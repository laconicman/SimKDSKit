/// How the client authenticates — one mechanism per request. Basic Auth is
/// gone with the contract picker (delta 2); `bearer` is the recommended path,
/// `apiKey` exists for backends that can't use Authorization.
public enum KdsCredentials: Sendable, Hashable {
    /// `Authorization: Bearer <token>`
    case bearer(String)
    /// `X-SimKDS-Api-Key: <key>`
    case apiKey(String)

    /// Header name/value pair this credential injects.
    var headerField: (name: String, value: String) {
        switch self {
        case let .bearer(token): ("Authorization", "Bearer \(token)")
        case let .apiKey(key): ("X-SimKDS-Api-Key", key)
        }
    }
}
