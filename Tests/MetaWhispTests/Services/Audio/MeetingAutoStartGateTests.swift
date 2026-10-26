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
                              calendarEventInProgress: nil, isRecording: false, practiceHoldsCapture: false)
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
                           calendarEventInProgress: nil, isRecording: false, practiceHoldsCapture: false)
        guard case .calendarReady(let name, let id) = d else {
            return XCTFail("calendar must fire at the boundary, got \(d)")
        }
        XCTAssertEqual(name, "Standup")
        XCTAssertEqual(id, "E1")
    }

    func testTheSameCalendarBoundaryDoesNotDoubleFire() {
        let g = gate()
        _ = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                       calendarEventInProgress: nil, isRecording: false, practiceHoldsCapture: false)
        let again = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                               calendarEventInProgress: nil, isRecording: false, practiceHoldsCapture: false)
        XCTAssertEqual(again, .idle, "one fire per boundary")
    }

    /// The 08:30 case: the first attempt captured nothing and the meeting is
    /// over, but the event itself is still running. It gets another chance.
    func testAnEventThatCapturedNothingGetsAnotherChance() {
        let g = gate()
        _ = g.evaluate(callName: nil, calendarEventNow: (id: "E1", title: "Standup"),
                       calendarEventInProgress: (id: "E1", title: "Standup"), isRecording: false, practiceHoldsCapture: false)
        var decision: MeetingAutoStartGate.Decision = .idle
        for _ in 0..<CalendarAutoStartRetry.cooldownTicks {
            decision = g.evaluate(callName: nil, calendarEventNow: nil,
                                  calendarEventInProgress: (id: "E1", title: "Standup"),
                                  isRecording: false, practiceHoldsCapture: false)
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
                       calendarEventInProgress: (id: "E1", title: "Standup"), isRecording: false, practiceHoldsCapture: false)
        for _ in 0..<(CalendarAutoStartRetry.cooldownTicks * 3) {
            let d = g.evaluate(callName: nil, calendarEventNow: nil,
                               calendarEventInProgress: (id: "E1", title: "Standup"),
                               isRecording: true, practiceHoldsCapture: false)
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
                              calendarEventInProgress: event, isRecording: isRecording, practiceHoldsCapture: false)
        }
        return last
    }

    /// The owner's report, 2026-09-22: stopped at 18:31:02, started itself again
    /// at 18:31:57, stopped at 18:32:23, started again at 18:33:10 — while they
    /// were not on a call.
    func testAnEventStoppedByHandNeverStartsItselfAgain() {
        let g = MeetingAutoStartGate()
        let ev = (id: "E1", title: "Weekly Sync")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false, practiceHoldsCapture: false)
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
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false, practiceHoldsCapture: false)
        // A long meeting runs…
        _ = runOut(g, event: ev, ticks: CalendarAutoStartRetry.cooldownTicks * 10, isRecording: true)
        // …and the first tick after it stops must not already be a retry.
        let justAfterStop = g.evaluate(callName: nil, calendarEventNow: nil,
                                       calendarEventInProgress: ev, isRecording: false, practiceHoldsCapture: false)
        XCTAssertEqual(justAfterStop, .idle, "a stop must not be followed instantly by a restart")
    }

    /// And the case the retry exists for still works: nothing recorded, nobody
    /// refused, the event is still running.
    func testAnEventNobodyRefusedIsStillRetried() {
        let g = MeetingAutoStartGate()
        let ev = (id: "E3", title: "Daily")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false, practiceHoldsCapture: false)
        guard case .calendarReady = runOut(g, event: ev, ticks: CalendarAutoStartRetry.cooldownTicks) else {
            return XCTFail("a still-running event nobody stopped must be retried")
        }
    }
}

/// A recording the person stopped by hand stays stopped until the call is over.
///
/// The owner's log, 2026-10-20: a Google Meet recording stopped by hand at
/// 19:22:52, 19:30:40 and 19:32:43 started itself again at 19:25:40, 19:31:06
/// and 19:32:56. Each time the window in front was the same call, held for ten
/// seconds: `.fallbackReady` knew nothing of the stop. The stop was kept only
/// for calendar events and on the call card's session, which the 60 s
/// session-end grace had already cleared.
@MainActor
final class GateHoldsACallStoppedByHandTests: XCTestCase {

    /// The gate's own clock: one evaluate is one second, as in the app's loop.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func gate(_ clock: Clock) -> MeetingAutoStartGate {
        MeetingAutoStartGate(now: { clock.now })
    }

    @discardableResult
    private func tick(_ g: MeetingAutoStartGate, _ clock: Clock, call: String?, seconds: Int,
                      recording: Bool = false,
                      inProgress: (id: String, title: String)? = nil) -> [MeetingAutoStartGate.Decision] {
        (0..<seconds).map { _ in
            clock.now += 1
            return g.evaluate(callName: call, calendarEventNow: nil,
                              calendarEventInProgress: inProgress, isRecording: recording, practiceHoldsCapture: false)
        }
    }

    private func fired(_ decisions: [MeetingAutoStartGate.Decision]) -> Bool {
        decisions.contains { if case .fallbackReady = $0 { return true } else { return false } }
    }

    /// The call fired, recorded for a while, and the person stopped it.
    private func stoppedMeet() -> (MeetingAutoStartGate, Clock) {
        let clock = Clock()
        let g = gate(clock)
        XCTAssertTrue(fired(tick(g, clock, call: "Google Meet", seconds: 10)), "the call starts itself once")
        tick(g, clock, call: "Google Meet", seconds: 600, recording: true)
        g.stoppedByHand()
        return (g, clock)
    }

    /// 19:30:40 → 19:31:06 and 19:32:43 → 19:32:56: the call never left the front.
    func testACallStoppedByHandDoesNotStartItselfWhileItStaysInFront() {
        let (g, clock) = stoppedMeet()
        XCTAssertFalse(fired(tick(g, clock, call: "Google Meet", seconds: 20 * 60)),
                       "the person stopped this call")
        XCTAssertTrue(g.isHeld("Google Meet"))
    }

    /// 19:22:52 → 19:25:40: away from the call for two and a half minutes, then back.
    func testACallStoppedByHandDoesNotStartItselfWhenThePersonComesBackToIt() {
        let (g, clock) = stoppedMeet()
        tick(g, clock, call: nil, seconds: 160)
        XCTAssertFalse(fired(tick(g, clock, call: "Google Meet", seconds: 60)),
                       "coming back to the same call is not a new call")
    }

    /// The hold's release: half an hour with the call out of front, and the
    /// call is over — the next one in that app starts itself again.
    func testACallStoppedByHandFiresAnywayOnceItHasBeenOutOfFrontForHalfAnHour() {
        let (g, clock) = stoppedMeet()
        tick(g, clock, call: nil, seconds: Int(MeetingAutoStartGate.heldCallRelease))
        XCTAssertFalse(g.isHeld("Google Meet"))
        XCTAssertTrue(fired(tick(g, clock, call: "Google Meet", seconds: 10)),
                      "a call after the release is a new call")
    }

    /// Each sighting starts the half hour again: a long call keeps its hold.
    func testEverySightingOfTheCallStartsTheHalfHourAgain() {
        let (g, clock) = stoppedMeet()
        for _ in 0..<4 {
            tick(g, clock, call: nil, seconds: Int(MeetingAutoStartGate.heldCallRelease) - 60)
            tick(g, clock, call: "Google Meet", seconds: 5)
        }
        XCTAssertTrue(g.isHeld("Google Meet"), "the call was in front again every 29 minutes")
        XCTAssertFalse(fired(tick(g, clock, call: "Google Meet", seconds: 30)))
    }

    /// A meeting run beside the notes: the call was out of front for most of
    /// the recording, and is still the call the person stopped.
    func testACallOutOfFrontForMostOfTheRecordingIsHeldToo() {
        let clock = Clock()
        let g = gate(clock)
        XCTAssertTrue(fired(tick(g, clock, call: "Zoom", seconds: 10)))
        tick(g, clock, call: "Zoom", seconds: 30, recording: true)
        tick(g, clock, call: nil, seconds: 45 * 60, recording: true)
        g.stoppedByHand()
        XCTAssertFalse(fired(tick(g, clock, call: "Zoom", seconds: 60)),
                       "the recording was this call's")
    }

    /// A countdown dismissed with nothing recording holds the call in front —
    /// not the calls of a recording that ended long ago.
    func testADismissedCountdownDoesNotHoldTheCallsOfAnOldRecording() {
        let clock = Clock()
        let g = gate(clock)
        XCTAssertTrue(fired(tick(g, clock, call: "Zoom", seconds: 10)))
        tick(g, clock, call: "Zoom", seconds: 60, recording: true)
        tick(g, clock, call: nil, seconds: Int(MeetingAutoStartGate.heldCallRelease) + 60)
        XCTAssertTrue(fired(tick(g, clock, call: "Google Meet", seconds: 10)))
        g.stoppedByHand()
        XCTAssertTrue(g.isHeld("Google Meet"), "the countdown the person dismissed")
        XCTAssertFalse(g.isHeld("Zoom"), "that recording ended half an hour ago")
        XCTAssertFalse(fired(tick(g, clock, call: "Google Meet", seconds: 60)))
    }

    /// Another call is not the one the person stopped.
    func testAnotherCallStillStartsItselfAfterAStop() {
        let (g, clock) = stoppedMeet()
        XCTAssertTrue(fired(tick(g, clock, call: "Zoom", seconds: 10)),
                      "a different call app is a different call")
    }

    /// A call last in front long before the stop is not held by it.
    func testAStopHoldsNoCallThatWasNotInFrontLately() {
        let clock = Clock()
        let g = gate(clock)
        tick(g, clock, call: "Google Meet", seconds: 5)
        tick(g, clock, call: nil, seconds: Int(MeetingAutoStartGate.heldCallRelease) + 60)
        tick(g, clock, call: nil, seconds: 600, recording: true)
        g.stoppedByHand()
        XCTAssertFalse(g.isHeld("Google Meet"))
        XCTAssertTrue(fired(tick(g, clock, call: "Google Meet", seconds: 10)))
    }

    /// The event running at the stop is not retried either — even when the
    /// recording started from the window, not for the event.
    func testAStopByHandRefusesTheRetryOfTheEventRunningNow() {
        let clock = Clock()
        let g = gate(clock)
        let ev = (id: "E1", title: "Weekly Sync")
        _ = g.evaluate(callName: nil, calendarEventNow: ev, calendarEventInProgress: ev, isRecording: false, practiceHoldsCapture: false)
        tick(g, clock, call: "Google Meet", seconds: 600, recording: true, inProgress: ev)
        g.stoppedByHand()
        let after = tick(g, clock, call: nil, seconds: CalendarAutoStartRetry.cooldownTicks * 5, inProgress: ev)
        XCTAssertFalse(after.contains { if case .calendarReady = $0 { return true } else { return false } },
                       "the person stopped the meeting this event is")
    }

    /// The next event's start is a new meeting, held call or not.
    func testTheNextEventStillStartsAfterAStop() {
        let (g, clock) = stoppedMeet()
        clock.now += 1
        let d = g.evaluate(callName: "Google Meet", calendarEventNow: (id: "E2", title: "Retro"),
                           calendarEventInProgress: (id: "E2", title: "Retro"), isRecording: false, practiceHoldsCapture: false)
        guard case .calendarReady(_, let id) = d else {
            return XCTFail("a new event must start, got \(d)")
        }
        XCTAssertEqual(id, "E2")
    }
}

/// The app tells the gate of every stop by hand, and the call card asks the
/// gate before announcing a call that would not start.
final class ManualStopReachesTheGateTests: XCTestCase {

    private func appDelegate() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/AppDelegate.swift").standardized, encoding: .utf8)
    }

    private func body(of marker: String, in source: String, length: Int) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: marker), "\(marker) is gone").lowerBound
        return source[start...].prefix(length)
    }

    func testAStopByHandHoldsTheCall() throws {
        let stop = try body(of: "private func stopMeetingRecording(reason: String)", in: appDelegate(), length: 1800)
        XCTAssertTrue(stop.contains("if CalendarAutoStartRetry.isRefusal(stopReason: reason) {\n            MeetingAutoStartGate.shared.stoppedByHand()"),
                      "only a stop by hand holds the call, and every one does")
    }

    func testADismissedCountdownHoldsTheCall() throws {
        let cancelled = try body(of: "countdown cancelled by user", in: appDelegate(), length: 500)
        XCTAssertTrue(cancelled.contains("MeetingAutoStartGate.shared.stoppedByHand()"))
    }

    func testTheCallCardIsNotShownForAHeldCall() throws {
        let detect = try body(of: "private func handleCallContext(_ callName: String?)", in: appDelegate(), length: 2400)
        XCTAssertTrue(detect.contains("MeetingAutoStartGate.shared.isHeld(callName)"))
    }
}

/// Step-1 review #6 — the onboarding practice holds the microphone, so every
/// meeting start is refused. Those refusals used to spend an event's three
/// attempts, and the event never started after the practice. Now nothing is
/// proposed while the practice holds it, a refusal that still happens (the
/// practice took the microphone during a countdown) is given back, and the
/// same running event starts once the practice ends.
@MainActor
final class GateWaitsForThePracticeTests: XCTestCase {
    private let event = (id: "E1", title: "Standup")

    private func tick(_ g: MeetingAutoStartGate, now: (id: String, title: String)? = nil,
                      held: Bool) -> MeetingAutoStartGate.Decision {
        g.evaluate(callName: nil, calendarEventNow: now, calendarEventInProgress: event,
                   isRecording: false, practiceHoldsCapture: held)
    }

    /// Ticks until the gate proposes the event; nil when it never does.
    private func ticksUntilProposed(_ g: MeetingAutoStartGate, within limit: Int) -> Int? {
        for n in 1...limit {
            if case .calendarReady(_, let id) = tick(g, held: false), id == event.id { return n }
        }
        return nil
    }

    func testAnEventThatStartsDuringThePracticeStartsOnceItEnds() {
        let g = MeetingAutoStartGate()
        // The event begins while the practice holds the microphone and keeps
        // running past all three attempts' worth of ticks.
        for n in 0..<(CalendarAutoStartRetry.maxAttempts * CalendarAutoStartRetry.cooldownTicks + 5) {
            XCTAssertEqual(tick(g, now: n < 65 ? event : nil, held: true), .idle, "tick \(n): nothing is proposed")
        }
        // The practice ends: the same running event is proposed at once.
        XCTAssertEqual(ticksUntilProposed(g, within: 1), 1)
    }

    /// Codex's case: the third attempt is refused because the practice took
    /// the microphone during its countdown; the practice ends; the same
    /// ongoing event starts.
    func testAThirdAttemptRefusedByThePracticeIsGivenBack() {
        let g = MeetingAutoStartGate()
        guard case .calendarReady = tick(g, now: event, held: false) else { return XCTFail("attempt 1, the boundary") }
        // Attempts 1 and 2 ran and recorded nothing: they count.
        XCTAssertEqual(ticksUntilProposed(g, within: CalendarAutoStartRetry.cooldownTicks), CalendarAutoStartRetry.cooldownTicks,
                       "attempt 2")
        XCTAssertEqual(ticksUntilProposed(g, within: CalendarAutoStartRetry.cooldownTicks), CalendarAutoStartRetry.cooldownTicks,
                       "attempt 3")
        g.refund(eventID: event.id)          // its countdown ended refused: the practice had the microphone
        for n in 0..<(3 * CalendarAutoStartRetry.cooldownTicks) {
            XCTAssertEqual(tick(g, held: true), .idle, "tick \(n): the practice still has the microphone")
        }
        XCTAssertEqual(ticksUntilProposed(g, within: 1), 1, "the practice ended: the same event starts")
    }

    /// The ceiling still holds for attempts that ran: a refund gives back
    /// only the refused one.
    func testAttemptsThatRanStillReachTheCeiling() {
        let g = MeetingAutoStartGate()
        _ = tick(g, now: event, held: false)
        _ = ticksUntilProposed(g, within: CalendarAutoStartRetry.cooldownTicks)
        _ = ticksUntilProposed(g, within: CalendarAutoStartRetry.cooldownTicks)
        XCTAssertNil(ticksUntilProposed(g, within: 5 * CalendarAutoStartRetry.cooldownTicks), "three attempts ran")
        g.refund(eventID: "an event never proposed")
        XCTAssertNil(ticksUntilProposed(g, within: 2 * CalendarAutoStartRetry.cooldownTicks))
    }
}
