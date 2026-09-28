import Foundation
@testable import SimKDSKit

enum Fixtures {
    static let baseTime = Date(timeIntervalSince1970: 1_782_540_000) // 2026-05-08T10:00:00Z

    /// The Kotlin suites' `ticket(...)` factory — paid/accepted defaults kept
    /// even though the gate is gone, so ported assertions read the same.
    static func ticket(
        _ displayNumber: String,
        status: KdsTicketStatus,
        source: KdsTicketSource = .pos,
        paymentState: KdsPaymentState? = .paid,
        fiscalState: KdsFiscalState? = .accepted,
        visibleAt: Date = baseTime,
        version: Int? = nil,
        station: KdsStation = .barHot,
        availabilityState: KdsAvailabilityState = .available,
        items: [KdsTicketItem]? = nil
    ) -> KdsTicket {
        KdsTicket(
            id: "ticket-\(displayNumber)",
            displayNumber: displayNumber,
            source: source,
            status: status,
            paymentState: paymentState,
            fiscalState: fiscalState,
            visibleAt: visibleAt,
            version: version,
            station: station,
            availabilityState: availabilityState,
            items: items ?? [
                KdsTicketItem(
                    name: "Капучино 250",
                    quantity: 1,
                    modifiers: ["овсяное молоко"],
                    comment: "без сахара"
                ),
            ]
        )
    }

    static func displayNumbers(_ tickets: [KdsTicket]) -> [String] {
        tickets.map(\.displayNumber)
    }
}
