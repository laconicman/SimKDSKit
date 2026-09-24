import Foundation

/// Scrubs backend-supplied strings before they reach the board (port of the
/// sanitizer embedded in `KdsBackendTicketDto.kt`). The backend promises "safe
/// display names only"; this is the seatbelt for when it doesn't — emails,
/// phones, telegram handles/ids, tokens, and `*-id`-looking material are
/// dropped rather than shown.
enum GuestTextSanitizer {
    /// Swift `Regex` literal — compile-checked and immutable. `Regex` is not
    /// `Sendable`, so the shared instance is `nonisolated(unsafe)` — it is
    /// never mutated after initialization.
    nonisolated(unsafe) private static let sensitivePattern = ##/([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\+?\d[\d\s().-]{5,}\d|telegram|t\.me|tg:|telegram_id|telegramid|telegram user|telegram_user|@\w{4,}|local_test_jwks|header\.payload\.signature|authsession(?:id)?|idtoken|id_token|verificationmode|jwks|(?:bearer|basic)\s+[A-Z0-9._~+/=-]+|(?:auth|token|secret|provider|providerpayment|payment|paymentattempt|guest|customer|telegram|order|fiscal|fiscaldocument|receipt|device|kkt|terminal)(?:id|token)?[-_:=]+[A-Z0-9][A-Z0-9._-]*)/##.ignoresCase()

    /// `nil` when the string is blank or matches the sensitive pattern —
    /// same contract as Kotlin `safeGuestVisibleText`.
    static func guestVisibleText(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.firstMatch(of: sensitivePattern) == nil ? trimmed : nil
    }

    /// Item names fall back to a placeholder rather than disappearing.
    static func itemName(_ value: String?) -> String {
        guestVisibleText(value) ?? "Позиция"
    }

    /// Customer names additionally drop raw guest references (`guest_*`,
    /// `customer_*`, `telegram_*`) that slip past the pattern.
    static func customerName(_ value: String?) -> String? {
        guard let text = guestVisibleText(value) else { return nil }
        let normalized = text.lowercased()
        let prefixes = ["guest-", "guest_", "customer-", "customer_", "telegram-", "telegram_"]
        return prefixes.contains { normalized.hasPrefix($0) } ? nil : text
    }
}
