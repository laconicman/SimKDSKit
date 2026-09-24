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
