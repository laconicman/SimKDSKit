package import Foundation
package import OpenAPIRuntime

/// The package's public API surface — the only thing the app talks to.
/// Documented statuses arrive as `KdsAPIError` cases; everything else is
/// `.transport`/`.decoding`. All methods throw `KdsAPIError` (typed throws).
public protocol KdsAPI: Sendable {
    func fetchStations(context: KdsContext) async throws(KdsAPIError) -> [KdsStationDirectoryEntry]
    func fetchActiveTickets(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket]
    /// The poll path. Same endpoint as `fetchActiveTickets` on a live backend;
    /// the mock uses it to inject its scripted arrivals.
    func refresh(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket]
    func applyTicketAction(_ action: KdsAction, context: KdsContext) async throws(KdsAPIError)
}

/// Live backend over the generated client. Per-request context headers travel
/// as generated `Input.Headers`; auth is middleware-injected at construction.
/// Internal — an implementation detail behind the public `KdsAPI` protocol.
struct LiveKdsAPI: KdsAPI {
    let client: Client

    func fetchStations(context: KdsContext) async throws(KdsAPIError) -> [KdsStationDirectoryEntry] {
        if let error = KdsRuntimeContextValidation.requestError(context: context) {
            throw .localValidation(error)
        }
        let output = try await call {
            try await client.listKdsStations(.init(
                query: .init(locationId: context.locationId),
                headers: .init(
                    xSimKDSLocationId: context.locationId,
                    xSimKDSDeviceId: context.deviceId,
                    xSimKDSDeviceName: context.deviceName
                )
            ))
        }
        switch output {
        case let .ok(response):
            return try TicketMapping.stationDirectory(jsonBody(response.body))
        case let .unauthorized(response): throw .unauthorized(message: errorMessage(response.body))
        case let .forbidden(response): throw .forbidden(message: errorMessage(response.body))
        case let .unprocessableContent(response):
            throw .validationError(message: errorMessage(response.body))
        case let .internalServerError(response):
            throw .backendError(message: errorMessage(response.body))
        case let .undocumented(statusCode, _): throw .undocumented(statusCode: statusCode)
        }
    }

    func fetchActiveTickets(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        if let error = KdsRuntimeContextValidation.requestError(context: context) {
            throw .localValidation(error)
        }

        let output = try await call {
            try await client.listActiveTickets(.init(
                path: .init(stationId: context.stationId),
                headers: .init(
                    xSimKDSLocationId: context.locationId,
                    xSimKDSStationId: context.stationId,
                    xSimKDSDeviceId: context.deviceId,
                    xSimKDSDeviceName: context.deviceName
                )
            ))
        }
        switch output {
        case let .ok(response):
            return try TicketMapping.tickets(jsonBody(response.body))
        case let .unauthorized(response): throw .unauthorized(message: errorMessage(response.body))
        case let .forbidden(response): throw .forbidden(message: errorMessage(response.body))
        case let .notFound(response): throw .notFound(message: errorMessage(response.body))
        case let .unprocessableContent(response):
            throw .validationError(message: errorMessage(response.body))
        case let .internalServerError(response):
            throw .backendError(message: errorMessage(response.body))
        case let .undocumented(statusCode, _): throw .undocumented(statusCode: statusCode)
        }
    }

    /// Live `refresh` is the same endpoint — only the mock scripts arrivals.
    func refresh(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        try await fetchActiveTickets(context: context)
    }

    func applyTicketAction(_ action: KdsAction, context: KdsContext) async throws(KdsAPIError) {
        if let error = KdsRuntimeContextValidation.actionError(context: context) {
            throw .localValidation(error)
        }

        let actionName = Self.actionName(action)
        let occurredAt = action.occurredAt
        let idempotencyKey = "kds_action_\(context.deviceId)_\(action.ticketId)_\(actionName)"
            + "_\(action.expectedVersion.map(String.init) ?? "unversioned")_\(occurredAt.idempotencyToken)"

        let output = try await call {
            try await client.applyTicketAction(.init(
                path: .init(ticketId: action.ticketId),
                headers: .init(
                    xSimKDSLocationId: context.locationId,
                    xSimKDSStationId: context.stationId,
                    xSimKDSDeviceId: context.deviceId,
                    xSimKDSDeviceName: context.deviceName,
                    idempotencyKey: idempotencyKey,
                    xRequestId: "req_\(idempotencyKey)"
                ),
                body: .json(.init(
                    stationId: context.stationId,
                    deviceId: context.deviceId,
                    actorId: context.actorId,
                    action: Self.wireAction(action),
                    expectedVersion: action.expectedVersion,
                    occurredAt: occurredAt
                ))
            ))
        }
        switch output {
        case .ok, .accepted, .noContent:
            return
        case let .unauthorized(response): throw .unauthorized(message: errorMessage(response.body))
        case let .forbidden(response): throw .forbidden(message: errorMessage(response.body))
        case let .notFound(response): throw .notFound(message: errorMessage(response.body))
        case let .conflict(response):
            // A 409 is a conflict even when the body is missing or carries a
            // code the spec doesn't know — Kotlin's "no refresh loop" case.
            guard let error = try? jsonBody(response.body).error else {
                throw KdsAPIError.conflict(code: .unknown, message: nil)
            }
            throw KdsAPIError.conflict(code: Self.conflictCode(error.code), message: error.message)
        case let .unprocessableContent(response):
            throw .validationError(message: errorMessage(response.body))
        case let .internalServerError(response):
            throw .backendError(message: errorMessage(response.body))
        case let .undocumented(statusCode, _): throw .undocumented(statusCode: statusCode)
        }
    }

    // MARK: - Helpers

    /// Transport errors become `.transport`; everything generated already
    /// decoded becomes its documented case.
    private func call<T>(
        _ operation: () async throws -> T
    ) async throws(KdsAPIError) -> T {
        do {
            return try await operation()
        } catch let error as KdsAPIError {
            throw error
        } catch let error as ClientError {
            // The runtime decodes documented bodies eagerly, so a 409 whose
            // body is malformed (or carries a code the spec doesn't know)
            // arrives here as a DecodingError — it is still a conflict.
            if error.response?.status == .conflict, error.underlyingError is DecodingError {
                throw .conflict(code: .unknown, message: nil)
            }
            if error.underlyingError is DecodingError {
                throw .decoding(underlying: String(describing: error.underlyingError))
            }
            throw .transport(underlying: error.errorDescription ?? String(describing: error))
        } catch {
            throw .transport(underlying: String(describing: error))
        }
    }

    private static func actionName(_ action: KdsAction) -> String {
        switch action {
        case .start: "start"
        case .markReady: "mark_ready"
        case .complete: "complete"
        }
    }

    private static func wireAction(_ action: KdsAction) -> Components.Schemas.TicketAction {
        switch action {
        case .start: .start
        case .markReady: .markReady
        case .complete: .complete
        }
    }

    private static func conflictCode(_ code: Components.Schemas.ErrorCode) -> KdsConflictCode {
        switch code {
        case .staleVersion: .staleVersion
        case .stationMismatch: .stationMismatch
        case .idempotencyConflict: .idempotencyConflict
        default: .unknown
        }
    }
}

/// Picks mock vs live per call from the context snapshot — the mode switch is
/// a per-request decision so a settings change can't strand in-flight work on
/// a stale delegate.
struct ModeSwitchingKdsAPI: KdsAPI {
    let mock: any KdsAPI
    let live: any KdsAPI

    private func delegate(for context: KdsContext) -> any KdsAPI {
        context.backendMode == .mock ? mock : live
    }

    func fetchStations(context: KdsContext) async throws(KdsAPIError) -> [KdsStationDirectoryEntry] {
        try await delegate(for: context).fetchStations(context: context)
    }

    func fetchActiveTickets(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        try await delegate(for: context).fetchActiveTickets(context: context)
    }

    func refresh(context: KdsContext) async throws(KdsAPIError) -> [KdsTicket] {
        try await delegate(for: context).refresh(context: context)
    }

    func applyTicketAction(_ action: KdsAction, context: KdsContext) async throws(KdsAPIError) {
        try await delegate(for: context).applyTicketAction(action, context: context)
    }
}

/// Public construction — the app's only entry point to the network layer.
/// Builds the generated client + URLSession transport + auth middleware and
/// hides both behind the facade. Mock and live are composed here so a mode
/// flip in settings takes effect on the next call without rebuilding.
public enum KdsAPIs {
    /// The app-facing factory. `settings.apiBaseUrl` must already pass
    /// `KdsRuntimeContextValidation` (https / loopback rules) — a bad URL is a
    /// programming error surfaced as `.localValidation`, not a crash.
    public static func make(
        settings: KdsDeviceSettings,
        credentials: KdsCredentials?,
        mock: any KdsAPI = MockKdsAPI()
    ) throws(KdsAPIError) -> any KdsAPI {
        guard let serverURL = URL(string: settings.apiBaseUrl) else {
            throw .localValidation("KDS apiBaseUrl is not a valid URL")
        }
        return ModeSwitchingKdsAPI(
            mock: mock,
            live: LiveKdsAPI(client: Client(serverURL: serverURL, credentials: credentials))
        )
    }

    /// Test seam — same construction with the transport swapped for a stub.
    package static func make(
        serverURL: URL,
        credentials: KdsCredentials?,
        transport: any ClientTransport
    ) -> any KdsAPI {
        LiveKdsAPI(client: Client(serverURL: serverURL, credentials: credentials, transport: transport))
    }
}

// MARK: - Response plumbing (generated-shape specifics)

/// Error bodies are `{"error": {...}}` on every documented error response;
/// extract the message, tolerate a missing/undecodable body.
private func errorMessage<Body>(_ body: Body) -> String? {
    guard let payload = body as? any _HasJsonErrorBody else { return nil }
    return try? payload.errorMessage
}

private protocol _HasJsonErrorBody {
    var errorMessage: String { get throws }
}

extension Components.Responses.Unauthorized.Body: _HasJsonErrorBody {
    var errorMessage: String { get throws { try json.error.message } }
}
extension Components.Responses.Forbidden.Body: _HasJsonErrorBody {
    var errorMessage: String { get throws { try json.error.message } }
}
extension Components.Responses.NotFound.Body: _HasJsonErrorBody {
    var errorMessage: String { get throws { try json.error.message } }
}
extension Components.Responses.ValidationError.Body: _HasJsonErrorBody {
    var errorMessage: String { get throws { try json.error.message } }
}
extension Components.Responses.BackendError.Body: _HasJsonErrorBody {
    var errorMessage: String { get throws { try json.error.message } }
}

/// Extract `.json` from a generated body enum or throw `.decoding` — an
/// off-contract content type is a decoding failure, not a transport one.
private func jsonBody<Body, Payload>(
    _ body: Body,
    _ extract: (Body) throws -> Payload
) throws(KdsAPIError) -> Payload {
    do { return try extract(body) } catch {
        throw .decoding(underlying: String(describing: error))
    }
}

private func jsonBody(_ body: Operations.ListKdsStations.Output.Ok.Body) throws(KdsAPIError) -> Components.Schemas.StationsResponse {
    try jsonBody(body) { try $0.json }
}
private func jsonBody(_ body: Operations.ListActiveTickets.Output.Ok.Body) throws(KdsAPIError) -> Components.Schemas.ActiveTicketsResponse {
    try jsonBody(body) { try $0.json }
}
private func jsonBody(_ body: Operations.ApplyTicketAction.Output.Conflict.Body) throws(KdsAPIError) -> Components.Schemas.ErrorResponse {
    try jsonBody(body) { try $0.json }
}

private extension Date {
    /// Idempotency token: ISO-8601 filtered to alphanumerics, stable for a
    /// fixed `occurredAt` (port of `Instant.toIdempotencyToken`).
    var idempotencyToken: String {
        iso8601String.filter { $0.isLetter || $0.isNumber }
    }

    private var iso8601String: String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: self
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            components.year ?? 0, components.month ?? 0, components.day ?? 0,
            components.hour ?? 0, components.minute ?? 0, components.second ?? 0
        )
    }
}
