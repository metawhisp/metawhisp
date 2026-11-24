import XCTest
@testable import MetaWhisp

/// ITER-083 I2 — one rule for "is this meeting over", asked by both the
/// silence stop and the calendar-end hard stop. Before, both ended recordings
/// on quiet alone: on 2026-11-04 the calendar-end check cut a call 76 min in,
/// 24 s after the call detector had seen it, and the same call was recorded
/// again 14 s later as a second meeting.
final class MeetingEndPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_330_400)
    private let threeMinutes: TimeInterval = 180

    func testAQuietCallStillOnScreenIsNotOver() {
        XCTAssertFalse(MeetingEndPolicy.quietEnds(quietFor: threeMinutes, quietNeeded: threeMinutes,
                                                  lastCallSeenAt: now.addingTimeInterval(-24), now: now))
    }

    /// The pair: the detector sees a window, not a connection — a tab left open
    /// after the call looks the same as a silent call. Fifteen minutes with
    /// nobody saying anything on either side ends it anyway.
    func testAQuietCallOnScreenEndsAnywayAfterFifteenMinutes() {
        XCTAssertFalse(MeetingEndPolicy.quietEnds(quietFor: 899, quietNeeded: threeMinutes,
                                                  lastCallSeenAt: now, now: now))
        XCTAssertTrue(MeetingEndPolicy.quietEnds(quietFor: 900, quietNeeded: threeMinutes,
                                                 lastCallSeenAt: now, now: now))
    }

    func testQuietWithNoCallSeenEndsAtTheUsualTime() {
        XCTAssertTrue(MeetingEndPolicy.quietEnds(quietFor: threeMinutes, quietNeeded: threeMinutes,
                                                 lastCallSeenAt: nil, now: now))
        XCTAssertTrue(MeetingEndPolicy.quietEnds(quietFor: threeMinutes, quietNeeded: threeMinutes,
                                                 lastCallSeenAt: now.addingTimeInterval(-301), now: now),
                      "a call last seen more than five minutes ago is not on")
        XCTAssertFalse(MeetingEndPolicy.quietEnds(quietFor: threeMinutes - 1, quietNeeded: threeMinutes,
                                                  lastCallSeenAt: nil, now: now), "not quiet long enough")
    }
}

/// ITER-083 I2 — what a stop was, from its reason. It decides what may start
/// next: a person's stop holds the call for good, the app's own end holds only
/// the window still in front.
final class StopOutcomeTests: XCTestCase {

    func testAPersonsStopIsARefusal() {
        for reason in ["user-toggle", "card-tap-stop", "dictation-end-card-tap", "calendar-end-overrun-card-tap:E@1"] {
            XCTAssertEqual(StopOutcome.of(stopReason: reason), .refusal, reason)
        }
    }

    func testTheNextEventsStartIsATransition() {
        XCTAssertEqual(StopOutcome.of(stopReason: "back-to-back-eventID:E@1"), .transition)
    }

    func testTheAppsOwnEndIsEnded() {
        for reason in ["calendar-end-grace:E@1", "calendar-end-hard-stop:E@1",
                       "recorder-auto-stop:silenceTimeout", "recorder-auto-stop:maxDurationReached"] {
            XCTAssertEqual(StopOutcome.of(stopReason: reason), .ended, reason)
        }
    }
}

/// ITER-083 I2 — the wiring, read off the source like the app's other wiring
/// tests: both stops ask the one rule.
final class MeetingEndPolicyWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../\(path)").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheSilenceStopAsksTheEndRule() throws {
        let app = try source("App/AppDelegate.swift")
        XCTAssertTrue(app.contains("meetingRecorder.endsOnQuiet = {"))
        XCTAssertTrue(app.contains("MeetingEndPolicy.quietEnds(quietFor: quietFor, quietNeeded: window,"))
        let recorder = try source("Services/Audio/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("if self.endsOnQuiet?(quiet, windowSeconds) ?? true {"),
                      "the silence guard fires only when the rule says the meeting is over")
    }

    func testTheCalendarEndCheckIsToldHowLongItHasBeenQuiet() throws {
        XCTAssertTrue(try source("App/AppDelegate.swift").contains("quietForSeconds: self.meetingRecorder.quietFor"))
    }

    func testTheStopActsOnItsOutcome() throws {
        let app = try source("App/AppDelegate.swift")
        XCTAssertTrue(app.contains("let outcome = StopOutcome.of(stopReason: reason)"))
        XCTAssertTrue(app.contains("if outcome == .ended { MeetingAutoStartGate.shared.endedByApp() }"))
        XCTAssertTrue(app.contains("if let eventID = recording?.occurrenceKey, capture.deliveredSamples > 16000 {\n            MeetingAutoStartGate.shared.recordingSaved(eventID: eventID)"))
        XCTAssertTrue(app.contains("MeetingAutoStartGate.shared.startCapturedNothing()"))
        XCTAssertTrue(app.contains("callApp: callName == nil ? nil : bundleID,"), "the gate is told which app the call is in")
    }
}

/// ITER-083 I2 (Codex review) — whether anything was captured is counted on
/// what the mic tap and the system stream delivered, not on the buffers'
/// lengths: a mic outage pads its timeline with silence.
final class CaptureDeliveredSamplesTests: XCTestCase {
    func testPaddedSilenceIsNotACapture() {
        let capture = MeetingRecorder.Capture(
            mic: [Float](repeating: 0, count: 48_000), system: [], tapSamples: 1_600,
            micChannelWasSilent: false, outages: 1, outageSeconds: 3, micDownAtStop: false,
            micUnavailable: nil, micZeroRunSeconds: 0, micAudioAtStop: false, generation: 1,
            systemDelivered: 0)
        XCTAssertEqual(capture.deliveredSamples, 1_600)
        XCTAssertLessThanOrEqual(capture.deliveredSamples, 16_000, "a tenth of a second was heard")
    }
}
