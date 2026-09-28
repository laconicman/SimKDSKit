/// Call-time snapshot of `KdsDeviceSettings` — everything an API call needs
/// except credentials. The app rebuilds it when settings change; calls never
/// read a mutable settings object mid-flight.
public struct KdsContext: Sendable, Hashable {
    public var locationId: String
    public var stationId: String
    public var deviceId: String
    public var deviceName: String
    public var actorId: String
    public var backendMode: KdsBackendMode

    public init(
        locationId: String,
        stationId: String,
        deviceId: String,
        deviceName: String,
        actorId: String,
        backendMode: KdsBackendMode
    ) {
        self.locationId = locationId
        self.stationId = stationId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.actorId = actorId
        self.backendMode = backendMode
    }

    public init(settings: KdsDeviceSettings) {
        self.init(
            locationId: settings.locationId,
            stationId: settings.stationId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName,
            actorId: settings.actorId,
            backendMode: settings.backendMode
        )
    }
}
