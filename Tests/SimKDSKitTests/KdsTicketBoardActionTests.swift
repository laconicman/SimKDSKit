import Foundation
import Testing
@testable import SimKDSKit

/// Port of `KdsTicketBoardActionTest.kt`.
@Suite("KdsTicketBoardAction")
struct KdsTicketBoardActionTests {
    let now = Date(timeIntervalSince1970: 1_784_149_200) // 2026-05-27T21:00:00Z

    @Test func newTicketsExposeStartAction() {
        let ticket = Fixtures.ticket("A-01", status: .new, version: 7)

        let presentation = ticket.boardActionPresentation(now: now)

        #expect(presentation.label == "▶  Начать")
        #expect(presentation.action == .start(
            ticketId: "ticket-A-01",
            displayNumber: "A-01",
            expectedVersion: 7,
            occurredAt: now
        ))
    }

    @Test func inProgressTicketsExposeReadyAction() {
        let ticket = Fixtures.ticket("A-02", status: .inProgress, version: 8)

        let presentation = ticket.boardActionPresentation(now: now)

        #expect(presentation.label == "Готово")
        #expect(presentation.action == .markReady(
            ticketId: "ticket-A-02",
            displayNumber: "A-02",
            expectedVersion: 8,
            occurredAt: now
        ))
    }

    @Test func readyHistoryTicketsDoNotExposeActions() {
        let presentation = Fixtures.ticket("R-01", status: .ready, version: 9)
            .boardActionPresentation(now: now)

        #expect(presentation.action == nil)
        #expect(presentation.label == nil)
    }

    @Test func terminalAndBlockedTicketsDoNotExposeTicketActions() {
        for ticket in [
            Fixtures.ticket("B-01", status: .blocked),
            Fixtures.ticket("C-01", status: .completed),
            Fixtures.ticket("X-01", status: .cancelled),
        ] {
            let presentation = ticket.boardActionPresentation(now: now)
            #expect(presentation.action == nil)
            #expect(presentation.label == nil)
        }
    }
}
