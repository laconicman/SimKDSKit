import Foundation

/// One row of the station directory — either the built-in fallback or a
/// `GET /stations` entry mapped over (port of `KdsStationDirectoryEntry`).
public struct KdsStationDirectoryEntry: Sendable, Hashable, Identifiable {
    public var id: String { stationId }
    public var stationId: String
    public var route: String
    public var label: String
    public var displayName: String
    public var sortOrder: Int
    public var activeTicketsPath: String
    public var isActive: Bool

    public init(
        stationId: String,
        route: String,
        label: String,
        displayName: String,
        sortOrder: Int,
        activeTicketsPath: String,
        isActive: Bool = true
    ) {
        self.stationId = stationId
        self.route = route
        self.label = label
        self.displayName = displayName
        self.sortOrder = sortOrder
        self.activeTicketsPath = activeTicketsPath
        self.isActive = isActive
    }
}

/// Offline/first-run fallback so the board has a station before any directory
/// fetch succeeds.
public func defaultKdsStationDirectory() -> [KdsStationDirectoryEntry] {
    [
        KdsStationDirectoryEntry(
            stationId: "station_bar_hot",
            route: "bar_hot",
            label: "BAR-HOT",
            displayName: "Hot bar",
            sortOrder: 10,
            activeTicketsPath: "/api/v1/kds/stations/station_bar_hot/tickets/active"
        ),
        KdsStationDirectoryEntry(
            stationId: "station_bar_cold",
            route: "bar_cold",
            label: "BAR-COLD",
            displayName: "Cold bar",
            sortOrder: 20,
            activeTicketsPath: "/api/v1/kds/stations/station_bar_cold/tickets/active"
        ),
    ]
}
