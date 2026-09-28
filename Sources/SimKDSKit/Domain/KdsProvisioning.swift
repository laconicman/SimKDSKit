import Foundation

/// Result of applying a `simkds://provision` link. `clearsStoredCredentials`
/// replaces the Android fields-on-the-settings-struct clearing: credentials
/// live in the Keychain now, so the parser flags the target change and the
/// caller deletes them.
public struct KdsProvisioningOutcome: Sendable, Hashable {
    public var settings: KdsDeviceSettings
    public var clearsStoredCredentials: Bool
}

/// `simkds://provision` deep-link parser (port of `KdsProvisioning.kt`).
/// Generic contract only: a `contract` parameter that isn't a generic alias
/// rejects the link outright (delta 3). Links carrying auth material are
/// rejected before anything else is read — secrets never travel in a QR code.
public enum KdsProvisioning {
    private static let scheme = "simkds"
    private static let host = "provision"

    /// Resolved station slot — the parser's alias table kept private now that
    /// the public `KdsStationFilter` enum is deleted (delta 4).
    private enum StationSlot {
        case all, barHot, barCold, kitchen

        var isAll: Bool {
            if case .all = self { return true }
            return false
        }

        func defaultStationId(stationToken: String?, fallback: String) -> String {
            switch self {
            case .barHot: "station_bar_hot"
            case .barCold: "station_bar_cold"
            case .kitchen: "station_kitchen"
            case .all:
                if let stationToken, stationToken.normalizedToken != "all" {
                    KdsStation.fromBackend(stationToken).stationId
                } else {
                    fallback
                }
            }
        }
    }

    /// Compared against keys with all separators stripped, so `api_key`,
    /// `api-key`, and `apikey` are the same word.
    private static let authParamKeys: Set<String> = [
        "apikey", "token", "bearertoken", "accesstoken", "refreshtoken",
        "authorization", "auth", "secret", "clientsecret",
        "user", "username", "password", "basicauthusername", "basicauthpassword",
    ]

    /// Params that re-target the backend — only these justify flipping a mock
    /// device to real mode. Station/device/actor choices are board-local.
    private static let backendTargetParamKeys: Set<String> = [
        "api", "apibaseurl", "backendbaseurl", "locationid", "location", "cafeid",
    ]

    public static func settings(
        from rawUrl: String,
        into current: KdsDeviceSettings
    ) -> KdsProvisioningOutcome? {
        guard let components = URLComponents(string: rawUrl),
              components.scheme == scheme,
              components.host == host else {
            return nil
        }

        let params = parseQuery(components.percentEncodedQuery)
        if params.contains(where: { key, value in
            authParamKeys.contains(key.separatorStripped) && !value.kdsIsBlank
        }) {
            return nil
        }

        // contract= accepts generic aliases only; anything else is a contract
        // this build does not speak — reject rather than silently re-target.
        if let contract = params.firstNonBlank("contract", "httpContract"),
           !["generic", "generickds", "generic_kds", "simkds"].contains(contract.normalizedToken) {
            return nil
        }

        let stationToken = params.firstNonBlank("station", "stationRoute", "route")
        let stationIdParam = params.firstNonBlank("stationId")
        let slot = stationToken.flatMap(stationSlot(from:))
            ?? stationIdParam.flatMap(stationSlot(from:))
            ?? (stationToken != nil ? .all : slot(from: current.stationId))
        let stationId = stationIdParam ?? slot.defaultStationId(stationToken: stationToken, fallback: current.stationId)

        let apiBaseUrl = params.firstNonBlank("api", "apiBaseUrl", "backendBaseUrl") ?? current.apiBaseUrl
        let locationId = params.firstNonBlank("locationId", "location", "cafeId") ?? current.locationId
        let hasBackendTargetParams = params.contains { key, value in
            backendTargetParamKeys.contains(key.separatorStripped) && !value.kdsIsBlank
        }
        let clearsCredentials = current.apiBaseUrl.trimmedTrailingSlash != apiBaseUrl.trimmedTrailingSlash
            || current.locationId != locationId

        var next = current
        next.apiBaseUrl = apiBaseUrl
        next.locationId = locationId
        next.stationId = stationId
        next.stationLabel = stationLabel(
            stationToken: stationToken,
            stationIdParam: stationIdParam,
            slot: slot,
            stationId: stationId,
            current: current
        )
        next.deviceName = params.firstNonBlank("deviceName", "label") ?? current.deviceName
        next.deviceId = params.firstNonBlank("deviceId") ?? current.deviceId
        next.actorId = params.firstNonBlank("actorId")?.runtimeActor
            ?? current.actorId.runtimeActor
            ?? ""
        next.backendMode = params.firstNonBlank("mode", "backendMode")
            .flatMap(backendMode(from:))
            ?? (hasBackendTargetParams ? .real : current.backendMode)

        return KdsProvisioningOutcome(settings: next, clearsStoredCredentials: clearsCredentials)
    }

    // MARK: - Query parsing

    /// Form-style decode matching `URLDecoder`: `+` is a space, then percent
    /// decoding. (Foundation's `URLComponents.queryItems` does not treat `+`
    /// as a space, which would diverge from the Android parser.)
    private static func parseQuery(_ rawQuery: String?) -> [String: String] {
        guard let rawQuery, !rawQuery.kdsIsBlank else { return [:] }
        var params = [String: String]()
        for part in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = part.firstIndex(of: "="), separator != part.startIndex,
                  let key = String(part[..<separator]).formDecoded,
                  let value = String(part[part.index(after: separator)...]).formDecoded else {
                continue
            }
            params[key] = value
        }
        return params
    }

    // MARK: - Station resolution

    private static func stationSlot(from token: String) -> StationSlot? {
        switch token.normalizedToken {
        case "all": .all
        case "bar", "barhot", "bar_hot", "hot", "station_bar", "station_bar_hot": .barHot
        case "barcold", "bar_cold", "cold", "station_bar_cold": .barCold
        case "kitchen", "station_kitchen": .kitchen
        default: nil
        }
    }

    /// Slot for an existing configured stationId — unknown ids land on `.all`
    /// (custom post), mirroring the Kotlin `current.station` fallback.
    private static func slot(from stationId: String) -> StationSlot {
        stationSlot(from: stationId) ?? .all
    }

    private static func stationLabel(
        stationToken: String?,
        stationIdParam: String?,
        slot: StationSlot,
        stationId: String,
        current: KdsDeviceSettings
    ) -> String {
        if stationToken == nil && stationIdParam == nil { return current.stationLabel }
        // Both station params present → the explicit id owns routing, so the
        // label must come from it too (not from a disagreeing `station` token).
        if stationToken != nil && stationIdParam != nil {
            return KdsStation.fromBackend(stationId).label
        }
        if stationToken == nil && current.stationId == stationId { return current.stationLabel }
        if stationToken == nil && slot.isAll { return KdsStation.fromBackend(stationId).label }
        if slot.isAll, let stationToken, !stationToken.kdsIsBlank {
            return KdsStation.fromBackend(stationToken).label
        }
        return ""
    }

    private static func backendMode(from token: String) -> KdsBackendMode? {
        switch token.normalizedToken {
        case "mock", "demo": .mock
        case "real", "http", "staging": .real
        default: nil
        }
    }
}

private extension String {
    var trimmedTrailingSlash: String {
        var value = trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var normalizedToken: String {
        trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacing("-", with: "_")
            .replacing(" ", with: "_")
    }

    /// Lowercased with every separator removed — `api_key`/`api-key`/`apikey`
    /// all become `apikey`.
    var separatorStripped: String {
        lowercased()
            .replacing("_", with: "")
            .replacing("-", with: "")
            .replacing(" ", with: "")
    }

    var formDecoded: String? {
        replacing("+", with: " ").removingPercentEncoding
    }

    /// Placeholder actorIds ("barista-kds", "testactor", …) provisioned by
    /// mistake never become the runtime actor — the request stays unconfigured.
    var runtimeActor: String? {
        let value = trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !KdsRuntimeContextValidation.isPlaceholderActorId(value) else {
            return nil
        }
        return value
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstNonBlank(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key], !value.kdsIsBlank { return value }
        }
        return nil
    }
}
