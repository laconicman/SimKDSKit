public import Foundation

/// Conflict codes the backend can send on `409` (mirrors the spec's
/// `ErrorCode` enum). Only `staleVersion`/`stationMismatch` ask the caller to
/// refresh the feed — per the spec text, which is broader than the Kotlin
/// client's `stale_version`-only rule (delta noted in Design).
public enum KdsConflictCode: String, Sendable, Hashable {
    case staleVersion = "stale_version"
    case stationMismatch = "station_mismatch"
    case idempotencyConflict = "idempotency_conflict"
    case unknown

    /// True when the spec tells SimKDS to refresh active tickets.
    public var requiresRefresh: Bool {
        self == .staleVersion || self == .stationMismatch
    }
}

/// Two channels per house rule: documented HTTP statuses are the enum cases a
/// caller `switch`es on; transport/decoding failures are their own cases. Never
/// collapsed into one `Error`.
public enum KdsAPIError: Error, Sendable, Hashable {
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    case conflict(code: KdsConflictCode, message: String?)
    case validationError(message: String?)
    case backendError(message: String?)
    /// A status/content pair the spec doesn't document reached the client.
    case undocumented(statusCode: Int)
    case transport(underlying: String)
    case decoding(underlying: String)
    /// Client-side guard failed before a byte went on the wire
    /// (Kotlin's `isLocalValidationFailure`).
    case localValidation(String)

    /// The engine refreshes the feed when this is true.
    public var requiresRefresh: Bool {
        if case let .conflict(code, _) = self { return code.requiresRefresh }
        return false
    }

    public var isLocalValidationFailure: Bool {
        if case .localValidation = self { return true }
        return false
    }
}

extension KdsAPIError: LocalizedError {
    /// Operator-facing text (RU). Documented errors carry the backend's
    /// message verbatim — it was written for operators.
    public var errorDescription: String? {
        switch self {
        case let .unauthorized(message): message ?? "Нет доступа (401)"
        case let .forbidden(message): message ?? "Запрещено (403)"
        case let .notFound(message): message ?? "Не найдено (404)"
        case let .conflict(_, message): message ?? "Конфликт версии (409)"
        case let .validationError(message): message ?? "Ошибка валидации (422)"
        case let .backendError(message): message ?? "Ошибка бэкенда (5xx)"
        case let .undocumented(statusCode): "Неожиданный ответ (\(statusCode))"
        case let .transport(underlying): "Сеть: \(underlying)"
        case let .decoding(underlying): "Ответ не разобран: \(underlying)"
        case let .localValidation(message): message
        }
    }
}
