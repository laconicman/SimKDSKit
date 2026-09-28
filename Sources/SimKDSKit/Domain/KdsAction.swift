public import Foundation

/// Operator action on a ticket. Generic KDS always knows the `ticketId`
/// (required on the wire), so the Kotlin number-or-id fallback addressing is
/// deleted; `displayNumber` rides along only for error surfaces.
public enum KdsAction: Sendable, Hashable {
    case start(ticketId: String, displayNumber: String, expectedVersion: Int?, occurredAt: Date)
    case markReady(ticketId: String, displayNumber: String, expectedVersion: Int?, occurredAt: Date)
    case complete(ticketId: String, displayNumber: String, expectedVersion: Int?, occurredAt: Date)

    public var ticketId: String {
        switch self {
        case let .start(ticketId, _, _, _),
             let .markReady(ticketId, _, _, _),
             let .complete(ticketId, _, _, _):
            ticketId
        }
    }

    public var displayNumber: String {
        switch self {
        case let .start(_, displayNumber, _, _),
             let .markReady(_, displayNumber, _, _),
             let .complete(_, displayNumber, _, _):
            displayNumber
        }
    }

    public var expectedVersion: Int? {
        switch self {
        case let .start(_, _, expectedVersion, _),
             let .markReady(_, _, expectedVersion, _),
             let .complete(_, _, expectedVersion, _):
            expectedVersion
        }
    }

    public var occurredAt: Date {
        switch self {
        case let .start(_, _, _, occurredAt),
             let .markReady(_, _, _, occurredAt),
             let .complete(_, _, _, occurredAt):
            occurredAt
        }
    }
}

public struct KdsTicketBoardActionPresentation: Sendable, Hashable {
    public var action: KdsAction?
    public var label: String?

    public init(action: KdsAction?, label: String?) {
        self.action = action
        self.label = label
    }
}

public extension KdsTicket {
    /// The single action this ticket exposes on the board right now
    /// (port of `KdsTicketBoardAction.kt`).
    func boardActionPresentation(now: Date) -> KdsTicketBoardActionPresentation {
        switch status {
        case .new:
            KdsTicketBoardActionPresentation(
                action: .start(
                    ticketId: id,
                    displayNumber: displayNumber,
                    expectedVersion: version,
                    occurredAt: now
                ),
                label: "▶  Начать"
            )
        case .inProgress:
            KdsTicketBoardActionPresentation(
                action: .markReady(
                    ticketId: id,
                    displayNumber: displayNumber,
                    expectedVersion: version,
                    occurredAt: now
                ),
                label: "Готово"
            )
        case .ready, .completed, .cancelled, .blocked:
            KdsTicketBoardActionPresentation(action: nil, label: nil)
        }
    }
}
