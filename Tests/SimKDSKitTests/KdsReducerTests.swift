import Foundation
import Testing
@testable import SimKDSKit

/// Port of `KdsReducerTest.kt`. Payment/fiscal-gate cases are inverted on
/// purpose: Generic KDS treats them as display metadata — the backend owns
/// visibility (delta 5), so "unpaid" tickets stay on the board.
@Suite("KdsReducer")
struct KdsReducerTests {
    let baseTime = Fixtures.baseTime

    @Test func paidAcceptedNewTicketAppearsInNewColumn() {
        let board = KdsReducer.visibleBoard([Fixtures.ticket("A-42", status: .new)])
        #expect(Fixtures.displayNumbers(board.new) == ["A-42"])
        #expect(board.inProgress.isEmpty)
        #expect(board.ready.isEmpty)
    }

    @Test func startMovesTicketFromNewToInProgress() {
        let ticket = Fixtures.ticket("A-42", status: .new)
        let updated = KdsReducer.reduce([ticket], .start(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: nil, occurredAt: baseTime
        ))
        let board = KdsReducer.visibleBoard(updated)
        #expect(board.new.isEmpty)
        #expect(Fixtures.displayNumbers(board.inProgress) == ["A-42"])
    }

    @Test func actionAddressesTicketByStableIdNotDisplayNumber() {
        // Display numbers can collide across sources; the wire id decides.
        var collision = Fixtures.ticket("A-42", status: .new)
        collision.id = "ticket-old"
        var target = Fixtures.ticket("A-42", status: .new)
        target.id = "ticket-new"

        let updated = KdsReducer.reduce([collision, target], .start(
            ticketId: "ticket-new", displayNumber: "A-42", expectedVersion: nil, occurredAt: baseTime
        ))

        #expect(updated.first { $0.id == "ticket-old" }?.status == .new)
        #expect(updated.first { $0.id == "ticket-new" }?.status == .inProgress)
    }

    @Test func markReadyMovesTicketFromInProgressToReady() {
        let ticket = Fixtures.ticket("A-42", status: .inProgress)
        let updated = KdsReducer.reduce([ticket], .markReady(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: nil, occurredAt: baseTime
        ))
        let board = KdsReducer.visibleBoard(updated)
        #expect(board.inProgress.isEmpty)
        #expect(Fixtures.displayNumbers(board.ready) == ["A-42"])
    }

    @Test func completeHidesTicketFromActiveBoard() {
        let ticket = Fixtures.ticket("A-42", status: .ready)
        let updated = KdsReducer.reduce([ticket], .complete(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: nil, occurredAt: baseTime
        ))
        let board = KdsReducer.visibleBoard(updated)
        #expect(updated.single().status == .completed)
        #expect(board.new.isEmpty && board.inProgress.isEmpty && board.ready.isEmpty)
    }

    @Test func acceptedActionsAdvanceOptimisticVersionForNextBackendAction() {
        let ticket = Fixtures.ticket("A-42", status: .new, version: 3)
        let startedAt = baseTime.addingTimeInterval(10)
        let readyAt = baseTime.addingTimeInterval(20)
        let completedAt = baseTime.addingTimeInterval(30)

        let started = KdsReducer.reduce([ticket], .start(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: 3, occurredAt: startedAt
        )).single()
        let ready = KdsReducer.reduce([started], .markReady(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: 4, occurredAt: readyAt
        )).single()
        let completed = KdsReducer.reduce([ready], .complete(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: 5, occurredAt: completedAt
        )).single()

        #expect(started.status == .inProgress && started.version == 4)
        #expect(ready.status == .ready && ready.version == 5)
        #expect(completed.status == .completed && completed.version == 6)
    }

    @Test func acceptedActionDoesNotRollbackNewerLocalVersion() {
        let ticket = Fixtures.ticket("A-42", status: .new, version: 5)
        let updated = KdsReducer.reduce([ticket], .start(
            ticketId: ticket.id, displayNumber: "A-42", expectedVersion: 3, occurredAt: baseTime
        )).single()
        #expect(updated.status == .inProgress)
        #expect(updated.version == 5)
    }

    @Test func paymentAndFiscalMetadataDoNotGateVisibility() {
        // Kotlin hid these behind `requiresPaymentFiscalGate`; Generic KDS
        // leaves visibility to the backend, so they stay visible here.
        let unpaid = Fixtures.ticket("A-42", status: .new, paymentState: .pending, fiscalState: .accepted)
        let fiscalPending = Fixtures.ticket("M-11", status: .new, paymentState: .paid, fiscalState: .pending)
        let accepted = Fixtures.ticket("A-43", status: .new, paymentState: .paid, fiscalState: .accepted)

        let board = KdsReducer.visibleBoard([unpaid, fiscalPending, accepted])

        #expect(Fixtures.displayNumbers(board.new) == ["A-42", "M-11", "A-43"])
    }

    @Test func unavailableTicketOrLineIsNotVisible() {
        var unavailableTicket = Fixtures.ticket("U-1", status: .new)
        unavailableTicket.availabilityState = .unavailable
        let unavailableLine = Fixtures.ticket("U-2", status: .new, items: [
            KdsTicketItem(name: "Какао", quantity: 1, availabilityState: .unavailable),
        ])
        let accepted = Fixtures.ticket("A-10", status: .new)

        let board = KdsReducer.visibleBoard([unavailableTicket, unavailableLine, accepted])

        #expect(Fixtures.displayNumbers(board.new) == ["A-10"])
    }

    @Test func visibleTicketsAreSortedByVisibleAt() {
        let later = Fixtures.ticket("A-43", status: .new, visibleAt: baseTime.addingTimeInterval(60))
        let earlier = Fixtures.ticket("A-42", status: .new, visibleAt: baseTime)
        let board = KdsReducer.visibleBoard([later, earlier])
        #expect(Fixtures.displayNumbers(board.new) == ["A-42", "A-43"])
    }

    @Test func activeTicketsFlattensVisibleBoardForTicketDetails() {
        let newTicket = Fixtures.ticket("A-42", status: .new, visibleAt: baseTime)
        let inProgress = Fixtures.ticket("A-43", status: .inProgress, visibleAt: baseTime.addingTimeInterval(5))
        let ready = Fixtures.ticket("A-44", status: .ready, visibleAt: baseTime.addingTimeInterval(10))
        let board = KdsReducer.visibleBoard([ready, inProgress, newTicket])
        #expect(Fixtures.displayNumbers(board.activeTickets) == ["A-42", "A-43", "A-44"])
    }

    @Test func blockedRecoveryTicketIsNotVisibleOnKitchenBoard() {
        let blocked = Fixtures.ticket("A-45", status: .blocked, fiscalState: .needsOperator)
        let board = KdsReducer.visibleBoard([blocked])
        #expect(board.activeTickets.isEmpty)
        #expect(board.new.isEmpty && board.inProgress.isEmpty && board.ready.isEmpty)
    }

    @Test func duplicateRemoteTicketUpdatesExistingTicket() {
        let existing = Fixtures.ticket("A-42", status: .new)
        var remoteUpdate = existing
        remoteUpdate.source = .online
        remoteUpdate.items = [KdsTicketItem(name: "Раф ванильный", quantity: 2)]

        let merged = KdsReducer.mergeRemoteTicket([existing], remoteTicket: remoteUpdate)

        #expect(merged.count == 1)
        #expect(merged.single().source == .online)
        #expect(merged.single().items.single().name == "Раф ванильный")
        #expect(merged.single().items.single().quantity == 2)
    }

    @Test func remoteUpdateDoesNotRollbackLocalStatusProgress() {
        let local = Fixtures.ticket("A-42", status: .ready)
        var staleRemote = local
        staleRemote.status = .new

        let merged = KdsReducer.mergeRemoteTicket([local], remoteTicket: staleRemote)

        #expect(merged.single().status == .ready)
    }

    @Test func completedTicketRemainsHiddenAfterRemoteUpdate() {
        let completed = Fixtures.ticket("A-42", status: .completed)
        var staleRemote = completed
        staleRemote.status = .inProgress

        let merged = KdsReducer.mergeRemoteTicket([completed], remoteTicket: staleRemote)
        let board = KdsReducer.visibleBoard(merged)

        #expect(merged.single().status == .completed)
        #expect(board.new.isEmpty && board.inProgress.isEmpty && board.ready.isEmpty)
    }

    @Test func remoteRefundedStateDoesNotResurrectCompletedTicketAsActive() {
        let completed = Fixtures.ticket("A-42", status: .completed, paymentState: .paid)
        var refundedRemote = completed
        refundedRemote.status = .inProgress
        refundedRemote.paymentState = .refunded

        let merged = KdsReducer.mergeRemoteTicket([completed], remoteTicket: refundedRemote)
        let board = KdsReducer.visibleBoard(merged)

        #expect(merged.single().status == .completed)
        #expect(merged.single().paymentState == .refunded)
        #expect(board.activeTickets.isEmpty)
    }

    @Test func cancelledRemoteStateWinsOverActiveLocalState() {
        let active = Fixtures.ticket("A-42", status: .inProgress, paymentState: .paid)
        var cancelledRemote = active
        cancelledRemote.status = .cancelled
        cancelledRemote.paymentState = .refunded

        let merged = KdsReducer.mergeRemoteTicket([active], remoteTicket: cancelledRemote)
        let board = KdsReducer.visibleBoard(merged)

        #expect(merged.single().status == .cancelled)
        #expect(merged.single().paymentState == .refunded)
        #expect(board.activeTickets.isEmpty)
    }

    @Test func blockedTicketCanRecoverFromFreshRemoteStatus() {
        let blocked = Fixtures.ticket("A-42", status: .blocked, fiscalState: .needsOperator)
        var recovered = blocked
        recovered.status = .new
        recovered.fiscalState = .accepted
        recovered.version = 2

        let merged = KdsReducer.mergeRemoteTicket([blocked], remoteTicket: recovered)
        let board = KdsReducer.visibleBoard(merged)

        #expect(merged.single().status == .new)
        #expect(Fixtures.displayNumbers(board.new) == ["A-42"])
    }
}

private extension Array {
    func single() -> Element {
        precondition(count == 1)
        return self[0]
    }
}
