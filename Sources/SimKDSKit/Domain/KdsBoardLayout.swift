public import Foundation

/// New tickets spread round-robin across three columns; In Progress is one
/// wave (port of `KdsBoardLayout.kt`).
public struct KdsBoardLayout: Sendable, Hashable {
    public var newColumnA: [KdsTicket]
    public var newColumnB: [KdsTicket]
    public var newColumnC: [KdsTicket]
    public var inProgress: [KdsTicket]

    public init(
        newColumnA: [KdsTicket],
        newColumnB: [KdsTicket],
        newColumnC: [KdsTicket],
        inProgress: [KdsTicket]
    ) {
        self.newColumnA = newColumnA
        self.newColumnB = newColumnB
        self.newColumnC = newColumnC
        self.inProgress = inProgress
    }

    public init(tickets: [KdsTicket]) {
        self.init(board: KdsReducer.visibleBoard(tickets))
    }

    public init(board: KdsBoard) {
        let columns = Self.distribute(board.new, columnCount: 3)
        newColumnA = columns[0]
        newColumnB = columns[1]
        newColumnC = columns[2]
        inProgress = board.inProgress.sorted { $0.visibleAt < $1.visibleAt }
    }

    public static func distribute(_ tickets: [KdsTicket], columnCount: Int) -> [[KdsTicket]] {
        let count = max(1, columnCount)
        var columns = [[KdsTicket]](repeating: [], count: count)
        for (index, ticket) in tickets.enumerated() {
            columns[index % count].append(ticket)
        }
        return columns
    }

    /// Ready-wait is measured from the ready transition (`readyAt`, stamped by
    /// the reducer) to the first snapshot, then frozen: a ticket already in
    /// `previous` keeps its earlier value, so timers don't keep climbing while
    /// the order waits for pickup. `statusUpdatedAt` was dropped with the
    /// Generic-spec cut — `readyAt` + this map carry the semantics instead.
    public static func snapshotReadyWaitDurations(
        readyTickets: [KdsTicket],
        now: Date,
        previous: [String: Duration]
    ) -> [String: Duration] {
        var snapshot = [String: Duration]()
        for ticket in readyTickets {
            snapshot[ticket.id] = previous[ticket.id] ?? ticket.readyWaitDuration(now: now)
        }
        return snapshot
    }
}
