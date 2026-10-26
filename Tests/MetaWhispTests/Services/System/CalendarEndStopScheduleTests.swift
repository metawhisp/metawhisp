import XCTest
@testable import MetaWhisp

/// ITER-075 step 1, US-1.3 — the calendar end check never fires in the first
/// 10 minutes of a recording, not even on its very first arm.
final class CalendarEndStopScheduleTests: XCTestCase {

    private let sessionStart = Date(timeIntervalSince1970: 1_790_330_400)   // 2026-09-25 10:00 UTC
    private let minute: TimeInterval = 60

    /// The series' first occurrence ended months ago: the first check comes
    /// 10 minutes into the recording, never one second in.
    func testAnEndLongPastWaitsTenMinutesIntoTheRecording() {
        let longPast = Date(timeIntervalSince1970: 1_764_930_600)   // 2025-12-05 10:30 UTC
        let fire = CalendarEndStopSchedule.fireAt(eventEnd: longPast, sessionStart: sessionStart,
                                                  now: sessionStart.addingTimeInterval(1))
        XCTAssertEqual(fire, sessionStart.addingTimeInterval(10 * minute))
    }

    /// A retry that starts in the last minutes of a running occurrence: its
    /// end is minutes away, and the check still waits for the floor.
    func testAnEndMinutesAwayStillWaitsForTheFloor() {
        let end = sessionStart.addingTimeInterval(3 * minute)
        let fire = CalendarEndStopSchedule.fireAt(eventEnd: end, sessionStart: sessionStart, now: sessionStart)
        XCTAssertEqual(fire, sessionStart.addingTimeInterval(10 * minute))
    }

    func testAFutureEndFiresAfterTheGrace() {
        let end = sessionStart.addingTimeInterval(30 * minute)
        let fire = CalendarEndStopSchedule.fireAt(eventEnd: end, sessionStart: sessionStart, now: sessionStart)
        XCTAssertEqual(fire, end.addingTimeInterval(CalendarEndStopDecisionRules.defaultGraceSeconds))
    }

    /// A re-check after an extension, 20 minutes in, fires at its new deadline.
    func testARecheckFiresAtItsNewDeadline() {
        let now = sessionStart.addingTimeInterval(20 * minute)
        let deadline = now.addingTimeInterval(5 * minute)
        let fire = CalendarEndStopSchedule.fireAt(
            eventEnd: deadline.addingTimeInterval(-CalendarEndStopDecisionRules.defaultGraceSeconds),
            sessionStart: sessionStart, now: now)
        XCTAssertEqual(fire, deadline)
    }

    func testTheCheckIsNeverInThePast() {
        let now = sessionStart.addingTimeInterval(60 * minute)
        let fire = CalendarEndStopSchedule.fireAt(eventEnd: sessionStart, sessionStart: sessionStart, now: now)
        XCTAssertEqual(fire, now.addingTimeInterval(1))
    }
}
