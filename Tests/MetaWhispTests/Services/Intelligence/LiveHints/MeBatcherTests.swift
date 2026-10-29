import XCTest
@testable import MetaWhisp

/// The user's own side, batched: the finished utterances are joined into one
/// clip and transcribed once.
///
/// The rules under test are the triggers — 20 s of speech, the owner's
/// shortcut, 45 s of age — the 25 s ceiling on one batch, and the layout
/// that gives every sentence the time of the utterance it came from.
final class MeBatcherTests: XCTestCase {

    // MARK: - The helpers

    /// The fake recorder behind the batcher: every sample carries its own
    /// index, so a test can see where an utterance landed in the batch.
    private final class BatchAudioSource: LiveAudioSource, @unchecked Sendable {
        func samples(from: Int, count: Int) async -> [Float] {
            guard count > 0 else { return [] }
            return (0..<count).map { Float(from + $0) }
        }
    }

    /// The batches the batcher sent.
    private final class BatchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [MeBatcher.Batch] = []

        func record(_ batch: MeBatcher.Batch) {
            lock.withLock { stored.append(batch) }
        }

        var all: [MeBatcher.Batch] { lock.withLock { stored } }
    }

    private func makeBatcher(engine: FakeLiveEngine,
                             pauseWindows: @escaping @Sendable () async -> [LiveSampleRange] = { [] },
                             clock: LiveValueBox<Int> = LiveValueBox(0)
                             ) async -> (MeBatcher, BatchLog) {
        let transcriber = LiveEngineTranscriber(
            engineProvider: { engine },
            languageProvider: { "en" },
            promptWordsProvider: { _ in [] },
            generationProvider: { 1 }
        )
        let batcher = MeBatcher(audioSource: BatchAudioSource(),
                                transcriber: transcriber,
                                pauseWindows: pauseWindows,
                                streamClock: { clock.value })
        let log = BatchLog()
        await batcher.setHandler { batch in log.record(batch) }
        return (batcher, log)
    }

    /// One second of the user's speech, starting at `start`.
    private func second(_ start: Int) -> MeBatcher.Utterance {
        MeBatcher.Utterance(startSample: start, endSample: start + 16_000)
    }

    // MARK: - The triggers

    /// Twenty seconds of speech send the batch out.
    func testTheBatchGoesOutAtTwentySecondsOfSpeech() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        await batcher.append(MeBatcher.Utterance(startSample: 0, endSample: 160_000))
        XCTAssertEqual(log.all.count, 0, "the batch went out too early")

        await batcher.append(MeBatcher.Utterance(startSample: 160_000, endSample: 320_000))

        XCTAssertEqual(log.all.count, 1, "the batch did not go out at 20 s of speech")
        XCTAssertEqual(log.all.first?.placements.count, 2)
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// The owner's shortcut sends the batch that is waiting.
    func testTheBatchGoesOutWhenTheOwnerAsksForIt() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        await batcher.append(second(0))
        XCTAssertEqual(log.all.count, 0, "the batch went out on its own")

        await batcher.flush()

        XCTAssertEqual(log.all.count, 1, "the shortcut did not send the batch")
        XCTAssertEqual(log.all.first?.placements.count, 1)
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// An utterance that waited 45 s cannot stay in the batch any longer.
    func testTheBatchGoesOutWhenTheOldestUtteranceIsFortyFiveSecondsOld() async {
        let clock = LiveValueBox(0)
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine(), clock: clock)

        await batcher.append(second(0))
        XCTAssertEqual(log.all.count, 0)

        // 45 s later the utterance is too old to wait for.
        clock.value = 45 * 16_000
        await batcher.append(second(46_000))

        XCTAssertEqual(log.all.count, 1, "the old utterance stayed in the batch")
        XCTAssertEqual(log.all.first?.placements.count, 1)
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 1, "the new utterance was sent with the old one")
    }

    /// The batch that waited 45 s goes out on its own: no other utterance and
    /// no shortcut are needed (§3.2).
    func testTheBatchGoesOutOnItsOwnWhenTheOldestUtteranceIsFortyFiveSecondsOld() async {
        let clock = LiveValueBox(0)
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine(), clock: clock)

        await batcher.append(second(0))
        XCTAssertEqual(log.all.count, 0)

        // 45 s later the utterance is too old to wait for — and nobody says
        // anything, so nothing brings the batch out but the age.
        clock.value = 45 * 16_000
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, log.all.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(log.all.count, 1, "the batch did not go out on its own")
        XCTAssertEqual(log.all.first?.placements.count, 1)
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// One batch holds at most 25 s of audio. With short utterances the
    /// ceiling comes before the 20 s of speech: the silence between them
    /// takes up the room the speech leaves.
    func testOneBatchHoldsAtMostTwentyFiveSeconds() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        // One-second utterances: sixteen of them hold 16 s of speech and 24 s
        // of audio — the seventeenth would take the audio past 25 s.
        for index in 0..<17 {
            await batcher.append(second(index * 16_000))
        }

        XCTAssertEqual(log.all.count, 1, "the ceiling did not send the batch out")
        guard let batch = log.all.first else { return XCTFail("no batch was sent") }
        XCTAssertEqual(batch.placements.count, 16, "the batch held the wrong number of utterances")
        XCTAssertLessThanOrEqual(batch.sampleCount, 25 * 16_000,
                                 "a batch held more than 25 s of audio")
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 1, "the utterance that did not fit was thrown away")
    }

    /// One long utterance does not make a batch that is too long: it is split
    /// before the batch is built (§3.2).
    func testOneLongUtteranceIsSplitBeforeTheBatchIsBuilt() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        // 26 seconds of speech in one utterance — the tracker allows nearly
        // 30 s, and a batch holds at most 25 s.
        await batcher.append(MeBatcher.Utterance(startSample: 0, endSample: 26 * 16_000))

        guard let batch = log.all.first else {
            return XCTFail("no batch was sent")
        }
        XCTAssertLessThanOrEqual(batch.sampleCount, 25 * 16_000,
                                 "a batch held more than 25 s of audio")
        // The words of the long utterance are not thrown away: the rest of
        // it waits for the next batch.
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 1, "the rest of the long utterance was thrown away")
    }

    /// The utterances keep the order they arrived in: an append that waits
    /// for its batch does not let a later utterance overtake it (§3.2).
    func testTheUtterancesKeepTheOrderTheyArrivedIn() async {
        // The engine is slow: the batch waits for its transcription.
        let engine = FakeLiveEngine(responder: { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return FakeLiveEngine.result("the words")
        })
        let (batcher, log) = await makeBatcher(engine: engine)

        // Sixteen one-second utterances fill the batch.
        for index in 0..<16 {
            await batcher.append(second(index * 16_000))
        }

        // The next utterance does not fit: the batch goes out first, and that
        // takes a moment. A later utterance must not overtake it.
        let overflowing = Task { await batcher.append(second(16 * 16_000)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await batcher.append(second(17 * 16_000))
        await overflowing.value

        await batcher.flush()

        guard let last = log.all.last else {
            return XCTFail("no batch was sent")
        }
        XCTAssertEqual(last.placements.map(\.utterance.startSample),
                       [16 * 16_000, 17 * 16_000],
                       "the utterances did not keep the order they arrived in")
    }

    // MARK: - The dictation pause

    /// A mic utterance inside a dictation pause is not part of the meeting.
    func testAnUtteranceInsideAPauseWindowIsDropped() async {
        let pause = LiveSampleRange(from: 0, to: 16_000)
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine(),
                                         pauseWindows: { [pause] })

        await batcher.append(second(0))
        await batcher.flush()

        XCTAssertTrue(log.all.isEmpty, "the dictated words went into the meeting")
        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// An utterance outside the pause window is kept.
    func testAnUtteranceOutsideThePauseWindowIsKept() async {
        let pause = LiveSampleRange(from: 100_000, to: 116_000)
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine(),
                                         pauseWindows: { [pause] })

        await batcher.append(second(0))
        await batcher.flush()

        XCTAssertEqual(log.all.count, 1, "the utterance was dropped although it was outside the pause")
    }

    // MARK: - The layout

    /// The batch keeps every utterance's own range and where it sits inside
    /// the clip.
    func testTheBatchKeepsEveryUtteranceRange() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        await batcher.append(second(0))
        await batcher.append(second(16_000))
        await batcher.flush()

        guard let batch = log.all.first else {
            return XCTFail("no batch was sent")
        }
        XCTAssertEqual(batch.placements.map(\.utterance.startSample), [0, 16_000])
        XCTAssertEqual(batch.placements.map(\.utterance.endSample), [16_000, 32_000])
        // The second utterance follows the first and half a second of silence.
        XCTAssertEqual(batch.placements.map(\.offset), [0, 16_000 + 8_000])
        // The clip holds the two utterances and a separator after each.
        XCTAssertEqual(batch.sampleCount, 16_000 + 8_000 + 16_000 + 8_000)
    }

    /// Every sentence takes the start of the utterance its segment came from.
    func testEachSentenceTakesTheStartOfItsUtterance() async {
        let engine = FakeLiveEngine(responder: { _ in
            FakeLiveEngine.result("The first sentence. The second sentence.", segments: [
                TranscriptionResult.Segment(text: "The first sentence.", start: 0, end: 1),
                TranscriptionResult.Segment(text: "The second sentence.", start: 1.5, end: 2),
            ])
        })
        let (batcher, log) = await makeBatcher(engine: engine)

        await batcher.append(second(0))
        await batcher.append(second(16_000))
        await batcher.flush()

        guard let batch = log.all.first else {
            return XCTFail("no batch was sent")
        }
        XCTAssertEqual(batch.sentences.map(\.text), ["The first sentence.", "The second sentence."])
        XCTAssertEqual(batch.sentences.map(\.startSample), [0, 16_000],
                       "the sentences did not take the time of their utterance")
    }

    /// An engine that returns no segment times gives every sentence the start
    /// of the batch's first utterance.
    func testWithNoSegmentsEverySentenceTakesTheStartOfTheBatch() async {
        let engine = FakeLiveEngine(responder: { _ in
            FakeLiveEngine.result("The first sentence. The second sentence.")
        })
        let (batcher, log) = await makeBatcher(engine: engine)

        await batcher.append(second(0))
        await batcher.append(second(16_000))
        await batcher.flush()

        guard let batch = log.all.first else {
            return XCTFail("no batch was sent")
        }
        XCTAssertEqual(batch.sentences.map(\.text), ["The first sentence.", "The second sentence."])
        XCTAssertEqual(batch.sentences.map(\.startSample), [0, 0],
                       "the sentences did not take the start of the batch")
    }

    /// A text with a number in it is not two sentences.
    func testTheTextIsSplitIntoSentences() {
        XCTAssertEqual(MeBatcher.splitSentences("One. Two? Three!"), ["One.", "Two?", "Three!"])
        XCTAssertEqual(MeBatcher.splitSentences("The version 3.14 is out"), ["The version 3.14 is out"])
        XCTAssertEqual(MeBatcher.splitSentences("Wait... what?"), ["Wait...", "what?"])
        XCTAssertEqual(MeBatcher.splitSentences("no terminator here"), ["no terminator here"])
    }

    // MARK: - The end of the meeting

    /// The meeting ends before the batch goes out: the words that were waiting
    /// are never asked for (§6.15).
    func testTheStoppedBatcherKeepsNothingOfTheMeetingThatIsOver() async {
        let (batcher, log) = await makeBatcher(engine: FakeLiveEngine())

        await batcher.append(second(0))
        await batcher.stop()

        let pending = await batcher.pendingCount
        XCTAssertEqual(pending, 0,
                       "the stopped batcher kept the words of a meeting that is over")

        await batcher.flush()
        XCTAssertTrue(log.all.isEmpty,
                      "the stopped batcher sent the batch of a meeting that is over")
    }
}
