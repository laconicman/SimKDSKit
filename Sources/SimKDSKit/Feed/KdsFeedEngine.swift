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
        let directory = (try? await api.fetchStations(context: context))
            ?? state.stationDirectory
        do {
            let tickets = try await api.fetchActiveTickets(context: context)
                .forDeviceStation(settings)
            state.tickets = tickets
            state.connectionState = .connected
            state.lastSyncedAt = now
            state.stationDirectory = directory
            persistAndPublish()
        } catch {
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
    public func dispatch(_ action: KdsAction) async {
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
            state.tickets = previousState.tickets
            state.lastActionError = actionError
            persistAndPublish()
            if error.requiresRefresh {
                await refreshSnapshot(lastActionError: actionError, settings: previousState.deviceSettings)
            }
        }
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
    /// filter and drop the previous station's tickets immediately.
    public func updateSettings(_ settings: KdsDeviceSettings, api newAPI: (any KdsAPI)? = nil) {
        if let newAPI { api = newAPI }
        if state.deviceSettings.stationId != settings.stationId {
            state.boardFilters.stationId = settings.stationId
        }
        state.deviceSettings = settings
        state.tickets = state.tickets.filter { $0.station.matchesStationId(settings.stationId) }
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
        do {
            let refreshed = try await api.refresh(context: context)
                .forDeviceStation(settings)
            let directory = (try? await api.fetchStations(context: context))
                ?? state.stationDirectory
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
