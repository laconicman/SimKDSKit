import Foundation

/// Preconditions a Real-mode request/action must satisfy (port of
/// `KdsRuntimeContextValidation.kt`, Generic contract only). Error strings keep
/// the Android wording — the operator sees the same sentences.
public enum KdsRuntimeContextValidation {
    public static func requestError(_ settings: KdsDeviceSettings) -> String? {
        contextError(settings, requireActor: false)
    }

    public static func actionError(_ settings: KdsDeviceSettings) -> String? {
        contextError(settings, requireActor: true)
    }

    public static func isPlaceholderActorId(_ value: String) -> Bool {
        value.isPlaceholderToken(explicitTokens: [
            "baristakds", "kdssystem", "system", "alpha",
            "alphaactor", "demoactor", "testactor",
        ])
    }

    private static func contextError(_ settings: KdsDeviceSettings, requireActor: Bool) -> String? {
        if let urlError = realBackendUrlSecurityError(settings.apiBaseUrl) {
            return urlError
        }
        if settings.stationId.kdsIsBlank {
            return "KDS stationId is required before GenericKds request"
        }
        if settings.stationId.isPlaceholderToken() {
            return "KDS stationId must be configured before GenericKds request"
        }
        if settings.deviceId.kdsIsBlank {
            return "KDS deviceId is required before GenericKds request"
        }
        if settings.deviceId.isPlaceholderToken() {
            return "KDS deviceId must be configured before GenericKds request"
        }
        if requireActor && settings.actorId.kdsIsBlank {
            return "KDS actorId is required before GenericKds action"
        }
        if requireActor && isPlaceholderActorId(settings.actorId) {
            return "KDS actorId must be configured before GenericKds action"
        }
        return nil
    }

    /// Real backends are HTTPS; loopback stays HTTP for the local mock server.
    /// `10.0.2.2` is dropped — the Android-emulator host means nothing on iOS.
    private static func realBackendUrlSecurityError(_ apiBaseUrl: String) -> String? {
        guard let url = URL(string: apiBaseUrl.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased() else {
            return "KDS Real API requires HTTPS"
        }
        if scheme == "https" { return nil }
        if scheme == "http" && (url.host ?? "").isLoopbackDevelopmentHost { return nil }
        return "KDS Real API requires HTTPS"
    }
}

private extension String {
    var isLoopbackDevelopmentHost: Bool {
        let host = lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var contextToken: String {
        trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacing("_", with: "")
            .replacing("-", with: "")
            .replacing(" ", with: "")
    }

    func isPlaceholderToken(explicitTokens: Set<String> = []) -> Bool {
        let token = contextToken
        if explicitTokens.contains(token) || placeholderTokens.contains(token) { return true }
        return placeholderSuffixes.contains { token.hasSuffix($0) }
    }
}

private let placeholderTokens: Set<String> = [
    "unknown", "placeholder", "fake", "default", "unset", "none", "null", "todo", "tbd",
]

private let placeholderSuffixes: Set<String> = [
    "unknown", "placeholder", "fake", "default", "unset",
]
