import XCTest
@testable import MetaWhisp

/// The acoustic half of the live hints: which samples are speech.
///
/// The floor is the 20th percentile of the frame levels over the last 8 s, so
/// a quiet room does not turn every breath into a sentence and a noisy room
/// does not hide the speaker. Two properties carry the whole design and are
/// pinned here: the floor follows the room, and room noise never becomes
/// speech.
final class SpeechActivityTests: XCTestCase {

    // MARK: - The floor

    /// The floor starts from the first second of the call and follows a noise
    /// step within the 8 s it looks back over.
    func testTheFloorBootstrapsFromTheFirstSecondAndFollowsANoiseStepWithinEightSeconds() {
        var activity = SpeechActivity()

        activity.append(LiveCallFixture.audio([.speech(1, rms: 0.002)]))
        XCTAssertEqual(activity.floor, 0.002, accuracy: 0.0002,
                       "the floor comes from the first second of the call")

        activity.append(LiveCallFixture.audio([.speech(8, rms: 0.008)]))
        XCTAssertEqual(activity.floor, 0.008, accuracy: 0.0005,
                       "the floor follows the step within 8 s")
    }

    /// The floor never leaves its clamped range, whatever the room does.
    func testTheFloorStaysInsideItsClampedRange() {
        var activity = SpeechActivity()
        activity.append(LiveCallFixture.audio([.speech(2, rms: 0.00001)]))
        XCTAssertEqual(activity.floor, SpeechActivity.floorMinimum, accuracy: 0.000_001,
                       "a dead-silent room still leaves the floor at its minimum")

        var loud = SpeechActivity()
        loud.append(LiveCallFixture.audio([.speech(2, rms: 0.5)]))
        XCTAssertEqual(loud.floor, SpeechActivity.floorMaximum, accuracy: 0.000_001,
                       "a loud room still leaves the floor at its maximum")
    }

    /// Constant noise is never speech: the floor sits at the noise level, and
    /// speech needs twice the floor plus a margin.
    func testConstantNoiseIsNeverSpeech() {
        var activity = SpeechActivity()
        let frames = activity.append(LiveCallFixture.audio([.speech(3, rms: 0.005)]))

        XCTAssertFalse(frames.contains { $0.isSpeech }, "room noise was taken for speech")
        XCTAssertFalse(frames.contains { $0.onset != nil }, "room noise opened an utterance")
    }

    // MARK: - Onset

    /// One loud frame is not an onset: the detector waits for a second one, so
    /// a single bang does not become a sentence.
    func testAnOnsetNeedsTwoFramesInARow() {
        var activity = SpeechActivity()
        activity.append(LiveCallFixture.audio([.silence(1)]))

        let first = activity.append(LiveCallFixture.frame(rms: 0.05, seed: 7))
        XCTAssertTrue(first.allSatisfy { $0.isSpeech }, "the frame is loud")
        XCTAssertNil(first.first?.onset, "one frame is not an onset")

        let second = activity.append(LiveCallFixture.frame(rms: 0.05, seed: 8))
        XCTAssertNotNil(second.first?.onset, "two frames in a row are an onset")
    }

    /// The onset keeps 0.25 s before the speech, so the first syllable is not
    /// cut off the front of the clip.
    func testTheOnsetKeepsThePreRoll() throws {
        var activity = SpeechActivity()
        activity.append(LiveCallFixture.audio([.silence(1)]))

        let first = activity.append(LiveCallFixture.frame(rms: 0.05, seed: 7))
        let second = activity.append(LiveCallFixture.frame(rms: 0.05, seed: 8))
        let onset = try XCTUnwrap(second.first?.onset)

        XCTAssertEqual(onset.startSample, (first.first?.startSample ?? 0) - SpeechActivity.preRollSamples,
                       "the utterance starts 0.25 s before the speech")
        XCTAssertEqual(onset.speechStartSample, first.first?.startSample,
                       "the speech itself starts where it was heard")
    }

    /// The detector sees samples, not frames: the same audio must give the
    /// same answer however it was chopped up.
    func testTheResultDoesNotDependOnHowTheSamplesWereBatched() {
        let audio = LiveCallFixture.audio([.silence(1), .speech(1), .silence(1), .speech(0.5)])

        var whole = SpeechActivity()
        let wholeFrames = whole.append(audio)

        var chopped = SpeechActivity()
        var choppedFrames: [SpeechActivity.Frame] = []
        var index = 0
        while index < audio.count {
            let end = min(index + 137, audio.count)
            choppedFrames.append(contentsOf: chopped.append(Array(audio[index ..< end])))
            index = end
        }

        XCTAssertEqual(wholeFrames.map(\.onset), choppedFrames.map(\.onset),
                       "the onsets moved when the audio was batched differently")
        XCTAssertEqual(wholeFrames.map(\.isSpeech), choppedFrames.map(\.isSpeech),
                       "the speech frames moved when the audio was batched differently")
        XCTAssertEqual(whole.floor, chopped.floor, accuracy: 0.000_001,
                       "the floor moved when the audio was batched differently")
    }
}
