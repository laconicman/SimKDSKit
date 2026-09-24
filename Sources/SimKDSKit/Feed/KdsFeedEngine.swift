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
    private var continuations: [UUID: AsyncStream<KdsFeedState>.Continuation] = [:]
    /// Kotlin's `synchronized(dispatchLock)`: action lifecycles serialize so a
    /// slow backend call can't interleave with a second tap's optimistic edit.
    private var dispatchTail: Task<Void, Never>?
    /// Bumped on every settings change — a fetch that started under the old
    /// backend must not publish under the new one.
    private var configVersion = 0
    /// Bumped per fetch — an older poll that finishes after a newer one is
    /// discarded, never merged.
    private var fetchTicket = 0

    /// Deferred start (Kotlin's `eagerInitialFetch = false`): the engine loads
    /// persisted settings and sits at `.connecting` until `start()` runs the
    /// first fetch — construction never touches the network.
    public init(
        api: any KdsAPI,
        store: any KdsSettingsStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let persisted = store.load()
        self.api = api
        self.store = store
        self.clock = clock
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
    public func observe() -> AsyncStream<KdsFeedState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<KdsFeedState>.makeStream()
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
        let now = clock()
        let config = configVersion
        fetchTicket += 1
        let mine = fetchTicket
        let directory = (try? await api.fetchStations(context: context))
            ?? state.stationDirectory
        do {
            let tickets = try await api.fetchActiveTickets(context: context)
                .forDeviceStation(settings)
            // A settings change or a newer fetch landed while this was in
            // flight — publishing now would show the old backend's board.
            guard config == configVersion, mine == fetchTicket else { return }
            state.tickets = tickets.map { ticket in
                var ticket = ticket
                if ticket.status == .ready, ticket.readyAt == nil {
                    ticket.readyAt = now // first seen ready at this fetch
                }
                return ticket
            }
            state.connectionState = .connected
            state.lastSyncedAt = now
            state.stationDirectory = directory
            state.lastActionError = nil // a successful start clears the stale banner
            persistAndPublish()
        } catch {
            guard config == configVersion, mine == fetchTicket else { return }
            let feedError = KdsActionError(
                ticketNumber: "feed",
                message: errorMessage(error),
                failedAt: now,
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
        let previous = dispatchTail
        let current = Task { [previous] in
            await previous?.value
            await runDispatch(action)
        }
        dispatchTail = current
        await current.value
    }

    private func runDispatch(_ action: KdsAction) async {
        let previousState = state
        let dispatchAction = stabilized(action, for: previousState.deviceSettings)
        let optimisticTickets = KdsReducer.reduce(previousState.tickets, dispatchAction)
        if optimisticTickets == previousState.tickets,
           dispatchAction.isAlreadyApplied(in: previousState.tickets) {
            return
        }

        state.tickets = optimisticTickets
        state.lastActionError = nil
        persistAndPublish()

        do {
            try await api.applyTicketAction(
                dispatchAction,
                context: KdsContext(settings: previousState.deviceSettings)
            )
            pendingActionOccurredAt.removeValue(forKey: dispatchAction.dedupeKey)
            state.lastSyncedAt = clock()
            state.lastActionError = nil
            persistAndPublish()
        } catch {
            // Typed throws — `error` is already `KdsAPIError`.
            if error.isLocalValidationFailure {
                pendingActionOccurredAt.removeValue(forKey: dispatchAction.dedupeKey)
            }
            let actionError = KdsActionError(
                ticketNumber: dispatchAction.displayNumber,
                message: errorMessage(error),
                failedAt: clock(),
                isFeedError: false,
                requiresRefresh: error.requiresRefresh
            )
            rollBack(dispatchAction, to: previousState)
            state.lastActionError = actionError
            persistAndPublish()
            if error.requiresRefresh {
                await refreshSnapshot(lastActionError: actionError, settings: previousState.deviceSettings)
            }
        }
    }

    /// Roll back only the optimistic transition this action owns — anything a
    /// poll merged meanwhile (other tickets, refreshed fields on this one)
    /// survives. Wholesaler rollback to `previousState.tickets` would clobber
    /// those intervening changes.
    private func rollBack(_ action: KdsAction, to previousState: KdsFeedState) {
        guard let index = state.tickets.firstIndex(where: { $0.id == action.ticketId }),
              let before = previousState.tickets.first(where: { $0.id == action.ticketId })
        else { return } // a snapshot already owns this row — leave it alone
        var restored = state.tickets[index]
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
        if let newAPI { api = newAPI }
        state.deviceSettings = settings
        if backendChanged {
            state.tickets = []
            pendingActionOccurredAt.removeAll()
            state.boardFilters.stationId = settings.stationId
        } else {
            if previous.stationId != settings.stationId {
                state.boardFilters.stationId = settings.stationId
            }
            state.tickets = state.tickets.filter { $0.station.matchesStationId(settings.stationId) }
        }
        configVersion += 1
        persistAndPublish()
    }

    public func updateFilters(_ filters: KdsBoardFilters) {
        state.boardFilters = filters
        persistAndPublish()
    }

    /// The board the views render (Kotlin `activeBoard()`).
    public func board() -> KdsBoard {
        KdsReducer.visibleBoard(state.tickets)
    }

    // MARK: - Snapshot merge

    /// Kotlin `refreshActiveSnapshot`: fetch the station's active feed, merge
    /// it pairwise with local tickets, keep terminal history the feed dropped.
    private func refreshSnapshot(
        lastActionError: KdsActionError? = nil,
        settings: KdsDeviceSettings? = nil
    ) async {
        let settings = settings ?? state.deviceSettings
        let context = KdsContext(settings: settings)
        let now = clock()
        let config = configVersion
        fetchTicket += 1
        let mine = fetchTicket
        do {
            let refreshed = try await api.refresh(context: context)
                .forDeviceStation(settings)
            let directory = (try? await api.fetchStations(context: context))
                ?? state.stationDirectory
            // A settings change or a newer fetch landed while this was in
            // flight — publishing now would merge the old backend's board.
            guard config == configVersion, mine == fetchTicket else { return }
            state.tickets = Self.replacedSnapshot(
                current: state.tickets,
                refreshed: refreshed,
                at: now
            )
            state.connectionState = .connected
            state.lastSyncedAt = now
            state.stationDirectory = directory
            state.lastActionError = lastActionError
            persistAndPublish()
        } catch {
            guard config == configVersion, mine == fetchTicket else { return }
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
