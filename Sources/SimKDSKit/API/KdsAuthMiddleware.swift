internal import Foundation
internal import HTTPTypes
internal import OpenAPIRuntime

/// Injects the credential header — `Authorization: Bearer` or
/// `X-SimKDS-Api-Key` — on every request. Internal: the app hands credentials
/// to `Client` construction and never touches headers itself.
struct KdsAuthMiddleware: ClientMiddleware {
    let credentials: KdsCredentials

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let field = credentials.headerField
        request.headerFields[HTTPField.Name(field.name)!] = field.value
        return try await next(request, body, baseURL)
    }
}
