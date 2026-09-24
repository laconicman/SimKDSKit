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
        // the board now bound to the cold bar.
        #expect(await engine.state.tickets.isEmpty)
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
