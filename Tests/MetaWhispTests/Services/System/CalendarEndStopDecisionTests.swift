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

    /// Past grace but audio still active (the 30 s window, the authoritative
    /// "someone is talking" signal) and no call seen → notify + extend deadline.
    func test_notifyAndExtend_activeAudio() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0,
            recentAudioActive: true
        )
        guard case let .notifyAndExtend(newDeadline) = decision else {
            return XCTFail("expected notifyAndExtend, got \(decision)")
        }
        // Default extension is 5 minutes (300s) — new deadline = now + 300.
        XCTAssertEqual(newDeadline.timeIntervalSince(now.addingTimeInterval(70)),
                       300, accuracy: 1)
    }

    /// Owner's log, 2026-10-20: «Calendar slot ended — still recording» at
    /// 11:16:00, 11:21:00 and 11:26:01, all timed out, none tapped. With audio
    /// on the recording continues whether or not the card is tapped, so the
    /// second card asks nothing the first did not. Ask once per recording.
    func test_secondOverrunWithAudioOn_cardDoesNotFire() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(400),
            eventEnd: now,
            audioRMSLastNSec: 0.04,
            notifyAttemptsSoFar: 1,
            recentAudioActive: true,
            overrunCardShown: true
        )
        guard case let .extendWithoutCard(newDeadline) = decision else {
            return XCTFail("the second overrun with audio on must extend without a card, got \(decision)")
        }
        XCTAssertEqual(newDeadline.timeIntervalSince(now.addingTimeInterval(400)), 300, accuracy: 1)
    }

    /// The pair to the test above: what ends the recording once the card has
    /// been shown. Audio going quiet still stops it — on the spot when the
    /// room and the screen are clear, and by the hard stop once the budget is
    /// spent, call or no call.
    func test_overrunCardShown_recordingStopFiresAnywayAfterAudioGoesQuiet() {
        let quietAfterTheCard = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(400),
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 1,
            recentAudioActive: false,
            overrunCardShown: true
        )
        XCTAssertEqual(quietAfterTheCard, .stopNow)

        let quietPastTheBudget = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(1000),
            eventEnd: now,
            audioRMSLastNSec: 0.006,
            notifyAttemptsSoFar: 3,
            recentAudioActive: false,
            lastCallSeenAt: now.addingTimeInterval(1000),
            overrunCardShown: true
        )
        XCTAssertEqual(quietPastTheBudget, .hardStop)
    }

    /// The window says nobody has talked for 30 s; only the instant sample
    /// is above the quiet line (room noise, 0.005-0.008). Not audio on, so
    /// nothing to ask — but not a stop either, and the round still counts
    /// toward the hard stop.
    func test_quietWindowWithALoudInstant_extendsWithoutCard() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.006,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false
        )
        guard case .extendWithoutCard = decision else {
            return XCTFail("expected extendWithoutCard, got \(decision)")
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
            lastCallSeenAt: now.addingTimeInterval(70)
        )
        if case .silentExtend = decision {
            // OK
        } else {
            XCTFail("expected silentExtend when both signals active, got \(decision)")
        }
    }

    /// Only ONE positive signal (audio but no call seen, or vice versa). Audio
    /// with no call on screen is the one real question — the meeting may be
    /// over while people still talk — so the first time, the caller pushes a
    /// card. A call on screen with the room quiet asks nothing (2026-10-20:
    /// the card is only for no call seen): the round extends without a card
    /// and still counts toward the hard stop.
    func test_onePositiveSignal_onlyAudioWithNoCallAsks() {
        let auditDecision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 0,
            recentAudioActive: true,
            lastCallSeenAt: nil
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
            lastCallSeenAt: now.addingTimeInterval(70)
        )
        if case .extendWithoutCard = visibleDecision { } else {
            XCTFail("a call seen with the room quiet extends without a card, got \(visibleDecision)")
        }
    }

    /// Same regression — alternate channel: if the call detector sees a call
    /// (Zoom / Meet / Teams / etc) in front at the check, the meeting is
    /// ongoing regardless of audio. Blocks stopNow.
    func test_callSeenAtTheCheck_blocksStopNow() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(70),
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            lastCallSeenAt: now.addingTimeInterval(70)   // Zoom in front right now
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
            lastCallSeenAt: nil
        )
        XCTAssertEqual(decision, .stopNow)
    }

    /// After the notify budget is exhausted, the decision splits on
    /// `recentAudioActive`:
    ///   - audio active → `silentExtend` (don't kill a still-going call;
    ///     user keeps getting cards every 5 min and can stop manually)
    ///   - audio quiet  → `hardStop` (anti-zombie safety valve)
    ///
    /// Originally `hardStop` ALWAYS won past the budget. That regressed
    /// real Google-Meet-in-Chrome calls: the meeting-app probe of the time
    /// missed browser-tab meetings, so a loud 46-min call got hard-stopped at
    /// notify #3 even though the user was still talking. The current
    /// contract preserves the anti-zombie cap (audio-quiet branch) while
    /// keeping live calls alive (audio-active branch).

    func test_silentExtend_whenBudgetExhaustedButAudioActive() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(2000),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 3,
            recentAudioActive: true,
            lastCallSeenAt: now.addingTimeInterval(2000)
        )
        if case .silentExtend = decision {
            // pass
        } else {
            XCTFail("Expected .silentExtend when audio active past budget, got \(decision)")
        }
    }

    func test_hardStop_whenBudgetExhaustedAndAudioQuiet() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(2000),
            eventEnd: now,
            audioRMSLastNSec: 0.05,
            notifyAttemptsSoFar: 3,
            recentAudioActive: false,
            lastCallSeenAt: now.addingTimeInterval(2000)
        )
        XCTAssertEqual(decision, .hardStop)
    }

    // MARK: - The call detector is the one source (2026-10-20)

    /// Owner's log, 2026-10-20: three «Calendar slot ended — still recording»
    /// cards at 17:51:00, 17:56:01 and 18:01:02 with `meetingApp=NO`, while the
    /// call detector held «Google Meet (app=Dia)» at each of those moments. The
    /// check read screen captures from the last 60 s — none had landed — and a
    /// browser list without Dia. It reads the detector's last sighting now; a
    /// call seen two minutes ago is a call still on.
    func test_aCallSeenTwoMinutesAgo_counts() {
        let check = now.addingTimeInterval(70)
        let talking = CalendarEndStopDecision.evaluate(
            now: check,
            eventEnd: now,
            audioRMSLastNSec: 0.14,
            notifyAttemptsSoFar: 0,
            recentAudioActive: true,
            lastCallSeenAt: check.addingTimeInterval(-120)
        )
        guard case .silentExtend = talking else {
            return XCTFail("a call seen 2 min ago with audio on is a live call, got \(talking)")
        }

        let pause = CalendarEndStopDecision.evaluate(
            now: check,
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            lastCallSeenAt: check.addingTimeInterval(-120)
        )
        XCTAssertNotEqual(pause, .stopNow, "a pause in a call seen 2 min ago must not stop it")
    }

    /// The pair to the test above: what ends the call's hold. Same log, 18:46:06 —
    /// the call had left the screen at 18:40:17 and the room was quiet. Once
    /// the call has been out of sight past the five-minute window, the quiet
    /// room stops the recording as before.
    func test_aCallSeenSixMinutesAgo_doesNotCount_stopFiresAnyway() {
        let check = now.addingTimeInterval(70)
        let decision = CalendarEndStopDecision.evaluate(
            now: check,
            eventEnd: now,
            audioRMSLastNSec: 0.001,
            notifyAttemptsSoFar: 0,
            recentAudioActive: false,
            lastCallSeenAt: check.addingTimeInterval(-360)
        )
        XCTAssertEqual(decision, .stopNow)
    }

    /// The wiring, read off the source like the app's other wiring tests: the
    /// end check is fed the detector's own sighting, and the second probe
    /// over stored captures stays gone.
    func test_theEndCheckIsFedTheCallDetector_notAProbeOverCaptures() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("let lastCallSeenAt = self.screenContext.lastCallSeenAt"))
        XCTAssertTrue(source.contains("lastCallSeenAt: lastCallSeenAt"), "the decision gets that sighting")
        XCTAssertFalse(source.contains("isMeetingAppVisibleInRecentScreenContext"), "the capture probe is gone")
    }

    /// "Once per recording" lives in the caller's flag: cleared where a new
    /// recording clears the round count, set where the card is pushed, and
    /// handed to the decision.
    func test_theOneCardFlagIsClearedPerRecordingSetByTheCardAndRead() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("calendarEndNotifyAttempts = 0\n        calendarEndOverrunCardShown = false"),
                      "a new recording may ask again")
        XCTAssertTrue(source.contains("self.calendarEndOverrunCardShown = true\n                MWNotificationStack.shared.push(card)"),
                      "the card marks itself shown")
        XCTAssertTrue(source.contains("overrunCardShown: self.calendarEndOverrunCardShown"), "the decision reads it")
    }

    /// With audio quiet and no call seen at all, the hard stop past the
    /// budget still happens — the detector's silence is not a reason to keep
    /// recording.
    func test_audioQuietAndNoCallSeen_hardStopStillHappens() {
        let decision = CalendarEndStopDecision.evaluate(
            now: now.addingTimeInterval(2000),
            eventEnd: now,
            audioRMSLastNSec: 0.006,
            notifyAttemptsSoFar: 3,
            recentAudioActive: false,
            lastCallSeenAt: nil
        )
        XCTAssertEqual(decision, .hardStop)
    }
}
