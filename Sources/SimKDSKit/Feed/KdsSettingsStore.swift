public import Foundation

/// Everything the engine persists between launches (port of Kotlin's
/// `KdsPersistedSettings`): device config, board filters, and the last
/// operator-visible error — an error banner survives an app restart.
public struct KdsPersistedSettings: Sendable, Hashable, Codable {
    public var deviceSettings: KdsDeviceSettings
    public var boardFilters: KdsBoardFilters
    public var lastActionError: KdsActionError?

    public init(
        deviceSettings: KdsDeviceSettings = KdsDeviceSettings(),
        boardFilters: KdsBoardFilters = KdsBoardFilters(),
        lastActionError: KdsActionError? = nil
    ) {
        self.deviceSettings = deviceSettings
        self.boardFilters = boardFilters
        self.lastActionError = lastActionError
    }
}

/// The persistence seam — the engine saves after every state transition it
/// would want back on restart. Synchronous: both stores below are.
public protocol KdsSettingsStore: Sendable {
    func load() -> KdsPersistedSettings
    func save(_ settings: KdsPersistedSettings)
}

/// Volatile store for tests and previews — the Kotlin suite's
/// `InMemoryKdsSettingsStore`.
public final class InMemoryKdsSettingsStore: KdsSettingsStore, @unchecked Sendable {
    private var value: KdsPersistedSettings
    private let lock = NSLock()

    public init(_ value: KdsPersistedSettings = KdsPersistedSettings()) {
        self.value = value
    }

    public func load() -> KdsPersistedSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ settings: KdsPersistedSettings) {
        lock.lock()
        value = settings
        lock.unlock()
    }
}

/// UserDefaults-backed store for the app. Absent and malformed data read as
/// defaults — corrupt settings must never block the board (the substrate rule
/// from YDeliveryKit, applied here too). Credentials never pass through it:
/// `KdsDeviceSettings` carries no secrets by construction.
/// `UserDefaults` is documented thread-safe but predates `Sendable` — the
/// conformance is asserted manually.
public final class UserDefaultsKdsSettingsStore: KdsSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "simkds.persisted-settings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> KdsPersistedSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(KdsPersistedSettings.self, from: data)
        else { return KdsPersistedSettings() }
        return decoded
    }

    public func save(_ settings: KdsPersistedSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}
