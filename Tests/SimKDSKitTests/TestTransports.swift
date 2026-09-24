import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import SimKDSKit

// House pattern from YandexDeliveryExpressAPITests — a canned-response
// transport and a recorder that captures the post-middleware request.

/// Returns a canned response without a network.
struct StubTransport: ClientTransport {
    let status: HTTPResponse.Status
    let json: String

    init(status: HTTPResponse.Status = .ok, json: String) {
        self.status = status
        self.json = json
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: status)
        if !json.isEmpty {
            response.headerFields[.contentType] = "application/json"
        }
        return (response, json.isEmpty ? nil : HTTPBody(json))
    }
}

actor RequestRecorder {
    private(set) var request: HTTPRequest?
    private(set) var requestBody: String?

    func record(_ request: HTTPRequest, body: String?) {
        self.request = request
        self.requestBody = body
    }
}

/// Captures what the middleware stack produced, then answers like `StubTransport`.
struct RecordingTransport: ClientTransport {
    let recorder: RequestRecorder
    var status: HTTPResponse.Status = .ok
    var json: String = #"{"tickets":[]}"#

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var text: String?
        if let body {
            text = try await String(collecting: body, upTo: .max)
        }
        await recorder.record(request, body: text)
        var response = HTTPResponse(status: status)
        if !json.isEmpty {
            response.headerFields[.contentType] = "application/json"
        }
        return (response, json.isEmpty ? nil : HTTPBody(json))
    }
}

/// Records the request as this middleware sees it. Placed ahead of auth in
/// the chain, a nil credential header on the recording proves auth runs
/// innermost and never leaks secrets to caller-supplied middleware.
struct SpyMiddleware: ClientMiddleware {
    let recorder: RequestRecorder

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await recorder.record(request, body: nil)
        return try await next(request, body, baseURL)
    }
}

/// A mutable clock for scripted-time tests — the Kotlin suite's `var now`,
/// lock-guarded so it can feed a `@Sendable` clock closure.
final class MutableClock: @unchecked Sendable {
    private var value: Date
    private let lock = NSLock()

    init(_ now: Date) { value = now }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value.addTimeInterval(interval)
        lock.unlock()
    }
}

/// Fails the way a real network failure does.
struct FailingTransport: ClientTransport {
    struct Failure: Error {}

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw Failure()
    }
}
