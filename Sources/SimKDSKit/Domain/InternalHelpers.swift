import Foundation

extension String {
    /// Shared blank check for domain parsers — internal so every file in the
    /// module gets it without a `fileprivate` copy in each.
    var kdsIsBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}
