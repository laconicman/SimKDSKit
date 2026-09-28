import Foundation

public enum KdsBackendMode: String, Sendable, Hashable, CaseIterable {
    case mock
    case real
}

/// Non-secret device/backend settings. Credentials are deliberately absent —
/// they live in the Keychain behind `CredentialStore` (delta 2), so this struct
/// is safe to persist in UserDefaults and to show whole in diagnostics.
public struct KdsDeviceSettings: Sendable, Hashable {
    public var apiBaseUrl: String
    public var locationId: String
    public var stationId: String
    public var stationLabel: String
    public var deviceName: String
    public var deviceId: String
    public var actorId: String
    public var backendMode: KdsBackendMode

    public init(
        apiBaseUrl: String = "http://localhost:8088",
        locationId: String = "demo_location",
        stationId: String = "station_bar_hot",
        stationLabel: String = "",
        deviceName: String = "SimKDS iPad BAR-HOT",
        deviceId: String = "",
        actorId: String = "",
        backendMode: KdsBackendMode = .mock
    ) {
        self.apiBaseUrl = apiBaseUrl
        self.locationId = locationId
        self.stationId = stationId
        self.stationLabel = stationLabel
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.actorId = actorId
        self.backendMode = backendMode
    }

    public var stationDisplayLabel: String {
        if !stationLabel.kdsIsBlank { return stationLabel }
        return KdsStation.fromBackendStationId(stationId).label
    }
}

/// Operator-facing diagnostics. `hasCredentials` is passed in because the
/// settings struct no longer carries secrets — the store answers, this type
/// renders. Labels are secret-safe by construction: they never interpolate
/// credential material.
public enum KdsDeviceDiagnostics {
    public static func authLabel(hasCredentials: Bool) -> String {
        hasCredentials ? "API key configured" : "Auth not configured"
    }

    public static func baristaBackendStatus(settings: KdsDeviceSettings, hasCredentials: Bool) -> String {
        guard settings.backendMode == .real else { return "Demo mode" }
        guard hasCredentials else { return "Нужен API key" }
        return realContractActionStatusLabel(settings) ?? "Real API готов"
    }

    public static func isRealBackendActionReady(settings: KdsDeviceSettings, hasCredentials: Bool) -> Bool {
        settings.backendMode == .real
            && hasCredentials
            && KdsRuntimeContextValidation.actionError(settings) == nil
    }

    private static func realContractActionStatusLabel(_ settings: KdsDeviceSettings) -> String? {
        KdsRuntimeContextValidation.actionError(settings).map { error in
            switch error {
            case _ where error.contains("HTTPS"): "Нужен HTTPS"
            case _ where error.contains("actorId"): "Нужен actorId"
            case _ where error.contains("deviceId"): "Нужен deviceId"
            case _ where error.contains("stationId"): "Нужен stationId"
            default: "Нужен KDS контекст"
            }
        }
    }
}
