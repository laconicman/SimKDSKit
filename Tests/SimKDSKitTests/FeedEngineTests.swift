import Foundation
import Testing
@testable import SimKDSKit

// Port of `FakeKdsRepositoryTest` — the Generic-relevant subset (SimCafe/
// contract-picker cases are deleted on this platform). ScriptedKdsAPI plays
// the Kotlin suite's scripted `KdsHttpApiClient` doubles.

@Suite("Feed engine")
struct FeedEngineTests {
    private let base = Date(timeIntervalSince1970: 1_783_200_000)

    private func seeds() -> [KdsTicket] { MockKdsAPI.seedTickets(now: base) }
    private func seed(_ number: String) -> KdsTicket {
        seeds().first { $0.displayNumber == number }!
    }

    private func makeEngine(
        _ api: ScriptedKdsAPI,
        store: InMemoryKdsSettingsStore = InMemoryKdsSettingsStore(),
        clock: MutableClock? = nil
    ) -> KdsFeedEngine {
        let clock = clock ?? MutableClock(base)
        return KdsFeedEngine(api: api, store: store, clock: { clock.now })
    }

    private func action(
        _ kind: String = "start",
        ticket: KdsTicket,
        at occurredAt: Date? = nil
    ) -> KdsAction {
        let at = occurredAt ?? base
        switch kind {
        case "markReady":
            return .markReady(ticketId: ticket.id, displayNumber: ticket.displayNumber,
                              expectedVersion: ticket.version, occurredAt: at)
        case "complete":
            return .complete(ticketId: ticket.id, displayNumber: ticket.displayNumber,
                             expectedVersion: ticket.version, occurredAt: at)
        default:
            return .start(ticketId: ticket.id, displayNumber: ticket.displayNumber,
                          expectedVersion: ticket.version, occurredAt: at)
        }
    }

    private func status(_ engine: KdsFeedEngine, _ number: String) async -> KdsTicketStatus? {
        await engine.state.tickets.first { $0.displayNumber == number }?.status
    }

    // MARK: - Lifecycle

    @Test("Construction is deferred: .connecting, no backend calls")
    func deferredStart() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)

        #expect(await engine.state.connectionState == .connecting)
        #expect(await engine.state.tickets.isEmpty)
        #expect(await api.fetchCount == 0)
        #expect(await api.stationFetchCount == 0)
    }

    @Test("start loads only the device station's tickets and hydrates the directory")
    func startLoads() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        let state = await engine.state
        #expect(state.connectionState == .connected)
        #expect(state.tickets.map(\.displayNumber) == ["A-42", "A-43"])
        #expect(state.lastSyncedAt == base)
        #expect(state.stationDirectory.map(\.stationId).contains("station_bar_cold"))
        #expect(await api.stationFetchCount == 1)
    }

    @Test("start failure goes offline, stores and persists a feed error")
    func startFailure() async throws {
        let store = InMemoryKdsSettingsStore()
        let api = ScriptedKdsAPI(fetchResults: [.failure(.transport(underlying: "initial fetch timeout"))])
        let engine = makeEngine(api, store: store)
        await engine.start()

        let state = await engine.state
        #expect(state.connectionState == .offline)
        #expect(state.tickets.isEmpty)
        #expect(state.lastActionError?.isFeedError == true)
        #expect(store.load().lastActionError != nil)
    }

    // MARK: - Dispatch

    @Test("Dispatch applies the optimistic update while the backend call runs")
    func dispatchOptimistic() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook {
            // Inside the backend call the local ticket is already in progress.
            let status = await engine.state.tickets.first { $0.displayNumber == "A-43" }?.status
            #expect(status == .inProgress)
        }
        await engine.dispatch(action(ticket: seed("A-43")))

        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await api.sentActions.count == 1)
        #expect(await engine.state.lastActionError == nil)
    }

    @Test("Duplicate start on an already-started ticket is not re-sent")
    func duplicateStart() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action(ticket: seed("A-43")))
        await engine.dispatch(action(ticket: seed("A-43")))

        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await api.sentActions.count == 1)
    }

    @Test("Wrong-state actions still reach the backend for conflict resolution")
    func wrongStateReachesBackend() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action("markReady", ticket: seed("A-43"))) // ticket is .new

        #expect(await status(engine, "A-43") == .new)
        #expect(await api.sentActions.count == 1)
        #expect(await engine.state.lastActionError == nil)
    }

    @Test("Failed action rolls the ticket back and stores an operator error")
    func failedActionRollsBack() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action(ticket: seed("A-43")))

        let state = await engine.state
        #expect(await status(engine, "A-43") == .new)
        #expect(state.lastActionError?.ticketNumber == "A-43")
        #expect(state.lastActionError?.message == "backend timeout")
        #expect(state.lastActionError?.isFeedError == false)
        #expect(state.lastActionError?.requiresRefresh == false)
    }

    @Test("A later success clears a previous rollback error")
    func successClearsError() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.backendError(message: "backend timeout")), .success(())]
        )
        let engine = makeEngine(api)
        await engine.start()

        let ticket = seed("A-43")
        await engine.dispatch(action(ticket: ticket))
        await engine.dispatch(action(ticket: ticket))

        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await engine.state.lastActionError == nil)
    }

    // MARK: - Conflict → refresh

    @Test("stale_version rolls back, shows the operator error, and refreshes")
    func conflictRefreshes() async throws {
        var remote = seed("A-43")
        remote.status = .inProgress
        remote.version = 4
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([remote])],
            actionResults: [.failure(.conflict(code: .staleVersion, message: "expected 3, got 5"))]
        )
        let clock = MutableClock(base)
        let engine = makeEngine(api, clock: clock)
        await engine.start()

        clock.advance(by: 30)
        await engine.dispatch(action(ticket: seed("A-43")))

        let state = await engine.state
        #expect(await api.refreshCount == 1)
        #expect(await status(engine, "A-43") == .inProgress)
        #expect(state.lastActionError?.ticketNumber == "A-43")
        #expect(state.lastActionError?.requiresRefresh == true)
        #expect(state.connectionState == .connected)
        #expect(state.lastSyncedAt == clock.now)
    }

    @Test("Conflict recovery does not advance a ticket the stale feed still holds new")
    func conflictStaleSnapshot() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-43")])], // backend still shows it new
            actionResults: [.failure(.conflict(code: .staleVersion, message: "version conflict"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action(ticket: seed("A-43")))

        #expect(await status(engine, "A-43") == .new)
        #expect(await engine.state.lastActionError?.requiresRefresh == true)
        #expect(await engine.state.connectionState == .connected)
    }

    // MARK: - Snapshot merge

    @Test("Refresh keeps a locally advanced status over a stale remote ticket")
    func localStatusWins() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-43")])] // still .new on the backend
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action(ticket: seed("A-43")))
        await engine.retryReconnect()

        #expect(await status(engine, "A-43") == .inProgress)
    }

    @Test("Refresh drops tickets missing from the active feed")
    func refreshDropsAbsent() async throws {
        let api = ScriptedKdsAPI(tickets: seeds(), refreshResults: [.success([])])
        let engine = makeEngine(api)
        await engine.start()
        #expect(await engine.state.tickets.isEmpty == false)

        await engine.retryReconnect()

        #expect(await engine.state.tickets.isEmpty)
        #expect(await engine.state.connectionState == .connected)
    }

    @Test("A locally completed ticket is not resurrected by a stale active feed")
    func completedNotResurrected() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-42")])] // backend still thinks it is in progress
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action("markReady", ticket: seed("A-42")))
        await engine.dispatch(action("complete", ticket: seed("A-42")))
        await engine.retryReconnect()

        #expect(await status(engine, "A-42") == .completed)
        #expect(await engine.state.tickets.filter { $0.displayNumber == "A-42" }.count == 1)
        #expect(await engine.board().activeTickets.isEmpty)
    }

    @Test("A clean snapshot keeps completed history; a stale feed never re-adds it")
    func cleanSnapshotKeepsHistory() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([]), .success([seed("A-42")])]
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.dispatch(action("markReady", ticket: seed("A-42")))
        await engine.dispatch(action("complete", ticket: seed("A-42")))

        await engine.retryReconnect() // empty feed — A-42 survives as history
        #expect(await status(engine, "A-42") == .completed)

        await engine.retryReconnect() // stale feed mentions it again — still completed, still single
        #expect(await status(engine, "A-42") == .completed)
        #expect(await engine.state.tickets.filter { $0.displayNumber == "A-42" }.count == 1)
    }

    @Test("Failed refresh goes offline and marks the error as a feed error")
    func refreshFailure() async throws {
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.failure(.transport(underlying: "poll timeout")), .success([])]
        )
        let engine = makeEngine(api)
        await engine.start()

        await engine.retryReconnect()
        #expect(await engine.state.connectionState == .offline)
        #expect(await engine.state.lastActionError?.isFeedError == true)
        #expect(await engine.state.lastActionError?.ticketNumber == "feed")

        await engine.retryReconnect() // the next success clears it
        #expect(await engine.state.connectionState == .connected)
        #expect(await engine.state.lastActionError == nil)
    }

    // MARK: - Settings + persistence

    @Test("Station change resyncs the filter and drops the old station's tickets")
    func settingsStationChange() async throws {
        let store = InMemoryKdsSettingsStore(KdsPersistedSettings(
            deviceSettings: KdsDeviceSettings(),
            boardFilters: KdsBoardFilters(source: .pos, stationId: "station_bar_hot")
        ))
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api, store: store)
        await engine.start()

        var settings = await engine.state.deviceSettings
        settings.stationId = "station_bar_cold"
        await engine.updateSettings(settings)

        let state = await engine.state
        #expect(state.boardFilters.stationId == "station_bar_cold")
        #expect(state.boardFilters.source == .pos) // unrelated filter survives
        #expect(state.tickets.isEmpty) // both seeded tickets were barHot
        #expect(store.load().boardFilters.stationId == "station_bar_cold")
    }

    @Test("Unchanged station keeps the operator's filters")
    func settingsSameStationKeepsFilters() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        let filters = KdsBoardFilters(source: .online, stationId: nil)
        await engine.updateFilters(filters)
        var settings = await engine.state.deviceSettings
        settings.deviceName = "Lenovo Tab10 BAR-HOT Front"
        await engine.updateSettings(settings)

        #expect(await engine.state.boardFilters == filters)
    }

    @Test("Settings, filters and a stored action error survive an engine restart")
    func restartPersistence() async throws {
        let store = InMemoryKdsSettingsStore()
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let first = makeEngine(api, store: store)
        await first.start()
        await first.dispatch(action(ticket: seed("A-43")))

        let restarted = makeEngine(ScriptedKdsAPI(tickets: seeds()), store: store)
        let state = await restarted.state
        #expect(state.lastActionError?.ticketNumber == "A-43")
        #expect(state.lastActionError?.message == "backend timeout")

        // A successful relaunch clears the stale banner — the board is
        // connected, the old failure is history.
        await restarted.start()
        #expect(await restarted.state.lastActionError == nil)
        #expect(await restarted.state.connectionState == .connected)
    }

    // MARK: - Idempotent retries

    @Test("Real-mode retry keeps the failed action's occurredAt — one idempotency key")
    func stableOccurredAt() async throws {
        var settings = KdsDeviceSettings()
        settings.backendMode = .real
        let store = InMemoryKdsSettingsStore(KdsPersistedSettings(deviceSettings: settings))
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.backendError(message: "timeout")), .success(())]
        )
        let clock = MutableClock(base)
        let engine = makeEngine(api, store: store, clock: clock)
        await engine.start()

        let ticket = seed("A-43")
        await engine.dispatch(action(ticket: ticket, at: base))
        clock.advance(by: 15)
        await engine.dispatch(action(ticket: ticket, at: clock.now))

        let sent = await api.sentActions
        #expect(sent.count == 2)
        #expect(sent[0].occurredAt == base)
        #expect(sent[1].occurredAt == base) // retry reuses the first stamp
    }

    @Test("Consecutive accepted actions carry advanced expected versions")
    func advancingVersions() async throws {
        var seeded = seeds()
        if let index = seeded.firstIndex(where: { $0.displayNumber == "A-43" }) {
            seeded[index].version = 3
        }
        let api = ScriptedKdsAPI(tickets: seeded)
        let engine = makeEngine(api)
        await engine.start()

        var ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }!
        await engine.dispatch(action(ticket: ticket))
        ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }!
        await engine.dispatch(action("markReady", ticket: ticket))
        ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }!
        await engine.dispatch(action("complete", ticket: ticket))

        #expect(await api.sentActions.map(\.expectedVersion) == [3, 4, 5])
        #expect(await engine.state.lastActionError == nil)
    }

    // MARK: - Concurrency

    @Test("A failed action rolls back only its own ticket — a poll that merged meanwhile survives")
    func rollbackPreservesConcurrentMerge() async throws {
        let gate = Gate()
        var extra = seed("A-42")
        extra.id = "ticket-c99"
        extra.displayNumber = "C-99"
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-42"), seed("A-43"), extra])],
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        await engine.refresh() // lands while the action's backend call is suspended
        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await engine.state.tickets.contains { $0.displayNumber == "C-99" })

        await gate.open()
        await dispatching

        let state = await engine.state
        #expect(await status(engine, "A-43") == .new) // only the optimistic edit rolls back
        #expect(state.tickets.contains { $0.displayNumber == "C-99" }) // the merged row survives
        #expect(await status(engine, "A-42") == .inProgress) // untouched
    }

    @Test("A failed action does not roll back a ticket a poll advanced meanwhile")
    func rollbackYieldsToNewerRemote() async throws {
        let gate = Gate()
        var remote = seed("A-43")
        remote.status = .ready
        remote.version = 9
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-42"), remote])],
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        await engine.refresh() // reports A-43 ready v9 while the action is out
        await gate.open()
        await dispatching

        // The failed start must not drag the ticket back to .new — the poll's
        // truth is newer than the rejected optimism.
        #expect(await status(engine, "A-43") == .ready)
        #expect(await engine.state.tickets.first { $0.displayNumber == "A-43" }?.version == 9)
        #expect(await engine.state.lastActionError != nil)
    }

    @Test("A poll that bumps only the version still counts as remote truth — the failed action rolls back to it")
    func rollbackRestoresStaleRemoteTruth() async throws {
        let gate = Gate()
        var remote = seed("A-43")
        remote.version = 5 // same .new status — a version bump, not advancement
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-42"), remote])],
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        await engine.refresh()
        await gate.open()
        await dispatching

        // Merge kept local .inProgress but adopted version 5; the rollback
        // must restore the remote's .new — version drift is not status
        // advancement, and the rejected optimism must not survive.
        let ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }
        #expect(ticket?.status == .new)
        #expect(ticket?.version == 5)
    }

    @Test("A failed action is moot when the remote independently reached the goal")
    func rollbackMootWhenRemoteConfirms() async throws {
        let gate = Gate()
        var remote = seed("A-43")
        remote.status = .inProgress // another tablet/backend path started it
        remote.version = 5
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-42"), remote])],
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        await engine.refresh()
        await gate.open()
        await dispatching

        // The remote independently reached .inProgress — the board already
        // shows what the rejected action wanted; nothing rolls back.
        let ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }
        #expect(ticket?.status == .inProgress)
        #expect(ticket?.version == 5)
    }

    @Test("board() applies the persisted filters")
    func boardAppliesFilters() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()
        #expect(await engine.board().activeTickets.count == 2)

        await engine.updateFilters(KdsBoardFilters(source: .online, stationId: nil))
        #expect(await engine.board().activeTickets.isEmpty) // seeds are all .pos

        await engine.updateFilters(KdsBoardFilters(source: .all, stationId: nil))
        #expect(await engine.board().activeTickets.count == 2)
    }

    @Test("Dispatches serialize through the backend call")
    func dispatchesSerialize() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook {
            if await api.sentActions.count == 1 { await gate.wait() }
        }
        async let first: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        // A-42 seeds in progress — markReady is its valid next transition.
        async let second: Void = engine.dispatch(action("markReady", ticket: seed("A-42")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await status(engine, "A-42") == .inProgress) // still queued behind the first call

        await gate.open()
        await first
        await second

        #expect(await status(engine, "A-42") == .ready)
        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await api.sentActions.map(\.displayNumber) == ["A-43", "A-42"])
    }

    @Test("A refresh that lands after a settings change is discarded")
    func staleRefreshDiscarded() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await api.setRefreshHook { await gate.wait() }
        async let refreshing: Void = engine.refresh()
        while await api.refreshCount == 0 { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.stationId = "station_bar_cold"
        await engine.updateSettings(settings)
        await gate.open()
        await refreshing

        // The suspended fetch was for the hot bar — it must not repopulate
        // the board now bound to the cold bar. Its replacement, run for the
        // cold bar, is what lands.
        #expect(await api.refreshCount == 2)
        #expect(await engine.state.tickets.map(\.displayNumber) == ["M-11"])
        #expect(await engine.state.connectionState == .connected)
    }

    @Test("A backend-identity change clears the board and its history")
    func backendChangeClearsBoard() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()
        await engine.dispatch(action("markReady", ticket: seed("A-42")))
        #expect(await status(engine, "A-42") == .ready)

        var settings = await engine.state.deviceSettings
        settings.locationId = "loc-other"
        await engine.updateSettings(settings)

        // A ready ticket from the old location must not linger as history.
        #expect(await engine.state.tickets.isEmpty)
    }

    @Test("A ticket already ready at first fetch gets readyAt stamped at load")
    func readyAtStampedOnStart() async throws {
        var ready = seed("A-43")
        ready.status = .ready
        ready.readyAt = nil
        let api = ScriptedKdsAPI(tickets: [seed("A-42"), ready])
        let engine = makeEngine(api)
        await engine.start()

        let ticket = await engine.state.tickets.first { $0.displayNumber == "A-43" }
        #expect(ticket?.readyAt == base) // pickup wait starts at first sight
    }

    @Test("readyAt and lastSyncedAt are stamped after the fetch returns, not before it was sent")
    func readyAtExcludesFetchLatency() async throws {
        var ready = seed("A-43")
        ready.status = .ready
        ready.readyAt = nil
        let api = ScriptedKdsAPI(tickets: [seed("A-42"), ready])
        let clock = MutableClock(base)
        let engine = makeEngine(api, clock: clock)
        await api.setFetchHook { clock.advance(by: 30) } // a slow network
        await engine.start()

        // 30 s of latency is not 30 s of pickup wait.
        let afterFetch = base.addingTimeInterval(30)
        #expect(await engine.state.tickets.first { $0.displayNumber == "A-43" }?.readyAt == afterFetch)
        #expect(await engine.state.lastSyncedAt == afterFetch)

        await api.setRefreshHook { clock.advance(by: 30) }
        await engine.refresh()
        #expect(await engine.state.lastSyncedAt == base.addingTimeInterval(60))
    }

    @Test("Duplicate ticket ids in the initial fetch are folded, not fatal")
    func duplicateIdsOnStart() async throws {
        let api = ScriptedKdsAPI(fetchResults: [.success([seed("A-43"), seed("A-43"), seed("A-42")])])
        let engine = makeEngine(api)
        await engine.start()

        #expect(await engine.state.connectionState == .connected)
        #expect(await engine.state.tickets.filter { $0.displayNumber == "A-43" }.count == 1)
        #expect(await engine.state.tickets.count == 2)
    }

    @Test("An action whose settings changed mid-flight leaves the new board alone — no conflict refresh against the new backend")
    func settingsChangeMidDispatchDiscardsOutcome() async throws {
        let gate = Gate()
        let oldAPI = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.conflict(code: .staleVersion, message: "expected 3, got 5"))]
        )
        // The replacement backend also serves hot-bar tickets — exactly what a
        // conflict refresh under the old settings would drag onto the cold board.
        let newAPI = ScriptedKdsAPI(tickets: seeds())
        let clock = MutableClock(base)
        let engine = makeEngine(oldAPI, clock: clock)
        await engine.start()

        await oldAPI.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await oldAPI.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.stationId = "station_bar_cold"
        settings.locationId = "loc-other"
        await engine.updateSettings(settings, api: newAPI)
        clock.advance(by: 5)
        await gate.open()
        await dispatching

        #expect(await newAPI.refreshCount == 0) // no recovery against a mismatched configuration
        #expect(await engine.state.tickets.isEmpty) // the cold board stays clear
        #expect(await engine.state.lastActionError == nil) // the hot bar's error is not the cold bar's
        #expect(await engine.state.lastSyncedAt == base) // the old action's completion stamped nothing
    }

    @Test("A fetch that fails under superseded device identity does not mark the corrected feed offline")
    func staleIdentityFetchFailureDiscarded() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.failure(.localValidation("KDS deviceId must be configured"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setRefreshHook { await gate.wait() }
        async let refreshing: Void = engine.refresh()
        while await api.refreshCount == 0 { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.deviceId = "tablet_new" // same board — the request context is what changed
        await engine.updateSettings(settings)
        await gate.open()
        await refreshing

        // The failure describes a request tablet_new never made.
        #expect(await engine.state.connectionState == .connected)
        #expect(await engine.state.lastActionError == nil)
        #expect(await engine.state.tickets.isEmpty == false) // board kept: same backend, same station
    }

    @Test("A settings edit during start() reruns the initial fetch instead of leaving the board connecting")
    func settingsEditDuringStartReruns() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)

        await api.setFetchHook { await gate.wait() }
        async let starting: Void = engine.start()
        while await api.fetchCount == 0 { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.deviceId = "tablet_new"
        await engine.updateSettings(settings)
        await api.setFetchHook {} // the replacement must not block
        await gate.open()
        await starting

        #expect(await api.fetchCount == 2) // the stale request was replaced, not just dropped
        #expect(await engine.state.connectionState == .connected)
        #expect(await engine.state.tickets.isEmpty == false)
    }

    @Test("A settings edit during retryReconnect() ends connected, not stuck reconnecting")
    func settingsEditDuringReconnectReruns() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await api.setRefreshHook { await gate.wait() }
        async let reconnecting: Void = engine.retryReconnect()
        while await api.refreshCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await engine.state.connectionState == .reconnecting)

        var settings = await engine.state.deviceSettings
        settings.actorId = "barista_02"
        await engine.updateSettings(settings)
        await api.setRefreshHook {}
        await gate.open()
        await reconnecting

        #expect(await api.refreshCount == 2)
        #expect(await engine.state.connectionState == .connected)
    }

    @Test("Saving unchanged settings does not invalidate a fetch in flight")
    func unchangedSettingsKeepFetch() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        await api.setRefreshHook { await gate.wait() }
        async let refreshing: Void = engine.refresh()
        while await api.refreshCount == 0 { try await Task.sleep(for: .milliseconds(1)) }

        let same = await engine.state.deviceSettings
        await engine.updateSettings(same)
        await gate.open()
        await refreshing

        #expect(await api.refreshCount == 1) // nothing to replace — the request still describes this device
        #expect(await engine.state.connectionState == .connected)
    }

    @Test("Dispatches serialize through conflict recovery too — a later success cannot land under a rerun")
    func dispatchWaitsForConflictRecovery() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.conflict(code: .staleVersion, message: "expected 3, got 5")), .success(())]
        )
        let engine = makeEngine(api)
        await engine.start()

        // The conflict's recovery refresh pauses; a settings edit makes it rerun, still paused.
        await api.setRefreshHook { await gate.wait() }
        async let failing: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.refreshCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        var settings = await engine.state.deviceSettings
        settings.deviceId = "tablet_new"
        await engine.updateSettings(settings)

        // A second tap queues behind the whole first lifecycle, recovery included —
        // it is never sent while the rerun is in flight (Kotlin's dispatchLock).
        async let second: Void = engine.dispatch(action("markReady", ticket: seed("A-42")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await api.sentActions.count == 1)
        #expect(await engine.state.lastActionError?.ticketNumber == "A-43")

        await gate.open()
        await failing
        await second

        // The success runs last and owns the banner; nothing older can restore it.
        #expect(await api.sentActions.map(\.displayNumber) == ["A-43", "A-42"])
        #expect(await engine.state.lastActionError == nil)
        #expect(await status(engine, "A-42") == .ready)
    }

    @Test("A queued action whose board changed while it waited is dropped, not sent to the new backend")
    func queuedActionDroppedOnBoardChange() async throws {
        let gate = Gate()
        let oldAPI = ScriptedKdsAPI(tickets: seeds())
        let newAPI = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(oldAPI)
        await engine.start()

        await oldAPI.setActionHook { await gate.wait() }
        async let first: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await oldAPI.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        async let queued: Void = engine.dispatch(action("markReady", ticket: seed("A-42"))) // waits behind `first`
        try await Task.sleep(for: .milliseconds(20))

        var settings = await engine.state.deviceSettings
        settings.locationId = "loc-other"
        await engine.updateSettings(settings, api: newAPI)
        await gate.open()
        await first
        await queued

        // The tap on A-42 was made on the old board; it must not reach the new backend.
        #expect(await newAPI.sentActions.isEmpty)
        #expect(await oldAPI.sentActions.map(\.displayNumber) == ["A-43"])
    }

    @Test("A late start() fetch merges — it does not put a confirmed action's ticket back")
    func lateStartMergesOverDispatchedProgress() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        await engine.start()

        // A second start() (scene re-activation) pauses on its fetch…
        await api.setFetchHook { await gate.wait() }
        async let restarting: Void = engine.start()
        while await api.fetchCount < 2 { try await Task.sleep(for: .milliseconds(1)) }
        // …while an action on A-43 completes.
        await api.setActionHook {}
        await engine.dispatch(action(ticket: seed("A-43")))
        #expect(await status(engine, "A-43") == .inProgress)

        await gate.open()
        await restarting

        // The fetch predates the action; it must not show A-43 as new again.
        #expect(await status(engine, "A-43") == .inProgress)
        #expect(await engine.state.connectionState == .connected)
    }

    @Test("A failed action on a ticket the latest poll dropped removes the row rather than resurrecting it")
    func rollbackRemovesTicketTheFeedDropped() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            refreshResults: [.success([seed("A-43")])], // the poll no longer reports A-42
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action("markReady", ticket: seed("A-42"))) // in progress → ready
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        await engine.refresh() // A-42 survives only as optimistic "ready" history
        #expect(await status(engine, "A-42") == .ready)

        await gate.open()
        await dispatching

        // Rolling back to in-progress would make an absent ticket active again.
        #expect(await status(engine, "A-42") == nil)
        #expect(await engine.state.lastActionError?.ticketNumber == "A-42")
    }

    @Test("A paused observer receives only the newest board, not every snapshot since it paused")
    func observerBuffersNewestOnly() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)
        let stream = await engine.observe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // the initial .connecting value

        await engine.start()
        await engine.refresh()
        await engine.refresh()
        await engine.dispatch(action(ticket: seed("A-43"))) // several publishes while paused

        // Resuming yields the latest state directly — no replay of the intermediate boards.
        let resumed = await iterator.next()
        #expect(resumed?.tickets.first { $0.displayNumber == "A-43" }?.status == .inProgress)
    }

    @Test("A settings edit that keeps the board (device label) does not strand a failed action")
    func boardPreservingEditKeepsFailureHandling() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(
            tickets: seeds(),
            actionResults: [.failure(.backendError(message: "backend timeout"))]
        )
        let engine = makeEngine(api)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.deviceName = "Bar tablet (renamed)" // same backend, same station
        await engine.updateSettings(settings)
        await gate.open()
        await dispatching

        // The ticket is still on this board, so its failure must land here:
        // rolled back to the server's truth, and reported to the operator.
        #expect(await status(engine, "A-43") == .new)
        #expect(await engine.state.lastActionError?.ticketNumber == "A-43")
    }

    @Test("A successful action whose settings changed mid-flight stamps nothing on the new board")
    func settingsChangeMidDispatchDiscardsSuccess() async throws {
        let gate = Gate()
        let api = ScriptedKdsAPI(tickets: seeds())
        let clock = MutableClock(base)
        let engine = makeEngine(api, clock: clock)
        await engine.start()

        await api.setActionHook { await gate.wait() }
        async let dispatching: Void = engine.dispatch(action(ticket: seed("A-43")))
        while await api.sentActions.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        var settings = await engine.state.deviceSettings
        settings.stationId = "station_bar_cold"
        await engine.updateSettings(settings)
        clock.advance(by: 5)
        await gate.open()
        await dispatching

        #expect(await engine.state.lastSyncedAt == base)
    }

    // MARK: - Observation

    @Test("observe() yields the current state, then every change")
    func observeStream() async throws {
        let api = ScriptedKdsAPI(tickets: seeds())
        let engine = makeEngine(api)

        var iterator = await engine.observe().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.connectionState == .connecting)

        await engine.start()
        let connected = await iterator.next()
        #expect(connected?.connectionState == .connected)
        #expect(connected?.tickets.count == 2)
    }
}
