public import Foundation

// Ported from SimKDS `domain/KdsTicket.kt`. Wire vocabulary follows the Generic
// KDS spec (`displayNumber`, `visibleAt`), not the Kotlin field names — the spec
// owns the names here, same rule that dropped `orderId`/`statusUpdatedAt`.

public enum KdsTicketSource: String, Sendable, Hashable, CaseIterable {
    case pos
    case online
    case unknown

    public var operatorLabel: String {
        switch self {
        case .pos: "За баром"
        case .online: "Приложение"
        case .unknown: "Источник не указан"
        }
    }
}

public enum KdsTicketStatus: String, Sendable, Hashable, CaseIterable {
    case new
    case inProgress
    case ready
    case completed
    case cancelled
    case blocked
}

/// Optional display metadata in Generic KDS — the backend decides visibility,
/// so these never gate the board (the SimCafe paid+fiscal gate is gone with the
/// contract picker; see DocC `Design` deltas).
public enum KdsPaymentState: String, Sendable, Hashable {
    case pending, paid, failed, refunded
}

public enum KdsFiscalState: String, Sendable, Hashable {
    case pending, accepted, succeeded, needsOperator
}

public enum KdsAvailabilityState: String, Sendable, Hashable {
    case available, unavailable
}

public struct KdsStation: Sendable, Hashable {
    public var stationId: String
    public var label: String

    public init(stationId: String, label: String) {
        self.stationId = stationId
        self.label = label
    }

    public static let barHot = KdsStation(stationId: "station_bar_hot", label: "BAR-HOT")
    public static let barCold = KdsStation(stationId: "station_bar_cold", label: "BAR-COLD")
    public static let kitchen = KdsStation(stationId: "station_kitchen", label: "KITCHEN")
    public static let unknown = KdsStation(stationId: "station_unknown", label: "UNKNOWN")

    /// Legacy/display-name path: accepts loose tokens ("bar", "BAR HOT",
    /// `stationBarCold`) and normalizes them to a `station_*` id.
    public static func fromBackend(_ value: String?) -> KdsStation {
        let raw = value?.trimmingCharacters(in: .whitespaces) ?? ""
        switch raw.normalizedStationToken {
        case "":
            return .unknown
        case "bar", "hot", "barhot", "stationbar", "stationbarhot":
            return .barHot
        case "cold", "barcold", "stationbarcold":
            return .barCold
        case "kitchen", "stationkitchen":
            return .kitchen
        default:
            let stationId = raw.stationIdNormalized
            return KdsStation(stationId: stationId, label: stationId.stationLabel)
        }
    }

    /// Strict path for the Generic contract: the wire carries canonical
    /// `station_*` ids; anything malformed collapses to `.unknown` rather than
    /// being rescued by the loose normalizer.
    public static func fromBackendStationId(_ value: String?) -> KdsStation {
        let stationId = (value?.trimmingCharacters(in: .whitespaces) ?? "").lowercased()
        switch stationId {
        case Self.barHot.stationId: return .barHot
        case Self.barCold.stationId: return .barCold
        case Self.kitchen.stationId: return .kitchen
        case Self.unknown.stationId: return .unknown
        default:
            guard stationId.isCanonicalStationId else { return .unknown }
            return KdsStation(stationId: stationId, label: stationId.stationLabel)
        }
    }

    public func matchesStationId(_ value: String) -> Bool {
        guard let current = stationId.canonicalStationId, let expected = value.canonicalStationId else {
            return false
        }
        return current == expected
    }
}

public struct KdsTicketItem: Sendable, Hashable {
    public var name: String
    public var quantity: Int
    public var modifiers: [String]
    public var comment: String?
    public var recipeLines: [String]
    public var availabilityState: KdsAvailabilityState

    public init(
        name: String,
        quantity: Int,
        modifiers: [String] = [],
        comment: String? = nil,
        recipeLines: [String] = [],
        availabilityState: KdsAvailabilityState = .available
    ) {
        self.name = name
        self.quantity = quantity
        self.modifiers = modifiers
        self.comment = comment
        self.recipeLines = recipeLines
        self.availabilityState = availabilityState
    }
}

public struct KdsTicket: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayNumber: String
    public var source: KdsTicketSource
    public var sourceLabel: String?
    public var status: KdsTicketStatus
    public var paymentState: KdsPaymentState?
    public var fiscalState: KdsFiscalState?
    public var visibleAt: Date
    public var slaDueAt: Date?
    public var version: Int?
    public var station: KdsStation
    public var customerName: String?
    public var availabilityState: KdsAvailabilityState
    public var items: [KdsTicketItem]

    public init(
        id: String,
        displayNumber: String,
        source: KdsTicketSource,
        sourceLabel: String? = nil,
        status: KdsTicketStatus,
        paymentState: KdsPaymentState? = nil,
        fiscalState: KdsFiscalState? = nil,
        visibleAt: Date,
        slaDueAt: Date? = nil,
        version: Int? = nil,
        station: KdsStation = .barHot,
        customerName: String? = nil,
        availabilityState: KdsAvailabilityState = .available,
        items: [KdsTicketItem]
    ) {
        self.id = id
        self.displayNumber = displayNumber
        self.source = source
        self.sourceLabel = sourceLabel
        self.status = status
        self.paymentState = paymentState
        self.fiscalState = fiscalState
        self.visibleAt = visibleAt
        self.slaDueAt = slaDueAt
        self.version = version
        self.station = station
        self.customerName = customerName
        self.availabilityState = availabilityState
        self.items = items
    }

    public func waitDuration(now: Date) -> Duration {
        .seconds(max(0, Int(now.timeIntervalSince(visibleAt))))
    }

    /// Visibility on the kitchen board. Generic KDS: status + availability only
    /// — the backend already decided payment/fiscal visibility (delta 5).
    public var isAllowedForKds: Bool {
        ![.completed, .cancelled, .blocked].contains(status)
            && availabilityState == .available
            && items.allSatisfy { $0.availabilityState == .available }
    }
}

private extension String {
    var stationLabel: String {
        strippingStationPrefix
            .split(separator: "_")
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
            .joined(separator: "-")
    }

    var strippingStationPrefix: String {
        hasPrefix("station_") ? String(dropFirst("station_".count)) : self
    }

    /// `^station_[a-z0-9]+(_[a-z0-9]+)*$` — hand-rolled because a shared
    /// `Regex` value isn't `Sendable` and this check runs per ticket at most.
    var isCanonicalStationId: Bool {
        guard hasPrefix("station_") else { return false }
        let segments = dropFirst("station_".count).split(separator: "_", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0 >= "a" && $0 <= "z" || $0 >= "0" && $0 <= "9" }
        }
    }

    var canonicalStationId: String? {
        let candidate = trimmingCharacters(in: .whitespaces).lowercased()
        return candidate.isCanonicalStationId ? candidate : nil
    }

    var stationIdNormalized: String {
        let normalized = trimmingCharacters(in: .whitespaces)
            .replacing("-", with: "_")
            .replacing(" ", with: "_")
            .lowercased()
        if normalized.isEmpty { return "station_unknown" }
        return normalized.hasPrefix("station_") ? normalized : "station_\(normalized)"
    }

    var normalizedStationToken: String {
        trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacing("_", with: "")
            .replacing("-", with: "")
            .replacing(" ", with: "")
    }
}
