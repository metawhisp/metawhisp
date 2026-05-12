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

    // MARK: - ITER-034.1 — sliding-window guards (regression 2026-05-11)

    /// REGRESSION 2026-05-11: user report «созвон закончился в 5 минут позже
    /// календарного окна» — caller used `meetingRecorder.audioLevel`
    /// (instantaneous), which dropped below threshold in normal 200-500ms
    /// pauses between sentences. Decision fired `.stopNow` mid-discussion.
    /// Fix: caller now passes `recentAudioActive` (true iff audio crossed
    /// the silence threshold within the last 30s — sliding window, NOT
    /// instantaneous). When true we must NOT `.stopNow` even if the current
    /// RMS sample is quiet.
    func test_recentAudioActive_blocksStopNow_evenIfCurrentRMSQuiet() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.001,               // current sample IS quiet
            notifyAttemptsSoFar: 0,
            recentAudioActive: true                // …but someone talked recently
        )
        // Must not be stopNow — meeting still in progress, just a pause.
        if case .stopNow = decision {
            XCTFail("stopped mid-pause despite recent audio activity: \(decision)")
        }
    }

    /// REGRESSION 2026-05-12: user got «RECORDING STOPPED · Meeting
    /// overrunning» card ~5 min into a recording (event was short OR
    /// recording started after event end). Recording was actually CONTINUING,
    /// not stopped — the card title was misleading. Fix: when BOTH signals
    /// say meeting is clearly ongoing (audio active AND meeting app visible),
    /// return `.silentExtend` instead of `.notifyAndExtend` — no card pushed.
    func test_bothPositiveSignals_silentExtendNotNotify() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0,
            recentAudioActive: true,
            meetingAppVisible: true
        )
        if case .silentExtend = decision {
            // OK
        } else {
            XCTFail("expected silentExtend when both signals active, got \(decision)")
        }
    }

    /// Only ONE positive signal (audio but no visible meeting app, or vice versa)
    /// → still notifyAndExtend (caller pushes a card so user knows).
    func test_onePositiveSignal_notifyAndExtend() {
        let auditDecision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0,
            recentAudioActive: true,
            meetingAppVisible: false
        )
        if case .notifyAndExtend = auditDecision { } else {
            XCTFail("audio-only signal should still notify, got \(auditDecision)")
        }

        let visibleDecision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            meetingAppVisible: true
        )
        if case .notifyAndExtend = visibleDecision { } else {
            XCTFail("app-visible-only signal should still notify, got \(visibleDecision)")
        }
    }

    /// Same regression — alternate channel: if a meeting app (Zoom / Meet /
    /// Teams / etc) is visible on screen in the recent capture window, the
    /// meeting is ongoing regardless of audio. Blocks stopNow.
    func test_meetingAppVisible_blocksStopNow() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            meetingAppVisible: true                // Zoom in foreground
        )
        if case .stopNow = decision {
            XCTFail("stopped while meeting app visible: \(decision)")
        }
    }

    /// Both new signals false + quiet RMS → still stops as before. Guards
    /// the backward-compat path so the new params don't break the existing
    /// "no one's around" auto-stop.
    func test_stopNow_stillFires_whenAllSignalsClear() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            meetingAppVisible: false
        )
        XCTAssertEqual(decision, .stopNow)
    }

    /// `hardStop` budget cap STILL wins over `recentAudioActive` — the whole
    /// point of `maxNotifyAttempts` is to bound the recording at ~15-30 min
    /// past calendar end (3 attempts × 5 min extension). Without this cap,
    /// a forgotten music session would record forever even when the
    /// "audio active" signal is real.
    func test_hardStop_wins_over_recentAudioActive() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(2000),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 3,
            recentAudioActive: true,
            meetingAppVisible: true
        )
        XCTAssertEqual(decision, .hardStop)
    }
}
