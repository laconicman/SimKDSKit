import Foundation

public enum KdsSourceFilter: String, Sendable, Hashable, CaseIterable, Codable {
    case all
    case pos
    case online

    public var operatorLabel: String {
        switch self {
        case .all: "Все"
        case .pos: "За баром"
        case .online: "Приложение"
        }
    }
}

/// Station filtering keys on `stationId` directly — the Android
/// `KdsStationFilter` enum is deleted (directory supplies labels; delta 4).
public struct KdsBoardFilters: Sendable, Hashable, Codable {
    public var source: KdsSourceFilter
    public var stationId: String?

    public init(source: KdsSourceFilter = .all, stationId: String? = nil) {
        self.source = source
        self.stationId = stationId
    }
}

public enum KdsOpsFilters {
    public static func apply(_ tickets: [KdsTicket], filters: KdsBoardFilters) -> [KdsTicket] {
        tickets
            .filter { $0.matchesSource(filters.source) }
            .filter { ticket in
                guard let stationId = filters.stationId, !stationId.kdsIsBlank else { return true }
                return ticket.station.matchesStationId(stationId)
            }
            .sorted { $0.visibleAt < $1.visibleAt }
    }
}

private extension KdsTicket {
    func matchesSource(_ filter: KdsSourceFilter) -> Bool {
        switch filter {
        case .all: true
        case .pos: source == .pos
        case .online: source == .online
        }
    }
}
