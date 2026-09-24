internal import Foundation
internal import OpenAPIRuntime
internal import OpenAPIURLSession

extension Client {
    /// The house construction: generated client + URLSession transport + the
    /// auth middleware, then any caller-supplied middlewares (logging).
    /// Transport is injectable so tests can hand a `StubTransport` in.
    init(
        serverURL: URL,
        credentials: KdsCredentials?,
        transport: any ClientTransport = URLSessionTransport(),
        additionalMiddlewares: [any ClientMiddleware] = []
    ) {
        var middlewares: [any ClientMiddleware] = []
        if let credentials {
            middlewares.append(KdsAuthMiddleware(credentials: credentials))
        }
        middlewares.append(contentsOf: additionalMiddlewares)
        self.init(serverURL: serverURL, transport: transport, middlewares: middlewares)
    }
}
