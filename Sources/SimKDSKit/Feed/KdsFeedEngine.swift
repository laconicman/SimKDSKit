public import Foundation

/// The feed's owner — port of `FakeKdsRepository`: optimistic dispatch with
/// backend confirmation, poll-driven snapshot merge, persisted settings, and
/// the operator error surface. Async where the Kotlin was blocking; the app
/// observes `observe()` where Android collected a `StateFlow`.
///
/// The engine talks only to `any KdsAPI` and `KdsContext` snapshots built from
/// the current settings at each call — it never holds a mutable client. When
/// connection settings change the app rebuilds the client and hands the new
/// facade to `updateSettings(_:api:)`.
public actor KdsFeedEngine {
    public private(set) var state: KdsFeedState

    private var api: any KdsAPI
    private let store: any KdsSettingsStore
    private let clock: @Sendable () -> Date
    /// `occurredAt` per pending real-mode action — retries of a failed action
    /// reuse the first stamp so the backend sees one idempotency key.
    private var pendingActionOccurredAt: [String: Date] = [:]
    /// The latest snapshot's rows by id — see `remoteRows`. Rollback consults
    /// it: a board row is merged local+remote, so the remote half must be kept
    /// separately to know whether a failed action's optimism still stands
    /// against what the backend actually reported, or whether the backend has
    /// stopped reporting the ticket at all.
    private var lastRemote: [String: KdsTicket] = [:]
    private var continuations: [UUID: AsyncStream<KdsFeedState>.Continuation] = [:]
    /// Kotlin's `synchronized(dispatchLock)`: action lifecycles serialize so a
    /// slow backend call can't interleave with a second tap's optimistic edit.
    private var dispatchTail: Task<Void, Never>?
    /// Bumped when the settings snapshot (or the facade) actually changes. A
    /// fetch is a request built from one snapshot — device, actor, location,
    /// station headers — so once that snapshot is superseded its outcome
    /// describes a request this device no longer makes: neither its tickets
    /// nor its failure are published; see `mayPublish` for the rerun.
    private var settingsVersion = 0
    /// Bumped when the board's identity changes — a different backend or
    /// station. Action outcomes key to this, not to `settingsVersion`: an edit
    /// that keeps the board (device label, actor) must still let a failure
    /// roll back and report on a ticket that is still here.
    private var boardVersion = 0
    /// Bumped per fetch — an older poll that finishes after a newer one is
    /// discarded, never merged.
    private var fetchTicket = 0
    /// When the current board's station directory was last fetched
    /// successfully; nil until the first fetch and after a backend change.
    /// The directory changes when a station is added or retired — rarely —
    /// so unlike tickets it is not refetched on every poll (SK-4).
    private var directoryFetchedAt: Date?
    private let directoryRefreshInterval: TimeInterval

    /// Deferred start (Kotlin's `eagerInitialFetch = false`): the engine loads
    /// persisted settings and sits at `.connecting` until `start()` runs the
    /// first fetch — construction never touches the network.
    ///
    /// `directoryRefreshInterval` is how often a poll also refreshes the
    /// station directory; the Android reference did so on every 2 s poll.
    public init(
        api: any KdsAPI,
        store: any KdsSettingsStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        directoryRefreshInterval: TimeInterval = 60
    ) {
        let persisted = store.load()
        self.api = api
        self.store = store
        self.clock = clock
        self.directoryRefreshInterval = directoryRefreshInterval
        self.state = KdsFeedState(
            tickets: [],
            connectionState: .connecting,
            lastSyncedAt: nil,
            deviceSettings: persisted.deviceSettings,
            boardFilters: persisted.boardFilters,
            lastActionError: persisted.lastActionError
        )
    }

    /// Every state change, current value first — the controller's binding.
    /// Each value is the whole board, so a subscriber that pauses needs only
    /// the newest one: older snapshots are obsolete, not a backlog to replay.
    public func observe() -> AsyncStream<KdsFeedState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<KdsFeedState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(state)
        return stream
    }

    /// The initial fetch (Kotlin's eager init, made async). Afterwards the feed
    /// is either `.connected` with the device's station tickets or `.offline`
    /// with a feed error; the poll loop drives `refresh()` from then on.
    public func start() async {
        let settings = state.deviceSettings
        let context = KdsContext(settings: settings)
        let snapshot = settingsVersion
        fetchTicket += 1
        let mine = fetchTicket
        let directory = try? await api.fetchStations(context: context) // always, on start
        do {
            let tickets = try await api.fetchActiveTickets(context: context)
                .forDeviceStation(settings)
            guard await mayPublish(snapshot: snapshot, mine: mine, rerun: { await start() }) else { return }
            // Sampled after the round trip: pickup wait starts when the
            // tablet first sees the ticket ready, not when it asked.
            let now = clock()
            // Merged, not assigned: an action can confirm while this fetch is
            // out, and a snapshot that predates it must not put the ticket back.
            // `mergeRemoteTicket` never rolls a more-advanced local status back
            // and stamps first-seen `readyAt` — the same policy as the poll.
            state.tickets = Self.replacedSnapshot(
                current: state.tickets,
                refreshed: tickets,
                at: now
            )
            lastRemote = Self.remoteRows(tickets)
            state.connectionState = .connected
            state.lastSyncedAt = now
            if let directory {
                state.stationDirectory = directory
                directoryFetchedAt = now
            }
            state.lastActionError = nil // a successful start clears the stale banner
            persistAndPublish()
        } catch {
            guard await mayPublish(snapshot: snapshot, mine: mine, rerun: { await start() }) else { return }
            let feedError = KdsActionError(
                ticketNumber: "feed",
                message: errorMessage(error),
                failedAt: clock(),
                isFeedError: true
            )
            state.connectionState = .offline
            state.lastSyncedAt = nil
            state.lastActionError = feedError
            persistAndPublish()
        }
    }

    /// Optimistic dispatch: reduce locally, send, roll back on failure. A
    /// duplicate of an already-applied action never reaches the backend, but a
    /// wrong-state action does — the backend resolves the conflict.
    /// Dispatches serialize through the backend call — Kotlin's
    /// `synchronized(dispatchLock)` — so a slow first action can't interleave
    /// its rollback with a second action's optimistic edit.
    public func dispatch(_ action: KdsAction) async {
        // The board the tap was made on. A queued action whose board changed
        // while it waited would address another backend's or station's ticket
        // — it is dropped before it runs, not sent to the wrong place.
        let board = boardVersion
        let previous = dispatchTail
        let current = Task { [previous] in
            await previous?.value
            guard board == boardVersion else { return }
            await runDispatch(action)
        }
        dispatchTail = current
        await current.value
    }

    private func runDispatch(_ action: KdsAction) async {
        let previousState = state
        // The board this action belongs to. If the board changes while the
        // call is out, its outcome — error, rollback, conflict refresh, sync
        // stamp — would land on another backend's or station's board, so it
        // is dropped instead.
        let board = boardVersion
        let dispatchAction = stabilized(action, for: previousState.deviceSettings)
        let optimisticTickets = KdsReducer.reduce(previousState.tickets, dispatchAction)
        if optimisticTickets == previousState.tickets,
           dispatchAction.isAlreadyApplied(in: previousState.tickets) {
            return
        }

        state.tickets = optimisticTickets
        state.lastActionError = nil
        let remoteAtDispatch = lastRemote[dispatchAction.ticketId]
        persistAndPublish()

        do {
            try await api.applyTicketAction(
                dispatchAction,
                context: KdsContext(settings: previousState.deviceSettings)
            )
            pendingActionOccurredAt.removeValue(forKey: dispatchAction.dedupeKey)
            guard board == boardVersion else { return }
            state.lastSyncedAt = clock()
            state.lastActionError = nil
            persistAndPublish()
        } catch {
            // Typed throws — `error` is already `KdsAPIError`.
            if error.isLocalValidationFailure || board != boardVersion {
                pendingActionOccurredAt.removeValue(forKey: dispatchAction.dedupeKey)
            }
            guard board == boardVersion else { return }
            let actionError = KdsActionError(
                ticketNumber: dispatchAction.displayNumber,
                message: errorMessage(error),
                failedAt: clock(),
                isFeedError: false,
                requiresRefresh: error.requiresRefresh
            )
            rollBack(
                dispatchAction,
                to: previousState,
                optimistic: optimisticTickets,
                remoteAtDispatch: remoteAtDispatch
            )
            state.lastActionError = actionError
            persistAndPublish()
            if error.requiresRefresh {
                // Same board as at dispatch (guarded above), so the current
                // settings address the action's backend and station.
                await refreshSnapshot(lastActionError: actionError)
            }
        }
    }

    /// Roll back only the optimistic transition this action owns, using the
    /// newest remote truth — anything a poll merged meanwhile (other tickets,
    /// refreshed fields on this one) survives. Wholesaler rollback to
    /// `previousState.tickets` would clobber those intervening changes.
    ///
    /// Four cases, in precedence order:
    /// - A merge changed the row's status while the call was out — the remote
    ///   won; the row is already truer than our rejected optimism.
    /// - The latest snapshot dropped this ticket (`lastRemote` lost it): the
    ///   row survived only as optimistic history, and restoring an active
    ///   status would resurrect a ticket the feed no longer shows — remove it.
    /// - A poll delivered new remote truth for this ticket (`lastRemote`
    ///   moved) without reaching the optimistic status — restore that truth;
    ///   a mere version bump still counts as "behind" and must roll back.
    ///   If the remote independently reached the optimistic status, the
    ///   failed call is moot — keep the row.
    /// - No newer remote word — revert only this action's optimistic fields.
    private func rollBack(
        _ action: KdsAction,
        to previousState: KdsFeedState,
        optimistic: [KdsTicket],
        remoteAtDispatch: KdsTicket?
    ) {
        guard let index = state.tickets.firstIndex(where: { $0.id == action.ticketId }),
              let produced = optimistic.first(where: { $0.id == action.ticketId })
        else { return }
        let current = state.tickets[index]
        guard current.status == produced.status
        else { return } // a merge decided this row — remote won

        let remote = lastRemote[action.ticketId]
        if remote != remoteAtDispatch {
            // The backend spoke about this ticket while the call was out…
            guard let remote else {
                state.tickets.remove(at: index) // …by no longer reporting it
                return
            }
            if remote.status == produced.status {
                return // it reached the goal independently — failure is moot
            }
            state.tickets[index] = remote // freshest server truth wins
            return
        }

        guard let before = previousState.tickets.first(where: { $0.id == action.ticketId })
        else { return }
        var restored = current
        restored.status = before.status
        restored.version = before.version
        restored.readyAt = before.readyAt
        state.tickets[index] = restored
    }

    /// The poll path (Kotlin `refreshActiveTickets`) — no connection flicker.
    public func refresh() async {
        await refreshSnapshot()
    }

    /// Reconnect affordance (Kotlin `retryReconnect`) — marks `.reconnecting`
    /// first so the banner reflects the attempt while it runs.
    public func retryReconnect() async {
        state.connectionState = .reconnecting
        publish()
        await refreshSnapshot()
    }

    /// Settings changed. A new `api` is supplied when connection parameters
    /// moved (the app rebuilds the client); station changes resync the board
    /// filter and drop the previous station's tickets immediately. A backend-
    /// identity change (mode, base URL, location, or a swapped client) drops
    /// the whole board — retained history from a different backend must not
    /// survive into the new target's feed.
    public func updateSettings(_ settings: KdsDeviceSettings, api newAPI: (any KdsAPI)? = nil) {
        let previous = state.deviceSettings
        let backendChanged = newAPI != nil
            || previous.backendMode != settings.backendMode
            || previous.apiBaseUrl != settings.apiBaseUrl
            || previous.locationId != settings.locationId
        let stationChanged = previous.stationId != settings.stationId
        // A retry is the *same* request only if its body is: station, device
        // and actor travel in the action payload (device also in the
        // idempotency key). Once any of them moves, a pending stamp would
        // pair the old key with a new body — `idempotency_conflict` on a
        // backend that recorded the first attempt. The next tap is a new
        // request and gets a fresh stamp.
        let requestIdentityChanged = stationChanged
            || previous.deviceId != settings.deviceId
            || previous.actorId != settings.actorId
        if let newAPI { api = newAPI }
        state.deviceSettings = settings
        if backendChanged || requestIdentityChanged {
            pendingActionOccurredAt.removeAll()
        }
        if backendChanged {
            state.tickets = []
            lastRemote.removeAll()
            // The directory belongs to the backend and location, not the
            // device; the previous one's stations must not be offered here
            // if the new backend's fetch fails — and the next poll fetches
            // the new one at once rather than waiting out the interval.
            state.stationDirectory = defaultKdsStationDirectory()
            directoryFetchedAt = nil
            state.boardFilters.stationId = settings.stationId
        } else {
            if stationChanged {
                state.boardFilters.stationId = settings.stationId
            }
            state.tickets = state.tickets.filter { $0.station.matchesStationId(settings.stationId) }
        }
        // An unchanged snapshot invalidates nothing — a same-settings save
        // must not discard (and rerun) a fetch that is already in flight.
        if settings != previous || newAPI != nil { settingsVersion += 1 }
        if backendChanged || stationChanged { boardVersion += 1 }
        persistAndPublish()
    }

    public func updateFilters(_ filters: KdsBoardFilters) {
        state.boardFilters = filters
        persistAndPublish()
    }

    /// The board the views render (Kotlin `activeBoard()`), with the persisted
    /// board filters applied — callers can't forget `KdsOpsFilters` and
    /// accidentally show every source.
    public func board() -> KdsBoard {
        KdsReducer.visibleBoard(
            KdsOpsFilters.apply(state.tickets, filters: state.boardFilters)
        )
    }

    // MARK: - Snapshot merge

    /// Kotlin `refreshActiveSnapshot`: fetch the station's active feed, merge
    /// it pairwise with local tickets, keep terminal history the feed dropped.
    private func refreshSnapshot(lastActionError: KdsActionError? = nil) async {
        let settings = state.deviceSettings
        let context = KdsContext(settings: settings)
        let snapshot = settingsVersion
        fetchTicket += 1
        let mine = fetchTicket
        do {
            let refreshed = try await api.refresh(context: context)
                .forDeviceStation(settings)
            // The directory rides along only when due; a failed fetch leaves
            // `directoryFetchedAt` alone so the next poll tries again.
            let directory: [KdsStationDirectoryEntry]? = isDirectoryDue(at: clock())
                ? try? await api.fetchStations(context: context)
                : nil
            guard await mayPublish(snapshot: snapshot, mine: mine, rerun: {
                await refreshSnapshot(lastActionError: lastActionError)
            }) else { return }
            let now = clock() // after the round trip — see `start()`
            state.tickets = Self.replacedSnapshot(
                current: state.tickets,
                refreshed: refreshed,
                at: now
            )
            lastRemote = Self.remoteRows(refreshed)
            state.connectionState = .connected
            state.lastSyncedAt = now
            if let directory {
                state.stationDirectory = directory
                directoryFetchedAt = now
            }
            state.lastActionError = lastActionError
            persistAndPublish()
        } catch {
            guard await mayPublish(snapshot: snapshot, mine: mine, rerun: {
                await refreshSnapshot(lastActionError: lastActionError)
            }) else { return }
            let now = clock()
            let message = errorMessage(error)
            state.connectionState = .offline
            state.lastActionError = lastActionError.map {
                KdsActionError(
                    ticketNumber: $0.ticketNumber,
                    message: "\($0.message); refresh failed: \(message)",
                    failedAt: now,
                    isFeedError: true
                )
            } ?? KdsActionError(
                ticketNumber: "feed",
                message: message,
                failedAt: now,
                isFeedError: true
            )
            persistAndPublish()
        }
    }

    private func isDirectoryDue(at now: Date) -> Bool {
        guard let directoryFetchedAt else { return true }
        return now.timeIntervalSince(directoryFetchedAt) >= directoryRefreshInterval
    }

    /// Exactly the rows the latest snapshot reported, by id — so `lastRemote`
    /// says both what the backend last said about a ticket *and* whether it
    /// still mentions it at all; a ticket the feed dropped is absent here even
    /// while its row survives on the board as history. Bounded by the feed,
    /// so a day of service accumulates nothing.
    private static func remoteRows(_ snapshot: [KdsTicket]) -> [String: KdsTicket] {
        Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Whether a completed fetch may publish its outcome — tickets or failure.
    /// A fetch superseded by a newer one yields to it. One invalidated by a
    /// settings change describes a request this device no longer makes; if
    /// nothing newer is in flight, dropping it would leave the board at
    /// `.connecting`/`.reconnecting` forever, so `rerun` first runs the same
    /// fetch again for the current settings.
    private func mayPublish(snapshot: Int, mine: Int, rerun: () async -> Void) async -> Bool {
        guard mine == fetchTicket else { return false }
        guard snapshot == settingsVersion else {
            await rerun()
            return false
        }
        return true
    }

    /// Kotlin `replaceWithActiveSnapshot`: merge each remote ticket with its
    /// local twin (never rolling a more-advanced local status back), retain
    /// local tickets absent from the feed only when they are history
    /// (ready/completed/cancelled), and never resurrect one the feed dropped.
    static func replacedSnapshot(
        current: [KdsTicket],
        refreshed: [KdsTicket],
        at now: Date
    ) -> [KdsTicket] {
        let merged = refreshed
            .deduplicatedById()
            .reduce(into: [KdsTicket]()) { tickets, remote in
                let seed = current.filter { $0.id == remote.id }
                tickets.append(contentsOf: KdsReducer.mergeRemoteTicket(seed, remoteTicket: remote, at: now))
            }
        let remoteIds = Set(merged.map(\.id))
        let retainedHistory = current.filter { ticket in
            !remoteIds.contains(ticket.id) && ticket.status.isRetainedAfterActiveSnapshot
        }
        return (merged + retainedHistory).sorted { $0.visibleAt < $1.visibleAt }
    }

    // MARK: - Action bookkeeping

    /// Kotlin `withStableOccurredAtFor`: in real mode a pending action keeps
    /// its first `occurredAt` across retries, so the idempotency key the
    /// backend dedupes on is the same request's, not the retry's.
    private func stabilized(_ action: KdsAction, for settings: KdsDeviceSettings) -> KdsAction {
        guard settings.backendMode == .real else { return action }
        let occurredAt = pendingActionOccurredAt[action.dedupeKey] ?? action.occurredAt
        pendingActionOccurredAt[action.dedupeKey] = occurredAt
        return action.withOccurredAt(occurredAt)
    }

    // MARK: - Persistence + observation plumbing

    private func persistAndPublish() {
        store.save(KdsPersistedSettings(
            deviceSettings: state.deviceSettings,
            boardFilters: state.boardFilters,
            lastActionError: state.lastActionError
        ))
        publish()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func errorMessage(_ error: any Error) -> String {
        (error as? KdsAPIError)?.errorDescription ?? String(describing: error)
    }
}

private extension KdsAction {
    /// Kotlin `actionKey` — one pending entry per action kind on one ticket
    /// at one expected version.
    var dedupeKey: String {
        "\(kind):\(ticketId):\(displayNumber):\(expectedVersion.map(String.init) ?? "none")"
    }

    var kind: String {
        switch self {
        case .start: "start"
        case .markReady: "mark_ready"
        case .complete: "complete"
        }
    }

    func withOccurredAt(_ date: Date) -> KdsAction {
        switch self {
        case let .start(ticketId, displayNumber, expectedVersion, _):
            .start(ticketId: ticketId, displayNumber: displayNumber,
                   expectedVersion: expectedVersion, occurredAt: date)
        case let .markReady(ticketId, displayNumber, expectedVersion, _):
            .markReady(ticketId: ticketId, displayNumber: displayNumber,
                       expectedVersion: expectedVersion, occurredAt: date)
        case let .complete(ticketId, displayNumber, expectedVersion, _):
            .complete(ticketId: ticketId, displayNumber: displayNumber,
                      expectedVersion: expectedVersion, occurredAt: date)
        }
    }

    /// Kotlin `isDuplicateAlreadyApplied`: every matched ticket already shows
    /// the action's target state, so a second tap is a no-op, not a request.
    func isAlreadyApplied(in tickets: [KdsTicket]) -> Bool {
        let matched = tickets.filter { $0.id == ticketId }
        return !matched.isEmpty && matched.allSatisfy { $0.hasApplied(self) }
    }
}

private extension KdsTicket {
    func hasApplied(_ action: KdsAction) -> Bool {
        switch action {
        case .start: status == .inProgress
        case .markReady: status == .ready
        case .complete: status == .completed
        }
    }
}

private extension KdsTicketStatus {
    /// Statuses that survive an active-snapshot replacement as history —
    /// everything else the feed dropped is gone for good.
    var isRetainedAfterActiveSnapshot: Bool {
        self == .ready || self == .completed || self == .cancelled
    }
}

private extension Array where Element == KdsTicket {
    /// Kotlin `toTicketsForDeviceStation`.
    func forDeviceStation(_ settings: KdsDeviceSettings) -> [KdsTicket] {
        filter { $0.station.matchesStationId(settings.stationId) }
    }

    func deduplicatedById() -> [KdsTicket] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
