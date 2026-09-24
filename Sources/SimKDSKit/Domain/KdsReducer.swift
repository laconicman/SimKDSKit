import Foundation

public struct KdsBoard: Sendable, Hashable {
    public var new: [KdsTicket]
    public var inProgress: [KdsTicket]
    public var ready: [KdsTicket]

    public init(new: [KdsTicket], inProgress: [KdsTicket], ready: [KdsTicket]) {
        self.new = new
        self.inProgress = inProgress
        self.ready = ready
    }

    public var activeTickets: [KdsTicket] { new + inProgress + ready }
}

/// Pure board state transitions (port of `KdsReducer.kt`). No I/O, no clock —
/// callers inject `now` via the action's `occurredAt`.
public enum KdsReducer {
    /// Optimistic local transition: applied before the backend confirms.
    public static func reduce(_ tickets: [KdsTicket], _ action: KdsAction) -> [KdsTicket] {
        tickets.map { $0.id == action.ticketId ? $0.transitioned(by: action) : $0 }
    }

    public static func visibleBoard(_ tickets: [KdsTicket]) -> KdsBoard {
        let visible = tickets
            .filter(\.isAllowedForKds)
            .sorted { $0.visibleAt < $1.visibleAt }
        return KdsBoard(
            new: visible.filter { $0.status == .new },
            inProgress: visible.filter { $0.status == .inProgress },
            ready: visible.filter { $0.status == .ready }
        )
    }

    /// Merge a remote snapshot entry with local optimistic state: cancelled
    /// always wins, blocked wins over active, otherwise the most advanced
    /// status survives (a stale snapshot never rolls local progress back).
    public static func mergeRemoteTicket(_ tickets: [KdsTicket], remoteTicket: KdsTicket) -> [KdsTicket] {
        guard let existing = tickets.first(where: { $0.id == remoteTicket.id }) else {
            return (tickets + [remoteTicket]).sorted { $0.visibleAt < $1.visibleAt }
        }
        var merged = remoteTicket
        merged.status = mergeStatus(local: existing.status, remote: remoteTicket.status)
        return tickets
            .map { $0.id == remoteTicket.id ? merged : $0 }
            .sorted { $0.visibleAt < $1.visibleAt }
    }

    private static func mergeStatus(local: KdsTicketStatus, remote: KdsTicketStatus) -> KdsTicketStatus {
        if remote == .cancelled || local == .cancelled { return .cancelled }
        if remote == .blocked || local == .blocked { return remote }
        return local.rank >= remote.rank ? local : remote
    }
}

private extension KdsTicket {
    func transitioned(by action: KdsAction) -> KdsTicket {
        switch action {
        case .start:
            guard status == .new else { return self }
            var copy = self
            copy.status = .inProgress
            return copy.withOptimisticVersion(action)
        case .markReady:
            guard status == .inProgress else { return self }
            var copy = self
            copy.status = .ready
            return copy.withOptimisticVersion(action)
        case .complete:
            guard status == .ready else { return self }
            var copy = self
            copy.status = .completed
            return copy.withOptimisticVersion(action)
        }
    }

    /// An accepted optimistic action advances the local version so the next
    /// action's `expectedVersion` matches what the backend will have — without
    /// ever rolling a newer local version back.
    func withOptimisticVersion(_ action: KdsAction) -> KdsTicket {
        guard let expectedVersion = action.expectedVersion else { return self }
        let accepted = expectedVersion + 1
        var copy = self
        copy.version = version.map { max($0, accepted) } ?? accepted
        return copy
    }
}

private extension KdsTicketStatus {
    var rank: Int {
        switch self {
        case .new: 0
        case .inProgress: 1
        case .ready: 2
        case .completed, .cancelled: 3
        case .blocked: 0
        }
    }
}
