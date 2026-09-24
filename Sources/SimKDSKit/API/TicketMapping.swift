import Foundation
import OpenAPIRuntime

/// Generated schema → domain. The only file that knows both types; everything
/// downstream sees `KdsTicket`/`KdsStationDirectoryEntry`.
enum TicketMapping {
    static func tickets(_ response: Components.Schemas.ActiveTicketsResponse) -> [KdsTicket] {
        response.tickets.map(ticket).sorted { $0.visibleAt < $1.visibleAt }
    }

    static func ticket(_ schema: Components.Schemas.Ticket) -> KdsTicket {
        let paymentState = metadataPaymentState(schema.metadata)
        return KdsTicket(
            id: schema.ticketId,
            displayNumber: schema.displayNumber,
            source: source(schema.source),
            sourceLabel: GuestTextSanitizer.guestVisibleText(schema.sourceLabel),
            status: status(schema.kitchenState, paymentState: paymentState),
            paymentState: paymentState,
            fiscalState: metadataFiscalState(schema.metadata),
            visibleAt: schema.visibleAt,
            slaDueAt: schema.slaDueAt,
            version: schema.version,
            station: .fromBackendStationId(schema.stationId),
            customerName: GuestTextSanitizer.customerName(schema.customerName),
            availabilityState: .available,
            items: schema.items.map(item)
        )
    }

    static func stationDirectory(_ response: Components.Schemas.StationsResponse) -> [KdsStationDirectoryEntry] {
        response.stations
            .filter(\.isActive)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { station in
                let fallback = KdsStation.fromBackendStationId(station.stationId)
                return KdsStationDirectoryEntry(
                    stationId: station.stationId,
                    route: station.route,
                    label: station.label.kdsIsBlank ? fallback.label : station.label,
                    displayName: station.displayName.kdsIsBlank
                        ? fallback.label.replacing("-", with: " ")
                        : station.displayName,
                    sortOrder: station.sortOrder,
                    activeTicketsPath: station.activeTicketsPath,
                    isActive: station.isActive
                )
            }
    }

    // MARK: - Field mapping

    private static func source(_ source: Components.Schemas.TicketSource) -> KdsTicketSource {
        switch source {
        case .pos: .pos
        // `delivery` reads as online-channel on the board — the Kotlin table
        // left it Unknown; deliberate fix, listed in Design's deltas.
        case .app, .delivery, .web: .online
        case .other: .unknown
        }
    }

    private static func status(
        _ state: Components.Schemas.KitchenState,
        paymentState: KdsPaymentState?
    ) -> KdsTicketStatus {
        switch state {
        case .new: .new
        case .inProgress: .inProgress
        case .ready: .ready
        // Kotlin quirk kept: completed + refunded displays as cancelled.
        case .completed: paymentState == .refunded ? .cancelled : .completed
        case .cancelled: .cancelled
        case .blocked: .blocked
        }
    }

    private static func availability(
        _ state: Components.Schemas.AvailabilityState?
    ) -> KdsAvailabilityState {
        switch state {
        case .available, nil: .available
        case .unavailable, .blocked, .stoplisted, .soldOut, .cancelled: .unavailable
        }
    }

    private static func item(_ schema: Components.Schemas.TicketLine) -> KdsTicketItem {
        KdsTicketItem(
            name: GuestTextSanitizer.itemName(schema.name),
            quantity: schema.quantity,
            modifiers: (schema.modifiers ?? []).compactMap(GuestTextSanitizer.guestVisibleText),
            comment: GuestTextSanitizer.guestVisibleText(schema.comment),
            recipeLines: (schema.recipeLines ?? []).compactMap(GuestTextSanitizer.guestVisibleText),
            availabilityState: availability(schema.availabilityState)
        )
    }

    /// `metadata` is a free-form object; payment/fiscal ride inside it as
    /// optional strings on the wire.
    private static func metadataPaymentState(_ metadata: Components.Schemas.Ticket.MetadataPayload?) -> KdsPaymentState? {
        metadataString(metadata, "paymentState").flatMap(KdsPaymentState.init(rawValue:))
    }

    private static func metadataFiscalState(_ metadata: Components.Schemas.Ticket.MetadataPayload?) -> KdsFiscalState? {
        metadataString(metadata, "fiscalState").flatMap(KdsFiscalState.init(rawValue:))
    }

    private static func metadataString(
        _ metadata: Components.Schemas.Ticket.MetadataPayload?,
        _ key: String
    ) -> String? {
        (metadata?.additionalProperties.value[key] ?? nil) as? String
    }
}
