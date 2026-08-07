import XCTest
@testable import MetaWhisp

/// ITER-060 units fix — the silence guard compares RAW rms, not the
/// sqrt-boosted UI `audioLevel`. Before the fix the 0.025 threshold was
/// checked against the boosted value (raw equivalent 5.2e-5 — digital zero),
/// so the silence auto-stop and calendar-end quiet probe never fired and
/// recordings ran hours past the call.
final class MeetingRecorderSilenceTests: XCTestCase {

    func test_ambientNoiseFloorIsSilence() {
        // Kbd typing / fan hum / AirPods breathing: raw ~0.001-0.005.
        XCTAssertTrue(MeetingRecorder.isRawSilence(0.001))
        XCTAssertTrue(MeetingRecorder.isRawSilence(0.005))
    }

    func test_quietSpeechIsNotSilence() {
        // Quiet/distant speech raw ~0.015+ must reset the silence window —
        // otherwise the auto-stop would cut a real conversation.
        XCTAssertFalse(MeetingRecorder.isRawSilence(0.015))
        XCTAssertFalse(MeetingRecorder.isRawSilence(0.05))
    }

    func test_thresholdIsRawScale_notBoosted() {
        // Boosted values live in ~0.2-0.9 for audible audio; a threshold in
        // raw scale must sit far below the boosted range. Guards against a
        // regression back to comparing boosted levels.
        XCTAssertLessThan(MeetingRecorder.silenceRMSThreshold, 0.1)
        // …and the boosted rendering of the threshold is clearly audible-range,
        // which is why comparing boosted against it never fired.
        let boostedOfThreshold = sqrtf(min(MeetingRecorder.silenceRMSThreshold * 12, 1))
        XCTAssertGreaterThan(boostedOfThreshold, MeetingRecorder.silenceRMSThreshold)
    }
}
