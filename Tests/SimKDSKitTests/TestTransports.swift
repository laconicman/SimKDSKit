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

// MARK: - Feed-engine backend double

/// The engine tests' backend — the Kotlin suite's scripted `KdsHttpApiClient`
/// doubles (`ManualRefresh`/`ConflictThen*`/`EmptyThen*`/`FailingFetch`) folded
/// into one actor: a fixed active feed plus a result queue per endpoint. An
/// exhausted queue falls back to the seed feed / success.
actor ScriptedKdsAPI: KdsAPI {
    private let fallbackTickets: [KdsTicket]
    private var fetchQueue: [Result<[KdsTicket], KdsAPIError>]
    private var refreshQueue: [Result<[KdsTicket], KdsAPIError>]
    private var actionQueue: [Result<Void, KdsAPIError>]
    private var stationsResult: Result<[KdsStationDirectoryEntry], KdsAPIError>
    private var actionHook: (@Sendable () async -> Void)?
    private var refreshHook: (@Sendable () async -> Void)?
    private var fetchHook: (@Sendable () async -> Void)?

    private(set) var sentActions: [KdsAction] = []
    private(set) var fetchCount = 0
    private(set) var refreshCount = 0
    private(set) var stationFetchCount = 0

    init(
        tickets: [KdsTicket] = [],
        fetchResults: [Result<[KdsTicket], KdsAPIError>] = [],
        refreshResults: [Result<[KdsTicket], KdsAPIError>] = [],
        actionResults: [Result<Void, KdsAPIError>] = [],
        stationsResult: Result<[KdsStationDirectoryEntry], KdsAPIError> = .success(MockKdsAPI.defaultDirectory())
    ) {
        self.fallbackTickets = tickets
        self.fetchQueue = fetchResults
        self.refreshQueue = refreshResults
        self.actionQueue = actionResults
        self.stationsResult = stationsResult
    }

    /// Kotlin's `onAction` — runs inside the action call so a test can assert
    /// the engine's optimistic state while the backend round-trip is in flight.
    func setActionHook(_ hook: @escaping @Sendable () async -> Void) {
        actionHook = hook
    }

    /// Same seam on the poll path — lets a test suspend a refresh mid-flight.
    func setRefreshHook(_ hook: @escaping @Sendable () async -> Void) {
        refreshHook = hook
    }

    /// Same seam on the initial fetch.
    func setFetchHook(_ hook: @escaping @Sendable () async -> Void) {
        fetchHook = hook
    }

    func fetchStations(context: KdsContext) async throws(KdsAPIError) -> [KdsStationDirectoryEntry] {
        stationFetchCount += 1
        return try stationsResult.get()
    }

    func fetchActiveTickets(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        fetchCount += 1
        await fetchHook?()
        return fetchQueue.isEmpty ? fallbackTickets : try fetchQueue.removeFirst().get()
    }

    func refresh(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        refreshCount += 1
        await refreshHook?()
        return refreshQueue.isEmpty ? fallbackTickets : try refreshQueue.removeFirst().get()
    }

    func applyTicketAction(_ action: KdsAction, context: KdsContext) async throws(KdsAPIError) {
        sentActions.append(action)
        await actionHook?()
        if !actionQueue.isEmpty {
            try actionQueue.removeFirst().get()
        }
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` releases every
/// waiter. Engine tests use it to hold a scripted backend call mid-flight.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
