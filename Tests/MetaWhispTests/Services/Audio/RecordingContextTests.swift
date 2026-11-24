import XCTest
@testable import MetaWhisp

/// ITER-083 I1 — a recording knows what it is from the moment it starts, and
/// keeps that until it is saved. Before, the event lived in two AppDelegate
/// fields the next recording overwrote, and the save read them afterwards: a
/// call cut at the next event's start was saved under the next event's name.
final class RecordingContextTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_330_400)   // 2026-09-25 10:00 UTC

    private func occurrence(_ id: String = "series-1", at start: Date, title: String? = "Weekly sync",
                            attendees: [String] = []) -> CalendarOccurrence {
        CalendarOccurrence(eventID: id, title: title, start: start, end: start.addingTimeInterval(1800),
                           attendees: attendees)!
    }

    func testACalendarStartCarriesItsOccurrence() {
        let event = occurrence(at: start)
        let context = RecordingContext.calendar(event, startedAt: start)
        XCTAssertEqual(context.origin, .calendar)
        XCTAssertEqual(context.event, event)
        XCTAssertEqual(context.occurrenceKey, event.key)
        XCTAssertEqual(context.callName, "Weekly sync", "the name the gate gave the call")
        XCTAssertNil(context.stoppedAt)
    }

    /// Attribution only from what was observed: a call window or a hand on
    /// the record button says nothing about which meeting it is.
    func testFallbackAndManualStartsCarryNoEvent() {
        let fallback = RecordingContext.fallback(callName: "Google Meet", startedAt: start)
        XCTAssertEqual(fallback.origin, .fallback)
        XCTAssertNil(fallback.event)
        XCTAssertNil(fallback.occurrenceKey)
        XCTAssertEqual(fallback.callName, "Google Meet")

        let manual = RecordingContext.manual(startedAt: start)
        XCTAssertEqual(manual.origin, .manual)
        XCTAssertNil(manual.event)
        XCTAssertNil(manual.callName)
    }

    func testStoppingFreezesTheStopAndKeepsTheRest() {
        let started = RecordingContext.calendar(occurrence(at: start), startedAt: start)
        let stop = start.addingTimeInterval(2400)
        let stopped = started.stopped(at: stop)
        XCTAssertEqual(stopped.stoppedAt, stop)
        XCTAssertEqual(stopped.event, started.event)
        XCTAssertEqual(stopped.startedAt, start)
        XCTAssertEqual(stopped.stopped(at: stop.addingTimeInterval(60)).stoppedAt, stop,
                       "a second stop does not move the first")
    }

    /// Back-to-back: A is stopped at B's start and saved after B started.
    /// What A saves is A's own snapshot, whatever B does next.
    func testTheSnapshotOfAStoppedRecordingIsItsOwn() {
        let a = RecordingContext.calendar(occurrence("series-a", at: start, title: "Planning"), startedAt: start)
        let stopAt = start.addingTimeInterval(1800)
        let snapshotOfA = a.stopped(at: stopAt)
        let b = RecordingContext.calendar(occurrence("series-b", at: stopAt, title: "Review"), startedAt: stopAt)
        XCTAssertNotEqual(snapshotOfA, b)
        XCTAssertEqual(snapshotOfA.event?.rawTitle, "Planning")
        XCTAssertEqual(snapshotOfA.event?.eventID, "series-a")
    }
}
