import Foundation
import Testing
@testable import SimKDSKit

/// Smoke tests proving the generated surface is decodable/compilable — the
/// scaffold's whole claim. Behavioural coverage arrives with the domain and
/// API layers; these guard only that the vendored contract generated the
/// shapes the mapper will rely on.
@Suite("Generated surface")
struct GeneratedSurfaceTests {
    @Test func decodesActiveTicketsFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "active-tickets", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(Components.Schemas.ActiveTicketsResponse.self, from: Data(contentsOf: url))

        #expect(response.tickets.count == 2)
        let first = response.tickets[0]
        #expect(first.ticketId == "ticket_1001")
        #expect(first.kitchenState == .new)
        #expect(first.source == .app)
        #expect(first.items.count == 2)
        #expect(first.items[0].recipeLines == ["heat milk to 65°C", "pull double shot"])
        #expect(first.items[0].quantity == 1)
        // Wire value `in_progress` must land on the idiomatic `.inProgress`.
        #expect(response.tickets[1].kitchenState == .inProgress)
    }

    @Test func encodesActionRequestWireShape() throws {
        let occurredAt = Date(timeIntervalSince1970: 1_783_200_000)
        let request = Components.Schemas.TicketActionRequest(
            stationId: "station_bar_hot",
            deviceId: "tablet_bar_01",
            actorId: "barista_01",
            action: .markReady,
            expectedVersion: 3,
            occurredAt: occurredAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(request))
        let object = try #require(raw as? [String: Any])

        // Wire key is `mark_ready`, not the Swift case name — the field the
        // backend dispatches on, so it is pinned here.
        #expect(object["action"] as? String == "mark_ready")
        #expect(object["stationId"] as? String == "station_bar_hot")
        #expect(object["expectedVersion"] as? Int == 3)
        #expect(object["occurredAt"] as? String != nil)
    }
}
