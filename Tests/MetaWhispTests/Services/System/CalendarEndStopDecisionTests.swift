import XCTest
@testable import MetaWhisp

/// Pure-function tests for `CalendarEndStopDecision.evaluate(...)`.
///
/// History (ITER-034, 2026-05-08): user report «созвон не выключается».
/// silence guard (3 min) is the only auto-stop signal currently, and any
/// continued audio (people lingering after the meeting, music, dictation
/// next to mic) resets it. The fix uses `EKEvent.endDate` as a deterministic
/// signal — at endDate + 60s grace, sample audio: if quiet, stop; if loud,
/// notify and extend; if user keeps ignoring, hard stop after N attempts.
final class CalendarEndStopDecisionTests: XCTestCase {

    // Reference time.
    private let now = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: - keepRunning while inside the event

    /// Event ends in the future — nothing to do yet.
    func test_keepRunning_beforeEnd() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now,
            eventEnd: now.addingTimeInterval(120),  // 2 min remaining
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0
        )
        XCTAssertEqual(decision, .keepRunning)
    }

    /// Right at endDate, before grace expires — still running.
    func test_keepRunning_atEnd_withinGrace() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(30),       // grace=60, only 30s past end
            eventEnd: now,
            audioRMSLastNSec: 0.0,
            notifyAttemptsSoFar: 0
        )
        XCTAssertEqual(decision, .keepRunning)
    }

    // MARK: - stopNow when grace passed and quiet

    /// Past endDate + grace, audio below threshold → stop.
    func test_stopNow_quietAfterGrace() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),       // 10s past grace
            eventEnd: now,
            audioRMSLastNSec: 0.001,               // below 0.005 threshold
            notifyAttemptsSoFar: 0
        )
        XCTAssertEqual(decision, .stopNow)
    }

    // MARK: - notifyAndExtend when audio still active

    /// Past grace but audio still active → notify + extend deadline.
    func test_notifyAndExtend_activeAudio() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0
        )
        guard case let .notifyAndExtend(newDeadline) = decision else {
            return XCTFail("expected notifyAndExtend, got \(decision)")
        }
        // Default extension is 5 minutes (300s) — new deadline = now + 300.
        XCTAssertEqual(newDeadline.timeIntervalSince(now.addingTimeInterval(70)),
                       300, accuracy: 1)
    }

    /// Second attempt — still active, still under max → extend again.
    func test_notifyAndExtend_secondAttempt() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(400),
            eventEnd: now,
            audioRMSLastNSec: 0.04,
            notifyAttemptsSoFar: 1
        )
        if case .notifyAndExtend = decision { } else {
            XCTFail("expected notifyAndExtend on attempt 2, got \(decision)")
        }
    }

    // MARK: - hardStop after maxNotifyAttempts

    /// 3 ignored notifications already → next evaluation hard-stops to
    /// prevent infinite recording.
    func test_hardStop_afterMaxNotifyAttempts() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(2000),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 3                 // already 3 attempts
        )
        XCTAssertEqual(decision, .hardStop)
    }

    // MARK: - quietRMSThreshold customization

    /// Threshold tuneable. With higher threshold, mid-level RMS counts as quiet.
    func test_quietThresholdCustomizable() {
        let decisionLowThreshold = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.01,
            notifyAttemptsSoFar: 0,
            quietRMSThreshold: 0.005
        )
        XCTAssertNotEqual(decisionLowThreshold, .stopNow)  // 0.01 > 0.005 → not quiet

        let decisionHighThreshold = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.01,
            notifyAttemptsSoFar: 0,
            quietRMSThreshold: 0.02                // 0.01 < 0.02 → quiet
        )
        XCTAssertEqual(decisionHighThreshold, .stopNow)
    }

    // MARK: - Edge: short grace when very close to endDate

    /// Caller can pass shorter grace (e.g. event ends in 30s, app starts late).
    /// Pure func just uses what it's given — the clamp logic lives in caller.
    func test_customGraceRespected() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(15),
            eventEnd: now,
            audioRMSLastNSec: 0.0,
            notifyAttemptsSoFar: 0,
            graceSeconds: 10                       // 10s grace; now is 15s past end
        )
        XCTAssertEqual(decision, .stopNow)
    }
}
