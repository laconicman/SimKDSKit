import Foundation

/// Preconditions a Real-mode request/action must satisfy (port of
/// `KdsRuntimeContextValidation.kt`, Generic contract only). Error strings keep
/// the Android wording — the operator sees the same sentences.
public enum KdsRuntimeContextValidation {
    /// Full check on settings — URL security plus identity fields.
    public static func requestError(_ settings: KdsDeviceSettings) -> String? {
        if let urlError = realBackendUrlSecurityError(settings.apiBaseUrl) {
            return urlError
        }
        return identityError(
            locationId: settings.locationId, stationId: settings.stationId,
            deviceId: settings.deviceId, actorId: settings.actorId,
            requireActor: false
        )
    }

    public static func actionError(_ settings: KdsDeviceSettings) -> String? {
        if let urlError = realBackendUrlSecurityError(settings.apiBaseUrl) {
            return urlError
        }
        return identityError(
            locationId: settings.locationId, stationId: settings.stationId,
            deviceId: settings.deviceId, actorId: settings.actorId,
            requireActor: true
        )
    }

    /// Identity-only check for a `KdsContext` snapshot — the URL was already
    /// vetted when the client was built, so it isn't re-litigated per call.
    public static func requestError(context: KdsContext) -> String? {
        identityError(
            locationId: context.locationId, stationId: context.stationId,
            deviceId: context.deviceId, actorId: context.actorId,
            requireActor: false
        )
    }

    public static func actionError(context: KdsContext) -> String? {
        identityError(
            locationId: context.locationId, stationId: context.stationId,
            deviceId: context.deviceId, actorId: context.actorId,
            requireActor: true
        )
    }

    public static func isPlaceholderActorId(_ value: String) -> Bool {
        value.isPlaceholderToken(explicitTokens: [
            "baristakds", "kdssystem", "system", "alpha",
            "alphaactor", "demoactor", "testactor",
        ])
    }

    private static func identityError(
        locationId: String, stationId: String, deviceId: String,
        actorId: String, requireActor: Bool
    ) -> String? {
        if locationId.kdsIsBlank {
            return "KDS locationId is required before GenericKds request"
        }
        if stationId.kdsIsBlank {
            return "KDS stationId is required before GenericKds request"
        }
        if stationId.isPlaceholderToken() {
            return "KDS stationId must be configured before GenericKds request"
        }
        if deviceId.kdsIsBlank {
            return "KDS deviceId is required before GenericKds request"
        }
        if deviceId.isPlaceholderToken() {
            return "KDS deviceId must be configured before GenericKds request"
        }
        if requireActor && actorId.kdsIsBlank {
            return "KDS actorId is required before GenericKds action"
        }
        if requireActor && isPlaceholderActorId(actorId) {
            return "KDS actorId must be configured before GenericKds action"
        }
        return nil
    }

    /// URL-only check, run at client construction — a remote `http://` base
    /// URL would send credential headers in cleartext. Identity fields are a
    /// per-call concern and are not checked here.
    public static func urlSecurityError(_ apiBaseUrl: String) -> String? {
        realBackendUrlSecurityError(apiBaseUrl)
    }

    /// Real backends are HTTPS; loopback stays HTTP for the local mock server.
    /// `10.0.2.2` is dropped — the Android-emulator host means nothing on iOS.
    private static func realBackendUrlSecurityError(_ apiBaseUrl: String) -> String? {
        guard let url = URL(string: apiBaseUrl.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased() else {
            return "KDS Real API requires HTTPS"
        }
        // `https://` with no host parses but reaches nothing — reject it.
        if scheme == "https" { return url.host?.kdsIsBlank == false ? nil : "KDS Real API requires HTTPS" }
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
