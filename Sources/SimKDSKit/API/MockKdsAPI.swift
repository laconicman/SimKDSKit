public import Foundation

/// In-memory backend for demo mode, previews, and tests (port of
/// `FakeKdsHttpApiClient`, mapped straight to domain types — the DTO layer
/// doesn't exist on this side). `refresh` injects the scripted trio, actions
/// record themselves, `failNextAction` arms one failure.
public actor MockKdsAPI: KdsAPI {
    private var tickets: [KdsTicket]
    private var nextFailureMessage: String?
    private let clock: @Sendable () -> Date

    /// Optional hook for scripted action outcomes (port of `onAction`).
    public var onAction: (@Sendable (KdsAction) throws(KdsAPIError) -> Void)?

    // Test introspection — the Kotlin client's counters.
    public private(set) var sentActions: [KdsAction] = []
    public private(set) var fetchCount = 0
    public private(set) var refreshCount = 0
    public private(set) var stationFetchCount = 0
    public private(set) var lastFetchContext: KdsContext?
    public private(set) var lastRefreshContext: KdsContext?

    public init(now: Date = Date(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.tickets = Self.seedTickets(now: now)
        self.clock = clock
    }

    public init(tickets: [KdsTicket], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.tickets = tickets
        self.clock = clock
    }

    public func fetchStations(context: KdsContext) async throws(KdsAPIError) -> [KdsStationDirectoryEntry] {
        stationFetchCount += 1
        return Self.defaultDirectory()
    }

    /// The demo directory — covers every station the scripted tickets use.
    public static func defaultDirectory() -> [KdsStationDirectoryEntry] {
        [
            KdsStationDirectoryEntry(
                stationId: "kitchen", route: "kitchen", label: "KITCHEN",
                displayName: "Kitchen", sortOrder: 10,
                activeTicketsPath: "/api/v1/kds/stations/kitchen/tickets/active"
            ),
            KdsStationDirectoryEntry(
                stationId: "bar_hot", route: "bar_hot", label: "BAR-HOT",
                displayName: "Hot bar", sortOrder: 20,
                activeTicketsPath: "/api/v1/kds/stations/bar_hot/tickets/active"
            ),
            KdsStationDirectoryEntry(
                stationId: "bar_cold", route: "bar_cold", label: "BAR-COLD",
                displayName: "Cold bar", sortOrder: 30,
                activeTicketsPath: "/api/v1/kds/stations/bar_cold/tickets/active"
            ),
        ]
    }

    public func fetchActiveTickets(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        fetchCount += 1
        lastFetchContext = context
        return tickets
    }

    /// The poll path: every refresh upserts the scripted trio, same as the
    /// Kotlin `refresh` — the demo board visibly changes on each poll.
    public func refresh(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        refreshCount += 1
        lastRefreshContext = context
        let now = clock()
        for ticket in [Self.fakePosOrder(now: now), Self.fakeOnlineOrder(now: now), Self.fakeFiscalReadyOrder(now: now)] {
            upsert(ticket)
        }
        return tickets
    }

    public func applyTicketAction(_ action: KdsAction, context: KdsContext) async throws(KdsAPIError) {
        sentActions.append(action)
        if let message = nextFailureMessage {
            nextFailureMessage = nil
            throw KdsAPIError.backendError(message: message)
        }
        try onAction?(action)
    }

    public func failNextAction(_ message: String) {
        nextFailureMessage = message
    }

    public func emitTicket(_ ticket: KdsTicket) {
        upsert(ticket)
    }

    private func upsert(_ ticket: KdsTicket) {
        if let index = tickets.firstIndex(where: { $0.id == ticket.id }) {
            tickets[index] = ticket
        } else {
            tickets.append(ticket)
        }
    }

    // MARK: - Scripted demo feed

    /// The four seed tickets — same ids/numbers/stations as the Kotlin fixture.
    /// `ticket-hidden` keeps its id for parity; under Generic semantics it is a
    /// normal kitchen ticket (payment/fiscal no longer gate visibility).
    public static func seedTickets(now: Date) -> [KdsTicket] {
        [
            KdsTicket(
                id: "ticket-a42", displayNumber: "A-42",
                source: .pos, status: .inProgress,
                paymentState: .paid, fiscalState: .succeeded,
                visibleAt: now.addingTimeInterval(-130),
                station: .barHot, customerName: "Гость у кассы",
                items: [
                    KdsTicketItem(
                        name: "Раф ванильный", quantity: 1,
                        modifiers: ["овсяное молоко"], comment: "потеплее"
                    ),
                    KdsTicketItem(name: "Круассан", quantity: 1),
                ]
            ),
            KdsTicket(
                id: "ticket-a43", displayNumber: "A-43",
                source: .pos, status: .new,
                paymentState: .paid, fiscalState: .accepted,
                visibleAt: now.addingTimeInterval(-65),
                station: .barHot, customerName: "POS",
                items: [
                    KdsTicketItem(name: "Капучино 250", quantity: 1),
                    KdsTicketItem(name: "Фильтр", quantity: 1, comment: "без крышки"),
                ]
            ),
            KdsTicket(
                id: "ticket-m11", displayNumber: "M-11",
                source: .online, status: .new,
                paymentState: .paid, fiscalState: .accepted,
                visibleAt: now.addingTimeInterval(-35),
                station: .barCold, customerName: "Мария",
                items: [
                    KdsTicketItem(
                        name: "Матча латте", quantity: 1,
                        modifiers: ["кокосовое молоко", "меньше льда"]
                    ),
                ]
            ),
            KdsTicket(
                id: "ticket-hidden", displayNumber: "M-12",
                source: .online, status: .new,
                paymentState: .pending, fiscalState: .pending,
                visibleAt: now.addingTimeInterval(-10),
                station: .kitchen, customerName: "Ожидает оплату",
                items: [KdsTicketItem(name: "Латте", quantity: 1)]
            ),
        ]
    }

    public static func fakePosOrder(now: Date) -> KdsTicket {
        KdsTicket(
            id: "ticket-a44", displayNumber: "A-44",
            source: .pos, status: .new,
            paymentState: .paid, fiscalState: .accepted,
            visibleAt: now,
            station: .kitchen, customerName: "POS",
            items: [
                KdsTicketItem(name: "Американо", quantity: 1),
                KdsTicketItem(name: "Брауни", quantity: 1),
            ]
        )
    }

    public static func fakeOnlineOrder(now: Date) -> KdsTicket {
        KdsTicket(
            id: "ticket-m13", displayNumber: "M-13",
            source: .online, status: .new,
            paymentState: .paid, fiscalState: .accepted,
            visibleAt: now.addingTimeInterval(1),
            station: .barHot, customerName: "Online guest",
            items: [
                KdsTicketItem(name: "Флэт уайт", quantity: 1, modifiers: ["без сахара"]),
            ]
        )
    }

    public static func fakeFiscalReadyOrder(now: Date) -> KdsTicket {
        KdsTicket(
            id: "ticket-hidden", displayNumber: "M-12",
            source: .online, status: .new,
            paymentState: .paid, fiscalState: .accepted,
            visibleAt: now.addingTimeInterval(2),
            station: .kitchen, customerName: "Ольга",
            items: [KdsTicketItem(name: "Латте", quantity: 1)]
        )
    }
}
