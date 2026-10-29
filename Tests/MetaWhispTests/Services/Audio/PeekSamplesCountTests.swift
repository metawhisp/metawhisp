import XCTest
@testable import MetaWhisp

/// The bounded peek: the live hints read one utterance's worth of samples and
/// must not copy the whole tail of the meeting behind it.
///
/// The window is `[from, from + count)`, clamped to what the buffer holds.
/// The old `peekSamples(from:)` still reads the whole tail — the live advisor
/// and the final pass depend on it — so it is pinned here too.
@MainActor
final class PeekSamplesCountTests: XCTestCase {

    // MARK: - The window

    /// The window holds its own samples and nothing else.
    func testTheWindowCopiesOnlyItsOwnSamples() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]

        XCTAssertEqual(SampleWindow.slice(samples, from: 1, count: 2), [0.2, 0.3],
                       "the window is not the window")
        XCTAssertEqual(SampleWindow.slice(samples, from: 3, count: 10), [0.4, 0.5],
                       "the window was not clamped to what exists")
        XCTAssertEqual(SampleWindow.slice(samples, from: 0, count: 0), [],
                       "a window of nothing is nothing")
        XCTAssertEqual(SampleWindow.slice(samples, from: 9, count: 2), [],
                       "a window past the end is nothing")
        XCTAssertEqual(SampleWindow.slice(samples, from: -2, count: 2), [0.1, 0.2],
                       "a start before the beginning counts from the beginning")
    }

    // MARK: - The microphone

    /// The mic's peek reads the window out of a real buffer.
    func testTheMicPeekReadsOnlyItsWindow() {
        let mic = AudioRecordingService()
        fill(mic)

        XCTAssertEqual(mic.currentSampleCount, 16_000, "the test buffer is not one second")
        XCTAssertEqual(mic.peekSamples(from: 100, count: 50).count, 50,
                       "the peek did not read the window it was asked for")
        XCTAssertEqual(mic.peekSamples(from: 100, count: 50_000).count, 15_900,
                       "the peek was not clamped to what exists")
        XCTAssertTrue(mic.peekSamples(from: 16_000, count: 10).isEmpty,
                      "the peek read past the end of the buffer")
        XCTAssertTrue(mic.peekSamples(from: 100, count: 0).isEmpty,
                      "a window of nothing is nothing")
        XCTAssertEqual(mic.peekSamples(from: -5, count: 10).count, 10,
                       "a start before the beginning must count from the beginning")
    }

    /// The old peek still reads the whole tail.
    func testTheOldMicPeekStillReadsTheWholeTail() {
        let mic = AudioRecordingService()
        fill(mic)

        XCTAssertEqual(mic.peekSamples(from: 100).count, 15_900,
                       "the old peek changed — the live advisor depends on it")
    }

    // MARK: - The system channel

    /// The system channel's peek reads the window out of a real buffer.
    func testTheSystemChannelPeekReadsOnlyItsWindow() throws {
        let system = SystemAudioCaptureService()
        system.screenRecordingGranted = { false }
        try system.start(leadingSilenceSeconds: 1)
        defer { system.stop() }

        XCTAssertEqual(system.currentSampleCount, 16_000, "the test buffer is not one second")
        XCTAssertEqual(system.peekSamples(from: 100, count: 50).count, 50,
                       "the peek did not read the window it was asked for")
        XCTAssertEqual(system.peekSamples(from: 100, count: 50_000).count, 15_900,
                       "the peek was not clamped to what exists")
        XCTAssertTrue(system.peekSamples(from: 16_000, count: 10).isEmpty,
                      "the peek read past the end of the buffer")
        XCTAssertEqual(system.peekSamples(from: 100).count, 15_900,
                       "the old peek changed — the live advisor depends on it")
    }

    // MARK: - The helper

    /// One second of silence on the mic's timeline, without a microphone.
    private func fill(_ mic: AudioRecordingService) {
        let t0 = SuspendingClock.now
        mic.beginTimeline()
        mic.fillSilence(bufferSampleTime: 1_000_000, inputRate: 48_000, capturedAt: t0)
        mic.fillSilence(bufferSampleTime: 1_000_000 + 48_000, inputRate: 48_000,
                        capturedAt: t0 + .seconds(1))
    }
}
