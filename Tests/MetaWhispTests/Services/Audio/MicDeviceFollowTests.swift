import XCTest
@testable import MetaWhisp

/// Plugging in a microphone must switch the recording to it. That is the
/// feature, not a recovery.
///
/// On macOS a device change mid-recording is ordinary: a headset switches to
/// its hands-free profile the moment capture starts, a monitor with a
/// microphone is connected, AirPods arrive. The recorder used to treat every
/// one of those as a fatal interruption — destroy the engine, drop the
/// recording, write a line. The owner spoke for eight seconds into nothing
/// (2026-09-08 19:23) and the app said "0 samples".
///
/// So: a live recording FOLLOWS the current input device. The rules below are
/// what "follows" means when the device keeps moving.
final class MicDeviceFollowTests: XCTestCase {

    func testALiveRecordingFollowsTheNewDevice() {
        XCTAssertTrue(MicDeviceFollow.shouldFollow(wasRecording: true, attempts: 0))
    }

    /// Nothing is being recorded — following would be a microphone that turns
    /// itself on because a monitor was plugged in.
    func testAnIdleRecorderDoesNotFollow() {
        XCTAssertFalse(MicDeviceFollow.shouldFollow(wasRecording: false, attempts: 0))
    }

    /// Rebinding can itself provoke the next configuration change. The follow
    /// is bounded so a device that keeps flapping cannot spin the engine — but
    /// the bound is generous, because giving up is the failure mode the owner
    /// is complaining about.
    func testFollowingIsBoundedButGenerous() {
        XCTAssertTrue(MicDeviceFollow.shouldFollow(wasRecording: true, attempts: MicDeviceFollow.maxAttempts - 1))
        XCTAssertFalse(MicDeviceFollow.shouldFollow(wasRecording: true, attempts: MicDeviceFollow.maxAttempts))
        XCTAssertGreaterThanOrEqual(MicDeviceFollow.maxAttempts, 5,
                                    "a headset that switches profile twice must not exhaust the budget")
    }

    /// The device needs a moment to finish appearing; binding into the middle
    /// of that is what starts a flap.
    func testTheFollowWaitsForTheDeviceToSettle() {
        XCTAssertGreaterThanOrEqual(MicDeviceFollow.settleDelaySeconds, 0.15)
        XCTAssertLessThanOrEqual(MicDeviceFollow.settleDelaySeconds, 1.0,
                                 "a dictation is seconds long — a slow follow is the same as none")
    }

    // MARK: - The system default changes

    /// A recording on the system default goes where the default goes (AirPods arriving mid-dictation); a recording
    /// on the user's pick stays on it, and a "change" to the device already bound is none.
    func testOnlyARecordingOnTheDefaultFollowsTheDefault() {
        XCTAssertTrue(MicDeviceFollow.followsDefaultChange(boundToDefault: true, bound: 41, newDefault: 42))
        XCTAssertFalse(MicDeviceFollow.followsDefaultChange(boundToDefault: false, bound: 41, newDefault: 42))
        XCTAssertFalse(MicDeviceFollow.followsDefaultChange(boundToDefault: true, bound: 41, newDefault: 41))
        XCTAssertFalse(MicDeviceFollow.followsDefaultChange(boundToDefault: true, bound: 41, newDefault: 0),
                       "no input at all is not a device to follow")
    }

    // MARK: - One owner at a time

    /// The meeting's recovery tick and the service's own follow must not both
    /// rebind the same engine. While a follow is in flight the tick stands
    /// down — and its release is the follow finishing, not a timer.
    func testTheMeetingTickStandsDownWhileTheServiceIsFollowing() {
        let followingNow = MicTickInput(hasPermission: true, state: .down, producedSinceLastTick: 0,
                                        healthyTicks: 0, lowRateTicks: 0, secondsSinceLastTick: 1,
                                        followInFlight: true,
                                        elapsed: 30, outageOpen: true, attemptDue: true)
        XCTAssertFalse(MicRecoveryPolicy.decide(followingNow, sampleRate: 16_000).attempt,
                       "the service is already bringing the microphone back")
    }

    func testTheTickActsAgainOnceTheFollowIsOver() {
        let followDone = MicTickInput(hasPermission: true, state: .down, producedSinceLastTick: 0,
                                      healthyTicks: 0, lowRateTicks: 0, secondsSinceLastTick: 1,
                                      followInFlight: false,
                                      elapsed: 30, outageOpen: true, attemptDue: true)
        XCTAssertTrue(MicRecoveryPolicy.decide(followDone, sampleRate: 16_000).attempt,
                      "the follow did not fix it — the recorder's own recovery takes over")
    }

    // MARK: - A follow belongs to its recording

    /// The user stopping while a follow waits for the device to settle leaves the microphone off (independent
    /// review, 2026-10-13: the delayed follow checked only "not recording now", which stop makes true, and bound the
    /// microphone again after the user had stopped).
    @MainActor
    func testAFollowPendingAtStopLeavesTheMicrophoneOff() async {
        let recorder = AudioRecordingService()
        var binds = 0
        recorder.followDelay = { _ in await Task.yield() }
        recorder.followResume = { _ in binds += 1 }
        recorder.follow(afterChangeWhileRecording: true)
        XCTAssertTrue(recorder.followInFlight)
        _ = recorder.stop()
        await settled(recorder)
        XCTAssertEqual(binds, 0, "no bind after the user stopped")
    }

    /// The same follow, its recording going on, binds the microphone again — the follow still does its job.
    @MainActor
    func testAFollowWhoseRecordingGoesOnBindsAgain() async {
        let recorder = AudioRecordingService()
        var binds = 0
        recorder.followDelay = { _ in await Task.yield() }
        recorder.followResume = { _ in binds += 1 }
        recorder.follow(afterChangeWhileRecording: true)
        await settled(recorder)
        XCTAssertEqual(binds, 1)
    }

    /// The follow's task has run: `stop()` releases the flag at once, so the flag alone does not say so.
    @MainActor
    private func settled(_ recorder: AudioRecordingService) async {
        for _ in 0..<1_000 where recorder.followInFlight { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(recorder.followInFlight, "the follow ended")
    }
}
