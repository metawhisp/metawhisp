import Foundation
import XCTest
@testable import MetaWhisp

@MainActor
final class UtteranceTrackerFreshnessTests: XCTestCase {
    func testSpeechExpiresByClockWhenTheChannelStopsDeliveringFrames() async {
        let (tracker, clock, _) = makeTracker()
        let initiallySpeaking = await tracker.recentSpeech(excluding: [])
        XCTAssertFalse(initiallySpeaking)

        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        let fresh = await tracker.recentSpeech(excluding: [])
        XCTAssertTrue(fresh)
        clock.advance(by: .milliseconds(600))
        let atBoundary = await tracker.recentSpeech(excluding: [])
        XCTAssertTrue(atBoundary)
        clock.advance(by: .milliseconds(1))
        let expired = await tracker.recentSpeech(excluding: [])
        XCTAssertFalse(expired)
    }

    func testQuietFramesDoNotRefreshTheLastSpeechTime() async {
        let (tracker, clock, _) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        clock.advance(by: .milliseconds(500))
        await tracker.append(LiveCallFixture.audio([.silence(0.1)]))
        clock.advance(by: .milliseconds(101))

        let speaking = await tracker.recentSpeech(excluding: [])
        XCTAssertFalse(speaking)
    }

    func testDictationPauseExcludesItsSpeechFrames() async {
        let (tracker, _, _) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))

        let speaking = await tracker.recentSpeech(excluding: [LiveSampleRange(from: 16_000, to: 17_600)])
        XCTAssertFalse(speaking)
    }

    func testAnExcludedNewestFrameFallsBackToEarlierFreshSpeech() async {
        let (tracker, clock, _) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        clock.advance(by: .milliseconds(400))
        await tracker.append(LiveCallFixture.audio([.speech(0.1)]))
        let pause = LiveSampleRange(from: 17_600, to: 19_200)

        let earlierIsFresh = await tracker.recentSpeech(excluding: [pause])
        XCTAssertTrue(earlierIsFresh)
        clock.advance(by: .milliseconds(201))
        let earlierHasExpired = await tracker.recentSpeech(excluding: [pause])
        XCTAssertFalse(earlierHasExpired)
        let newestIsFresh = await tracker.recentSpeech(excluding: [])
        XCTAssertTrue(newestIsFresh)
    }

    func testCaptureReplacementClearsFreshnessAndCanAcceptNewSpeech() async {
        let (tracker, _, _) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        await tracker.reset()
        let afterReset = await tracker.recentSpeech(excluding: [])
        XCTAssertFalse(afterReset)

        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        let newSpeech = await tracker.recentSpeech(excluding: [])
        XCTAssertTrue(newSpeech)
    }

    func testStoppingClearsFreshnessAndRejectsLaterSamples() async {
        let (tracker, _, token) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        let beforeStop = await tracker.speechSeconds(after: 0, excluding: [])
        await tracker.stop()
        await tracker.append(LiveCallFixture.audio([.speech(0.1)]))

        let speaking = await tracker.recentSpeech(excluding: [])
        let afterStop = await tracker.speechSeconds(after: 0, excluding: [])
        XCTAssertFalse(speaking)
        XCTAssertEqual(afterStop, beforeStop)
        XCTAssertFalse(token.isCancelled)
    }

    func testSessionCancellationRejectsSamplesBeforeTheTrackerStopArrives() async {
        let (tracker, _, token) = makeTracker()
        await tracker.append(LiveCallFixture.audio([.silence(1), .speech(0.1)]))
        let beforeCancellation = await tracker.speechSeconds(after: 0, excluding: [])
        token.stop()
        await tracker.append(LiveCallFixture.audio([.speech(0.1)]))

        let speaking = await tracker.recentSpeech(excluding: [])
        let afterCancellation = await tracker.speechSeconds(after: 0, excluding: [])
        XCTAssertFalse(speaking)
        XCTAssertEqual(afterCancellation, beforeCancellation)
    }

    private func makeTracker() -> (UtteranceTracker, FreshnessClock, LiveHintsStopToken) {
        let clock = FreshnessClock()
        let token = LiveHintsStopToken()
        let tracker = UtteranceTracker(speaker: .me,
                                       transcriber: FakeLiveTranscriber(),
                                       audioSource: FakeLiveAudioSource(samples: []),
                                       stopToken: token,
                                       timingNow: { clock.now })
        return (tracker, clock, token)
    }
}

private final class FreshnessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}
