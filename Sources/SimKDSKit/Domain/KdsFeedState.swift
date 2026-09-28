public import Foundation

public enum KdsConnectionState: String, Sendable, Hashable {
    case connected, connecting, offline, reconnecting
}

public struct KdsActionError: Sendable, Hashable {
    public var ticketNumber: String
    public var message: String
    public var failedAt: Date
    /// Feed-level failure (poll/fetch), not a ticket action.
    public var isFeedError: Bool
    /// Backend asked for a refresh (`stale_version` / `station_mismatch`).
    public var requiresRefresh: Bool

    public init(
        ticketNumber: String,
        message: String,
        failedAt: Date,
        isFeedError: Bool = false,
        requiresRefresh: Bool = false
    ) {
        self.ticketNumber = ticketNumber
        self.message = message
        self.failedAt = failedAt
        self.isFeedError = isFeedError
        self.requiresRefresh = requiresRefresh
    }
}

/// The board's whole observable state — the feed engine (PR 4) produces it,
/// the controller owns it, views render it.
public struct KdsFeedState: Sendable, Hashable {
    public var tickets: [KdsTicket]
    public var connectionState: KdsConnectionState
    public var lastSyncedAt: Date?
    public var deviceSettings: KdsDeviceSettings
    public var boardFilters: KdsBoardFilters
    public var stationDirectory: [KdsStationDirectoryEntry]
    public var lastActionError: KdsActionError?

    public init(
        tickets: [KdsTicket],
        connectionState: KdsConnectionState,
        lastSyncedAt: Date?,
        deviceSettings: KdsDeviceSettings = KdsDeviceSettings(),
        boardFilters: KdsBoardFilters = KdsBoardFilters(),
        stationDirectory: [KdsStationDirectoryEntry] = defaultKdsStationDirectory(),
        lastActionError: KdsActionError? = nil
    ) {
        self.tickets = tickets
        self.connectionState = connectionState
        self.lastSyncedAt = lastSyncedAt
        self.deviceSettings = deviceSettings
        self.boardFilters = boardFilters
        self.stationDirectory = stationDirectory
        self.lastActionError = lastActionError
    }
}
