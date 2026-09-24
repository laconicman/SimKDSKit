import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import SimKDSKit

// MARK: - Shared fixture

private let context = KdsContext(
    locationId: "loc_1",
    stationId: "station_bar_hot",
    deviceId: "ipad-bar-1",
    deviceName: "Bar iPad",
    actorId: "op-7",
    backendMode: .real
)

private let serverURL = URL(string: "https://kds.example.com")!

private func api(
    _ transport: any ClientTransport,
    credentials: KdsCredentials? = nil
) -> any KdsAPI {
    KdsAPIs.make(serverURL: serverURL, credentials: credentials, transport: transport)
}

private extension HTTPRequest {
    func header(_ name: String) -> String? {
        headerFields[HTTPField.Name(name)!]
    }
}

// MARK: - Auth middleware

@Suite("Auth middleware")
struct AuthMiddlewareTests {
    @Test("Bearer credential sets Authorization")
    func bearer() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder), credentials: .bearer("s3cret"))

        _ = try await client.fetchActiveTickets(context: context)

        let request = try #require(await recorder.request)
        #expect(request.header("Authorization") == "Bearer s3cret")
        #expect(request.header("X-SimKDS-Api-Key") == nil)
    }

    @Test("API-key credential sets X-SimKDS-Api-Key")
    func apiKey() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder), credentials: .apiKey("k3y"))

        _ = try await client.fetchActiveTickets(context: context)

        let request = try #require(await recorder.request)
        #expect(request.header("X-SimKDS-Api-Key") == "k3y")
        #expect(request.header("Authorization") == nil)
    }

    @Test("No credential sends no auth header")
    func none() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder))

        _ = try await client.fetchActiveTickets(context: context)

        let request = try #require(await recorder.request)
        #expect(request.header("Authorization") == nil)
        #expect(request.header("X-SimKDS-Api-Key") == nil)
    }
}

// MARK: - Context headers and request shape

@Suite("Request headers")
struct RequestHeaderTests {
    @Test("Stations: locationId query plus context headers")
    func stations() async throws {
        let recorder = RequestRecorder()
        let client = api(
            RecordingTransport(recorder: recorder, json: #"{"stations":[]}"#)
        )

        _ = try await client.fetchStations(context: context)

        let request = try #require(await recorder.request)
        #expect(request.path == "/api/v1/kds/stations?locationId=loc_1")
        #expect(request.header("X-SimKDS-Location-Id") == "loc_1")
        #expect(request.header("X-SimKDS-Device-Id") == "ipad-bar-1")
        // The generator percent-encodes header values on the wire.
        #expect(request.header("X-SimKDS-Device-Name") == "Bar%20iPad")
        #expect(request.header("X-SimKDS-Station-Id") == nil) // no station on the directory call
    }

    @Test("Active tickets: station in path, all context headers")
    func tickets() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder))

        _ = try await client.fetchActiveTickets(context: context)

        let request = try #require(await recorder.request)
        #expect(request.path == "/api/v1/kds/stations/station_bar_hot/tickets/active")
        #expect(request.header("X-SimKDS-Station-Id") == "station_bar_hot")
        #expect(request.header("X-SimKDS-Location-Id") == "loc_1")
        #expect(request.header("X-SimKDS-Device-Id") == "ipad-bar-1")
    }

    @Test("Action: idempotency/request-id headers and wire body")
    func action() async throws {
        let recorder = RequestRecorder()
        let client = api(
            RecordingTransport(recorder: recorder, status: .noContent, json: "")
        )
        let occurredAt = Date(timeIntervalSince1970: 1_783_200_000) // stable → stable key

        try await client.applyTicketAction(
            .markReady(ticketId: "t-1", displayNumber: "A-1", expectedVersion: 4, occurredAt: occurredAt),
            context: context
        )

        let request = try #require(await recorder.request)
        #expect(request.path == "/api/v1/kds/tickets/t-1/actions")
        #expect(request.method == .post)
        let idempotency = try #require(request.header("Idempotency-Key"))
        #expect(idempotency.hasPrefix("kds_action_ipad-bar-1_t-1_mark_ready_4_"))
        #expect(request.header("X-Request-Id") == "req_\(idempotency)")

        let body = try #require(await recorder.requestBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        #expect(json["action"] as? String == "mark_ready")
        #expect(json["stationId"] as? String == "station_bar_hot")
        #expect(json["deviceId"] as? String == "ipad-bar-1")
        #expect(json["actorId"] as? String == "op-7")
        #expect(json["expectedVersion"] as? Int == 4)
        #expect(json["occurredAt"] as? String == "2026-07-04T21:20:00Z")
    }

    @Test("Same inputs give the same idempotency key; different occurredAt changes it")
    func idempotencyStability() async throws {
        let recorder = RequestRecorder()
        let transport = RecordingTransport(recorder: recorder, status: .noContent, json: "")
        let client = api(transport)
        let at = Date(timeIntervalSince1970: 1_783_200_000)

        try await client.applyTicketAction(
            .start(ticketId: "t-9", displayNumber: "A-9", expectedVersion: nil, occurredAt: at),
            context: context
        )
        let first = await recorder.request?.header("Idempotency-Key")

        try await client.applyTicketAction(
            .start(ticketId: "t-9", displayNumber: "A-9", expectedVersion: nil, occurredAt: at),
            context: context
        )
        let second = await recorder.request?.header("Idempotency-Key")
        #expect(first == second)
        #expect(first?.contains("unversioned") == true)

        try await client.applyTicketAction(
            .start(ticketId: "t-9", displayNumber: "A-9", expectedVersion: nil, occurredAt: at.addingTimeInterval(60)),
            context: context
        )
        let third = await recorder.request?.header("Idempotency-Key")
        #expect(third != first)
    }
}

// MARK: - Status → error mapping

@Suite("Status mapping")
struct StatusMappingTests {
    private func actionApi(status: HTTPResponse.Status, json: String = "") -> any KdsAPI {
        api(StubTransport(status: status, json: json))
    }

    private let action = KdsAction.complete(
        ticketId: "t-1", displayNumber: "A-1", expectedVersion: 2,
        occurredAt: Date(timeIntervalSince1970: 1_783_200_000)
    )

    @Test("200/202/204 all succeed", arguments: [HTTPResponse.Status.ok, .accepted, .noContent])
    func successStatuses(status: HTTPResponse.Status) async throws {
        // 200 and 202 carry a TicketActionResponse body; 204 carries none.
        let json = status == .noContent ? "" : #"{"ok":true,"ticketId":"t-1"}"#
        try await actionApi(status: status, json: json)
            .applyTicketAction(action, context: context)
    }

    @Test("409 stale_version maps to a refresh-requesting conflict")
    func staleVersion() async throws {
        let client = actionApi(
            status: .conflict,
            json: #"{"error":{"code":"stale_version","message":"expected 2, got 5"}}"#
        )
        do {
            try await client.applyTicketAction(action, context: context)
            Issue.record("expected conflict")
        } catch {
            guard case let .conflict(code, message) = error else {
                Issue.record("expected .conflict, got \(error)")
                return
            }
            #expect(code == .staleVersion)
            #expect(code.requiresRefresh)
            #expect(message == "expected 2, got 5")
        }
    }

    @Test("409 station_mismatch requires refresh; idempotency_conflict does not",
          arguments: [("station_mismatch", KdsConflictCode.stationMismatch, true),
                      ("idempotency_conflict", KdsConflictCode.idempotencyConflict, false)])
    func conflictCodes(wire: String, code: KdsConflictCode, refreshes: Bool) async throws {
        let client = actionApi(
            status: .conflict,
            json: #"{"error":{"code":"\#(wire)","message":"m"}}"#
        )
        do {
            try await client.applyTicketAction(action, context: context)
            Issue.record("expected conflict")
        } catch {
            guard case let .conflict(mapped, _) = error else {
                Issue.record("expected .conflict, got \(error)")
                return
            }
            #expect(mapped == code)
            #expect(error.requiresRefresh == refreshes)
        }
    }

    @Test("409 without a documented code is conflict(.unknown), no refresh")
    func unknownConflict() async throws {
        let client = actionApi(
            status: .conflict,
            json: #"{"error":{"code":"device_station_mismatch","message":"m"}}"#
        )
        do {
            try await client.applyTicketAction(action, context: context)
            Issue.record("expected conflict")
        } catch {
            guard case let .conflict(code, _) = error else {
                Issue.record("expected .conflict, got \(error)")
                return
            }
            #expect(code == .unknown)
            #expect(!error.requiresRefresh)
        }
    }

    @Test("401/403/404/422/500 map to their documented cases",
          arguments: [
              (HTTPResponse.Status.unauthorized, #"{"error":{"code":"unauthorized","message":"bad token"}}"#),
              (.forbidden, #"{"error":{"code":"forbidden","message":"no"}}"#),
              (.notFound, #"{"error":{"code":"not_found","message":"gone"}}"#),
              (.unprocessableContent, #"{"error":{"code":"validation_error","message":"bad field"}}"#),
              (.internalServerError, #"{"error":{"code":"backend_error","message":"boom"}}"#),
          ])
    func documentedErrors(status: HTTPResponse.Status, json: String) async throws {
        let client = actionApi(status: status, json: json)
        do {
            try await client.applyTicketAction(action, context: context)
            Issue.record("expected error for \(status.code)")
        } catch {
            switch (status, error) {
            case (.unauthorized, .unauthorized),
                 (.forbidden, .forbidden),
                 (.notFound, .notFound),
                 (.unprocessableContent, .validationError),
                 (.internalServerError, .backendError):
                break
            default:
                Issue.record("status \(status.code) mapped to \(error)")
            }
        }
    }

    @Test("Undocumented status surfaces as .undocumented")
    func undocumented() async throws {
        let client = actionApi(status: HTTPResponse.Status(code: 418), json: "{}")
        do {
            try await client.applyTicketAction(action, context: context)
            Issue.record("expected undocumented")
        } catch {
            guard case let .undocumented(code) = error else {
                Issue.record("expected .undocumented, got \(error)")
                return
            }
            #expect(code == 418)
        }
    }

    @Test("Malformed feed payload is .decoding, not a crash")
    func malformedFeed() async throws {
        let client = api(StubTransport(status: .ok, json: #"{"tickets":[{"bogus":1}]}"#))
        do {
            _ = try await client.fetchActiveTickets(context: context)
            Issue.record("expected decoding error")
        } catch {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("Transport failure is .transport")
    func transportFailure() async throws {
        let client = api(FailingTransport())
        do {
            _ = try await client.fetchActiveTickets(context: context)
            Issue.record("expected transport error")
        } catch {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
    }

    @Test("A failure never puts the credential in its error message")
    func errorsDoNotLeakCredential() async throws {
        let token = "s3cret-token-that-must-not-appear-anywhere"
        let client = api(FailingTransport(), credentials: .bearer(token))
        do {
            _ = try await client.fetchActiveTickets(context: context)
            Issue.record("expected transport error")
        } catch {
            let rendered = "\(error) \(error.localizedDescription)"
            #expect(!rendered.contains(token))
            #expect(!rendered.lowercased().contains("bearer"))
        }
    }
}

// MARK: - Local validation

@Suite("Local validation")
struct LocalValidationTests {
    private let action = KdsAction.start(
        ticketId: "t-1", displayNumber: "A-1", expectedVersion: nil,
        occurredAt: Date(timeIntervalSince1970: 1_783_200_000)
    )

    @Test("Blank stationId rejects before the wire")
    func blankStation() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder))
        var bad = context
        bad.stationId = "  "

        do {
            _ = try await client.fetchActiveTickets(context: bad)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
        #expect(await recorder.request == nil) // nothing went on the wire
    }

    @Test("Placeholder deviceId rejects")
    func placeholderDevice() async throws {
        var bad = context
        bad.deviceId = "todo"
        do {
            _ = try await api(StubTransport(json: #"{"tickets":[]}"#))
                .fetchActiveTickets(context: bad)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
    }

    @Test("Action without actorId rejects; fetch does not")
    func actorRequiredForAction() async throws {
        var noActor = context
        noActor.actorId = ""
        let client = api(StubTransport(json: #"{"tickets":[]}"#))

        _ = try await client.fetchActiveTickets(context: noActor) // fetch is fine

        do {
            try await client.applyTicketAction(action, context: noActor)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
    }

    @Test("Blank locationId rejects before the wire")
    func blankLocation() async throws {
        let recorder = RequestRecorder()
        let client = api(RecordingTransport(recorder: recorder))
        var bad = context
        bad.locationId = ""

        do {
            _ = try await client.fetchStations(context: bad)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
        do {
            _ = try await client.fetchActiveTickets(context: bad)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
        #expect(await recorder.request == nil)
    }

    @Test("HTTPS URL without a host fails settings preflight")
    func hostlessHttps() {
        var settings = KdsDeviceSettings(
            apiBaseUrl: "https://", locationId: "l", deviceId: "d", backendMode: .real
        )
        #expect(KdsRuntimeContextValidation.requestError(settings) != nil)
        settings.apiBaseUrl = "https:///path-only"
        #expect(KdsRuntimeContextValidation.requestError(settings) != nil)
        settings.apiBaseUrl = "https://kds.example.test"
        #expect(KdsRuntimeContextValidation.requestError(settings) == nil)
    }
}

// MARK: - Mapping and sanitization

@Suite("Mapping and sanitization")
struct MappingTests {
    private func ticketsApi(json: String) -> any KdsAPI {
        api(StubTransport(json: json))
    }

    @Test("delivery source maps to the online channel")
    func deliveryIsOnline() async throws {
        let client = ticketsApi(json: """
        {"tickets":[{"ticketId":"t-d","displayNumber":"D-1","stationId":"station_bar_hot",
        "source":"delivery","kitchenState":"new","visibleAt":"2026-07-09T10:00:00Z","items":[]}]}
        """)
        let tickets = try await client.fetchActiveTickets(context: context)
        #expect(tickets.first?.source == .online)
    }

    @Test("completed + refunded displays as cancelled (Kotlin quirk kept)")
    func completedRefunded() async throws {
        let client = ticketsApi(json: """
        {"tickets":[{"ticketId":"t-r","displayNumber":"R-1","stationId":"s",
        "source":"pos","kitchenState":"completed","visibleAt":"2026-07-09T10:00:00Z",
        "metadata":{"paymentState":"refunded"},"items":[]}]}
        """)
        let tickets = try await client.fetchActiveTickets(context: context)
        #expect(tickets.first?.status == .cancelled)
    }

    @Test("Sensitive strings never reach the board")
    func sanitization() async throws {
        let client = ticketsApi(json: """
        {"tickets":[{"ticketId":"t-s","displayNumber":"S-1","stationId":"s",
        "source":"pos","kitchenState":"new","visibleAt":"2026-07-09T10:00:00Z",
        "customerName":"guest_8842@mail.ru",
        "items":[{"lineId":"l1","name":"order_id=99112233","quantity":1,
        "modifiers":["t.me/evil","овсяное молоко"],"comment":"+7 999 123-45-67"}]}]}
        """)
        let ticket = try #require(try await client.fetchActiveTickets(context: context).first)
        #expect(ticket.customerName == nil)            // guest_* prefix dropped
        #expect(ticket.items.first?.name == "Позиция") // id-looking name → placeholder
        #expect(ticket.items.first?.modifiers == ["овсяное молоко"]) // t.me scrubbed
        #expect(ticket.items.first?.comment == nil)    // phone scrubbed
    }

    @Test("Missing metadata yields nil payment/fiscal")
    func noMetadata() async throws {
        let client = ticketsApi(json: """
        {"tickets":[{"ticketId":"t-m","displayNumber":"M-1","stationId":"s",
        "source":"web","kitchenState":"in_progress","visibleAt":"2026-07-09T10:00:00Z","items":[]}]}
        """)
        let ticket = try #require(try await client.fetchActiveTickets(context: context).first)
        #expect(ticket.paymentState == nil)
        #expect(ticket.fiscalState == nil)
        #expect(ticket.status == .inProgress)
    }

    @Test("Fractional quantities survive mapping")
    func fractionalQuantity() async throws {
        let client = ticketsApi(json: """
        {"tickets":[{"ticketId":"t-w","displayNumber":"W-1","stationId":"s",
        "source":"pos","kitchenState":"new","visibleAt":"2026-07-09T10:00:00Z",
        "items":[{"lineId":"l1","name":"Взвешенный товар","quantity":0.5}]}]}
        """)
        let ticket = try #require(try await client.fetchActiveTickets(context: context).first)
        #expect(ticket.items.first?.quantity == 0.5)
    }

    @Test("Stations sort by sortOrder, inactive entries drop out")
    func stationDirectory() async throws {
        let client = api(StubTransport(json: """
        {"stations":[
          {"stationId":"s2","route":"r2","label":"B","displayName":"Second",
           "sortOrder":20,"activeTicketsPath":"/p2","isActive":true},
          {"stationId":"s1","route":"r1","label":"A","displayName":"First",
           "sortOrder":10,"activeTicketsPath":"/p1","isActive":true},
          {"stationId":"s0","route":"r0","label":"X","displayName":"Dead",
           "sortOrder":1,"activeTicketsPath":"/p0","isActive":false}
        ]}
        """))
        let directory = try await client.fetchStations(context: context)
        #expect(directory.map(\.stationId) == ["s1", "s2"])
        #expect(directory.first?.displayName == "First")
    }
}

// MARK: - Mock backend

@Suite("Mock backend")
struct MockKdsAPITests {
    @Test("Seeds carry the scripted tickets; refresh upserts the trio")
    func refreshInjects() async throws {
        let mock = MockKdsAPI(now: Date(timeIntervalSince1970: 1_783_200_000))
        let seeded = try await mock.fetchActiveTickets(context: context)
        #expect(seeded.count == 4)

        let after = try await mock.refresh(context: context)
        let numbers = after.map(\.displayNumber)
        #expect(numbers.contains("A-44"))
        #expect(numbers.contains("M-13"))
        // ticket-hidden re-emitted as paid/accepted
        let hidden = try #require(after.first { $0.id == "ticket-hidden" })
        #expect(hidden.paymentState == .paid)
        #expect(await mock.refreshCount == 1)
        #expect(await mock.fetchCount == 1)
    }

    @Test("failNextAction fires once then clears")
    func failNext() async throws {
        let mock = MockKdsAPI(now: Date())
        let action = KdsAction.start(
            ticketId: "t-1", displayNumber: "A-1", expectedVersion: nil, occurredAt: Date()
        )
        await mock.failNextAction("boom")
        do {
            try await mock.applyTicketAction(action, context: context)
            Issue.record("expected failure")
        } catch {
            guard case let .backendError(message) = error else {
                Issue.record("expected .backendError, got \(error)")
                return
            }
            #expect(message == "boom")
        }
        try await mock.applyTicketAction(action, context: context) // second call succeeds
        #expect(await mock.sentActions.count == 2)
    }

    @Test("Mode switch sends mock contexts to the mock, real to live")
    func modeSwitch() async throws {
        let recorder = RequestRecorder()
        let mock = MockKdsAPI(now: Date())
        let switching = ModeSwitchingKdsAPI(
            mock: mock,
            live: LiveKdsAPI(client: Client(
                serverURL: serverURL, credentials: nil,
                transport: RecordingTransport(recorder: recorder)
            ))
        )
        var mockContext = context
        mockContext.backendMode = .mock

        _ = try await switching.fetchActiveTickets(context: mockContext)
        #expect(await mock.fetchCount == 1)
        #expect(await recorder.request == nil) // nothing touched the wire

        _ = try await switching.fetchActiveTickets(context: context)
        #expect(await recorder.request != nil)
    }
}

// MARK: - Factory

@Suite("KdsAPIs.make")
struct FactoryTests {
    @Test("Malformed apiBaseUrl is .localValidation, not a crash")
    func badUrl() throws {
        let settings = KdsDeviceSettings(
            apiBaseUrl: "ht!tp://not a url", locationId: "l", stationId: "s",
            stationLabel: "S", deviceName: "d", deviceId: "d",
            actorId: "a", backendMode: .real
        )
        do {
            _ = try KdsAPIs.make(settings: settings, credentials: nil)
            Issue.record("expected localValidation")
        } catch {
            #expect(error.isLocalValidationFailure)
        }
    }
}
