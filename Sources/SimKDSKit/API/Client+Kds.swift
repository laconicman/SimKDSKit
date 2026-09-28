internal import Foundation
internal import OpenAPIRuntime
internal import OpenAPIURLSession

extension Client {
    /// The house construction: generated client + URLSession transport + the
    /// auth middleware, plus any caller-supplied middlewares (logging).
    /// Auth is placed last — innermost — so a logging middleware observes the
    /// request *before* the credential header exists and can never persist it.
    /// Transport is injectable so tests can hand a `StubTransport` in.
    init(
        serverURL: URL,
        credentials: KdsCredentials?,
        transport: any ClientTransport = URLSessionTransport(),
        additionalMiddlewares: [any ClientMiddleware] = []
    ) {
        var middlewares: [any ClientMiddleware] = additionalMiddlewares
        if let credentials {
            middlewares.append(KdsAuthMiddleware(credentials: credentials))
        }
        self.init(serverURL: serverURL, transport: transport, middlewares: middlewares)
    }
}
