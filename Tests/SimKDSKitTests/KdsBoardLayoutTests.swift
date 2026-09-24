import Foundation
import Testing
@testable import SimKDSKit

/// Port of `KdsBoardLayoutTest.kt`. The `statusUpdatedAt` cases collapse into
/// one: with the field deleted, the first snapshot itself is the freeze.
@Suite("KdsBoardLayout")
struct KdsBoardLayoutTests {
    let baseTime = Fixtures.baseTime

    @Test func distributesNewTicketsAcrossThreeColumnsInCreationOrder() {
        let layout = KdsBoardLayout(tickets: [
            Fixtures.ticket("A-01", status: .new, visibleAt: baseTime),
            Fixtures.ticket("A-02", status: .new, visibleAt: baseTime.addingTimeInterval(10)),
            Fixtures.ticket("A-03", status: .new, visibleAt: baseTime.addingTimeInterval(20)),
            Fixtures.ticket("A-04", status: .new, visibleAt: baseTime.addingTimeInterval(30)),
        ])

        #expect(Fixtures.displayNumbers(layout.newColumnA) == ["A-01", "A-04"])
        #expect(Fixtures.displayNumbers(layout.newColumnB) == ["A-02"])
        #expect(Fixtures.displayNumbers(layout.newColumnC) == ["A-03"])
    }

    @Test func keepsInProgressTicketsInSingleWaveColumn() {
        let layout = KdsBoardLayout(tickets: [
            Fixtures.ticket("A-01", status: .new, visibleAt: baseTime),
            Fixtures.ticket("A-02", status: .inProgress, visibleAt: baseTime.addingTimeInterval(5)),
            Fixtures.ticket("A-03", status: .new, visibleAt: baseTime.addingTimeInterval(10)),
            Fixtures.ticket("A-04", status: .inProgress, visibleAt: baseTime.addingTimeInterval(15)),
        ])

        #expect(Fixtures.displayNumbers(layout.inProgress) == ["A-02", "A-04"])
        #expect(Fixtures.displayNumbers(layout.newColumnA) == ["A-01"])
        #expect(Fixtures.displayNumbers(layout.newColumnB) == ["A-03"])
        #expect(layout.newColumnC.isEmpty)
    }

    @Test func doesNotPlaceBlockedTicketsOnKitchenLayout() {
        let layout = KdsBoardLayout(tickets: [
            Fixtures.ticket("A-01", status: .blocked, visibleAt: baseTime.addingTimeInterval(10)),
            Fixtures.ticket("A-02", status: .inProgress, visibleAt: baseTime.addingTimeInterval(5)),
            Fixtures.ticket("A-03", status: .blocked, visibleAt: baseTime.addingTimeInterval(20)),
        ])

        #expect(Fixtures.displayNumbers(layout.inProgress) == ["A-02"])
        #expect(layout.newColumnA.isEmpty && layout.newColumnB.isEmpty && layout.newColumnC.isEmpty)
    }

    @Test func freezesReadyElapsedTimeAcrossClockTicks() {
        let ticket = Fixtures.ticket("R-01", status: .ready, visibleAt: baseTime.addingTimeInterval(30))
        let first = KdsBoardLayout.snapshotReadyWaitDurations(
            readyTickets: [ticket], now: baseTime.addingTimeInterval(90), previous: [:]
        )
        let second = KdsBoardLayout.snapshotReadyWaitDurations(
            readyTickets: [ticket], now: baseTime.addingTimeInterval(150), previous: first
        )

        #expect(first["ticket-R-01"] == .seconds(60))
        #expect(second["ticket-R-01"] == .seconds(60))
    }

    @Test func preservesReadyElapsedSnapshotForMultipleTicketsAfterClockAdvance() {
        let tickets = [
            Fixtures.ticket("R-01", status: .ready, visibleAt: baseTime.addingTimeInterval(10)),
            Fixtures.ticket("R-02", status: .ready, visibleAt: baseTime.addingTimeInterval(20)),
        ]
        let snapshot = KdsBoardLayout.snapshotReadyWaitDurations(
            readyTickets: tickets, now: baseTime.addingTimeInterval(100), previous: [:]
        )
        let second = KdsBoardLayout.snapshotReadyWaitDurations(
            readyTickets: tickets, now: baseTime.addingTimeInterval(300), previous: snapshot
        )

        #expect(snapshot["ticket-R-01"] == .seconds(90))
        #expect(snapshot["ticket-R-02"] == .seconds(80))
        #expect(second["ticket-R-01"] == .seconds(90))
        #expect(second["ticket-R-02"] == .seconds(80))
    }

    @Test func keepsReadyLayoutMultiColumnForMultipleTickets() {
        let columns = KdsBoardLayout.distribute(
            (1...6).map {
                Fixtures.ticket("R-0\($0)", status: .ready, visibleAt: baseTime.addingTimeInterval(Double($0) * 10))
            },
            columnCount: 3
        )

        #expect(columns.count == 3)
        #expect(Fixtures.displayNumbers(columns[0]) == ["R-01", "R-04"])
        #expect(Fixtures.displayNumbers(columns[1]) == ["R-02", "R-05"])
        #expect(Fixtures.displayNumbers(columns[2]) == ["R-03", "R-06"])
    }
}
