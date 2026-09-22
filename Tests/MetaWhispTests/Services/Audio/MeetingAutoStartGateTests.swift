import XCTest
@testable import MetaWhisp

/// When a call should start recording itself.
///
/// The gate had no tests at all, and three rules had drifted apart from the
/// behaviour anyone would expect:
///
/// 1. A call in a BROWSER had to be fullscreen. A meeting in an ordinary
///    window — the way most people run one while taking notes beside it —
///    never crossed the threshold, so recording only ever started from a
///    calendar event.
/// 2. `audioActive` was still in the signature although the caller hardcoded
///    `false` and the decision had stopped reading it (2026-05-15).
/// 3. A calendar event fired exactly once, ever. On 2026-09-17 08:30 an event
///    fired into a closed lid — ScreenCaptureKit reported no displays, the mic
///    produced nothing, and the meeting auto-stopped on silence at 08:33. When
///    the owner actually joined, nothing re-armed: the event had spent its one
///    trigger.
@MainActor
final class MeetingAutoStartGateTests: XCTestCase {

    private func gate() -> MeetingAutoStartGate { MeetingAutoStartGate() }

    private func tick(_ g: MeetingAutoStartGate, call: String?, times: Int) -> MeetingAutoStartGate.Decision {
        var last: MeetingAutoStartGate.Decision = .idle
        for _ in 0..<times {
            last = g.evaluate(callName: call, calendarEventNow: nil,
                              calendarEventInProgress: nil, isRecording: false)
        }
        return last
    }

    // MARK: - A call in a window is still a call

    func testABrowserCallInAnOrdinaryWindowFiresAfterTenSeconds() {
        let g = gate()
        let d = tick(g, call: "Google Meet", times: 10)
        guard case .fallbackReady(let name) = d else {
            return XCTFail("a windowed call must fire, got \(d)")
        }
        XCTAssertEqual(name, "Google Meet")
    }

    func testTheStreakIsNotThereYetBeforeTenSeconds() {
        let g = gate()
        guard case .tracking(_, let left) = tick(g, call: "Google Meet", times: 9) else {
            return XCTFail("should still be tracking")
        }
        XCTAssertEqual(left, 1)
    }

    /// The native-app path keeps working — Zoom's small floating window was
    /// the 2026-05-15 report and must not regress.
    func testANativeCallAppStillFires() {
        let g = gate()
        guard case .fallbackReady = tick(g, call: "Zoom", times: 10) else {
            return XCTFail("a native call app must fire")
        }
    }

    /// Looking away resets the streak: a call window that is not in front is
    /// not evidence of anything.
    func testTheStreakResetsWhenTheCallWindowGoesAway() {
        let g = gate()
        _ = tick(g, call: "Google Meet", times: 9)
        _ = tick(g, call: nil, times: 1)
        guard case .tracking(_, let left) = tick(g, call: "Google Meet", times: 1) else {
            return XCTFail("should be tracking from the start again")
        }
        XCTAssertEqual(left, 9, "the streak starts over")
    }

    func testNoCallWindowIsIdle() {
        let g = gate()
        XCTAssertEqual(tick(g, call: nil, times: 3), .idle)
    }

    // MARK: - Calendar

    func testACalendarEventFiresImmediately() {
        let g = gate()
        let d = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                           calendarEventInProgress: nil, isRecording: false)
        guard case .calendarReady(let name, let id) = d else {
            return XCTFail("calendar must fire at the boundary, got \(d)")
        }
        XCTAssertEqual(name, "Standup")
        XCTAssertEqual(id, "E1")
    }

    func testTheSameCalendarBoundaryDoesNotDoubleFire() {
        let g = gate()
        _ = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                       calendarEventInProgress: nil, isRecording: false)
        let again = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                               calendarEventInProgress: nil, isRecording: false)
        XCTAssertEqual(again, .idle, "one fire per boundary")
    }

    /// The 08:30 case: the first attempt captured nothing and the meeting is
    /// over, but the event itself is still running. It gets another chance.
    func testAnEventThatCapturedNothingGetsAnotherChance() {
        let g = gate()
        _ = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                       calendarEventInProgress: (id: "E1", title: "Standup"), isRecording: false)
        var decision: MeetingAutoStartGate.Decision = .idle
        for _ in 0..<CalendarAutoStartRetry.cooldownTicks {
            decision = g.evaluate(callName: nil, calendarEventNow: nil,
                                  calendarEventInProgress: (id: "E1", title: "Standup"),
                                  isRecording: false)
        }
        guard case .calendarReady(_, let id) = decision else {
            return XCTFail("a still-running event must be retried, got \(decision)")
        }
        XCTAssertEqual(id, "E1")
    }

    /// …but never while something is already recording.
    func testAnEventIsNotRetriedWhileRecording() {
        let g = gate()
        _ = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                       calendarEventInProgress: (id: "E1", title: "Standup"), isRecording: false)
        for _ in 0..<(CalendarAutoStartRetry.cooldownTicks * 3) {
            let d = g.evaluate(callName: nil, calendarEventNow: nil,
                               calendarEventInProgress: (id: "E1", title: "Standup"),
                               isRecording: true)
            XCTAssertEqual(d, .idle, "a running meeting must not be started again")
        }
    }
}

/// What the gate does after the person says no.
@MainActor
final class GateRespectsAManualStopTests: XCTestCase {

    private func runOut(_ g: MeetingAutoStartGate, event: (id: String, title: String),
                        ticks: Int, isRecording: Bool = false) -> MeetingAutoStartGate.Decision {
        var last: MeetingAutoStartGate.Decision = .idle
        for _ in 0..<ticks {
            last = g.evaluate(callName: nil, calendarEventNow: nil,
                              calendarEventInProgress: event, isRecording: isRecording)
        }
        return last
    }

    /// The owner's report, 2026-09-22: stopped at 18:31:02, started itself again
    /// at 18:31:57, stopped at 18:32:23, started again at 18:33:10 — while they
    /// were not on a call.
    func testAnEventStoppedByHandNeverStartsItselfAgain() {
        let g = MeetingAutoStartGate()
        let ev = (id: "E1", title: "Atomic Wallet")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false)
        g.decline(eventID: ev.id)
        for _ in 0..<5 {
            XCTAssertEqual(runOut(g, event: ev, ticks: CalendarAutoStartRetry.cooldownTicks * 2), .idle,
                           "the person already said no")
        }
    }

    /// The cooldown is time spent NOT recording: counting through the meeting
    /// let a retry fire 98 ms after a stop (owner's log, 16:17:30).
    func testTheCooldownDoesNotRunWhileAMeetingIsRecording() {
        let g = MeetingAutoStartGate()
        let ev = (id: "E2", title: "Standup")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false)
        // A long meeting runs…
        _ = runOut(g, event: ev, ticks: CalendarAutoStartRetry.cooldownTicks * 10, isRecording: true)
        // …and the first tick after it stops must not already be a retry.
        let justAfterStop = g.evaluate(callName: nil, calendarEventNow: nil,
                                       calendarEventInProgress: ev, isRecording: false)
        XCTAssertEqual(justAfterStop, .idle, "a stop must not be followed instantly by a restart")
    }

    /// And the case the retry exists for still works: nothing recorded, nobody
    /// refused, the event is still running.
    func testAnEventNobodyRefusedIsStillRetried() {
        let g = MeetingAutoStartGate()
        let ev = (id: "E3", title: "Daily")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false)
        guard case .calendarReady = runOut(g, event: ev, ticks: CalendarAutoStartRetry.cooldownTicks) else {
            return XCTFail("a still-running event nobody stopped must be retried")
        }
    }
}
