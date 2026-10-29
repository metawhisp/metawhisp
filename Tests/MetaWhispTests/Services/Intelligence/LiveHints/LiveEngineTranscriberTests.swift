import XCTest
@testable import MetaWhisp

/// The live calls: the queues of §3.2.
///
/// Every live call goes through one adapter, so the rules live in one place:
/// at most one call in flight per stream, a deadline of 8 s, no billing at
/// all, and the results of another recording thrown away.
final class LiveEngineTranscriberTests: XCTestCase {

    // MARK: - The helpers

    private func makeTranscriber(
        engine: FakeLiveEngine,
        engineProvider: (@Sendable () async -> (any TranscriptionEngine)?)? = nil,
        generation: @escaping @Sendable () async -> Int = { 1 },
        deadline: Duration = LiveEngineTranscriber.deadline,
        maximumQueueAge: Duration = LiveEngineTranscriber.maximumQueueAge,
        onBalanceSpent: (@Sendable () -> Void)? = nil
    ) -> LiveEngineTranscriber {
        LiveEngineTranscriber(
            engineProvider: engineProvider ?? { engine },
            languageProvider: { "en" },
            promptWordsProvider: { _ in ["a prompt word"] },
            generationProvider: generation,
            onBalanceSpent: onBalanceSpent,
            deadline: deadline,
            maximumQueueAge: maximumQueueAge
        )
    }

    // MARK: - The rules

    /// The deadlines are the ones the spec names.
    func testTheDeadlineIsEightSecondsAndTheQueueAgeIsSixty() {
        XCTAssertEqual(LiveEngineTranscriber.deadline, .seconds(8))
        XCTAssertEqual(LiveEngineTranscriber.maximumQueueAge, .seconds(60))
    }

    /// A live pass is part of the meeting, which is booked once when it ends:
    /// no live call adds monthly minutes — not even one that asks for it.
    func testEveryLiveCallBillsNothing() async {
        let engine = FakeLiveEngine()
        let transcriber = makeTranscriber(engine: engine)

        _ = await transcriber.call(samples: [0.1], stream: .them)
        _ = await transcriber.call(samples: [0.2], stream: .me)
        // The tracker's own protocol carries the flag — it must not reach the
        // engine either.
        _ = try? await transcriber.transcribe(samples: [0.3],
                                              range: LiveSampleRange(from: 0, to: 1),
                                              countUsage: true)

        XCTAssertEqual(engine.calls.count, 3, "not every call reached the engine")
        XCTAssertTrue(engine.calls.allSatisfy { $0.countUsage == false },
                      "a live call billed the meeting's minutes")
    }

    /// The engine is asked with the language and the prompt words it was
    /// given.
    func testTheEngineIsAskedWithTheLanguageAndThePromptWords() async {
        let engine = FakeLiveEngine()
        let transcriber = LiveEngineTranscriber(
            engineProvider: { engine },
            languageProvider: { "de" },
            promptWordsProvider: { language in language == "de" ? ["ein Wort"] : [] },
            generationProvider: { 1 }
        )

        _ = await transcriber.call(samples: [0.1], stream: .them)

        XCTAssertEqual(engine.calls.first?.language, "de")
        XCTAssertEqual(engine.calls.first?.promptWords, ["ein Wort"])
    }

    // MARK: - The queues

    /// A slow `.me` batch never blocks the other side.
    func testTheOtherSideIsNotBlockedByASlowBatch() async {
        let engine = FakeLiveEngine(responder: { index in
            if index == 0 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            return FakeLiveEngine.result("the answer")
        })
        let transcriber = makeTranscriber(engine: engine)

        async let batch = transcriber.call(samples: [0.1], stream: .me)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let them = await transcriber.call(samples: [0.2], stream: .them)

        guard case .text(let result) = them else {
            return XCTFail("the other side waited for the batch — \(them)")
        }
        XCTAssertEqual(result.text, "the answer")
        _ = await batch
    }

    /// The deadline drops the text of that clip — and the outcome says so.
    func testTheDeadlineDropsTheText() async {
        let engine = FakeLiveEngine(responder: { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return FakeLiveEngine.result("too late")
        })
        let transcriber = makeTranscriber(engine: engine, deadline: .milliseconds(100))

        let outcome = await transcriber.call(samples: [0.1], stream: .them)

        guard case .timeout = outcome else {
            return XCTFail("the call did not time out — \(outcome)")
        }
    }

    /// Work that waited longer than it may before it could start is dropped.
    func testWorkThatWaitedTooLongIsDropped() async {
        let engine = FakeLiveEngine()
        let transcriber = makeTranscriber(engine: engine,
                                          engineProvider: { nil },
                                          maximumQueueAge: .milliseconds(200))

        let outcome = await transcriber.call(samples: [0.1], stream: .them)

        guard case .failed(let error) = outcome else {
            return XCTFail("the work was not dropped — \(outcome)")
        }
        XCTAssertEqual(error as? LiveTranscriptionError, .waitedTooLong)
        XCTAssertEqual(engine.callCount, 0, "the engine was called after the work gave up")
    }

    /// A timed-out call still holds its stream: the next call on that stream
    /// waits for the engine call to truly return.
    func testATimedOutCallBlocksItsStreamUntilItTrulyReturns() async {
        let engine = FakeLiveEngine(responder: { index in
            if index == 0 {
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            return FakeLiveEngine.result("the text")
        })
        let transcriber = makeTranscriber(engine: engine, deadline: .milliseconds(100))

        let first = await transcriber.call(samples: [0.1], stream: .them)
        guard case .timeout = first else {
            return XCTFail("the first call did not time out — \(first)")
        }

        let second = Task { await transcriber.call(samples: [0.2], stream: .them) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.callCount, 1,
                       "a second call started while the first was still running")

        _ = await second.value
        XCTAssertEqual(engine.callCount, 2, "the second call never started")
    }

    /// A cancelled call says so.
    func testACancelledCallSaysCancelled() async {
        let engine = FakeLiveEngine(responder: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return FakeLiveEngine.result("never")
        })
        let transcriber = makeTranscriber(engine: engine)

        let task = Task { await transcriber.call(samples: [0.1], stream: .them) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            return XCTFail("the call did not say it was cancelled — \(outcome)")
        }
    }

    /// Two calls on one stream: the second one starts only after the first
    /// has truly returned.
    ///
    /// The slot is taken before the readiness and the language lookup, so a
    /// second caller cannot slip in while the first one is waiting for the
    /// engine (§3.2).
    func testTwoCallsOnOneStreamStartOneAfterTheOther() async {
        let engine = FakeLiveEngine(responder: { _ in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return FakeLiveEngine.result("the text")
        })
        // The language takes its time: the window between the readiness and
        // the call is wide enough for a second caller to slip into.
        let transcriber = LiveEngineTranscriber(
            engineProvider: { engine },
            languageProvider: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return "en"
            },
            promptWordsProvider: { _ in [] },
            generationProvider: { 1 })

        let first = Task { await transcriber.call(samples: [0.1], stream: .them) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { await transcriber.call(samples: [0.2], stream: .them) }

        // The first call is in the engine; the second one waits for it.
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(engine.callCount, 1,
                       "two calls were in the engine at the same time")

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(engine.callCount, 2, "the second call never started")
    }

    // MARK: - The generation

    /// A result for another recording is thrown away: the meeting it belonged
    /// to is over.
    func testAResultFromAnotherGenerationIsDiscarded() async {
        let generation = LiveValueBox(1)
        let engine = FakeLiveEngine(responder: { _ in
            generation.value = 2      // the meeting stopped and another began
            return FakeLiveEngine.result("the text of a meeting that is over")
        })
        let transcriber = makeTranscriber(engine: engine, generation: { generation.value })

        let outcome = await transcriber.call(samples: [0.1], stream: .them)

        guard case .failed(let error) = outcome else {
            return XCTFail("the result of another recording came through — \(outcome)")
        }
        XCTAssertEqual(error as? LiveTranscriptionError, .recordingChanged)
    }

    /// A call that was made in the meeting before never reaches the engine of
    /// the next one.
    ///
    /// The generation belongs to the request, not to the moment the request
    /// gets its turn: a call that waits for its stream must not pick up the
    /// generation of the meeting that started while it waited.
    func testACallThatWaitedForItsStreamNeverReachesTheEngineOfTheNextMeeting() async {
        let generation = LiveValueBox(1)
        let latch = RequestGate()
        let engine = FakeLiveEngine(responder: { index in
            // The first call stays in the engine until the test lets it go.
            if index == 0 { await latch.wait() }
            return FakeLiveEngine.result("the text")
        })
        let transcriber = makeTranscriber(engine: engine, generation: { generation.value })

        // The first call takes the stream and stays in the engine.
        let first = Task { await transcriber.call(samples: [0.1], stream: .them) }
        let deadline = Date().addingTimeInterval(5)
        while engine.callCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(engine.callCount, 1, "the first call never reached the engine")

        // The second call waits for its turn.
        let second = Task { await transcriber.call(samples: [0.2], stream: .them) }
        while await transcriber.waitingCallCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let waitingCount = await transcriber.waitingCallCount
        XCTAssertEqual(waitingCount, 1, "the second call never waited for its turn")

        // The meeting ends and another one begins.
        generation.value = 2

        // The first call comes back: the second one gets the stream.
        latch.open()
        let outcome = await second.value
        _ = await first.value

        XCTAssertEqual(engine.callCount, 1,
                       "the queued call reached the engine of the next meeting")
        guard case .failed(let error) = outcome else {
            return XCTFail("the queued call was not dropped — \(outcome)")
        }
        XCTAssertEqual(error as? LiveTranscriptionError, .recordingChanged)
    }

    // MARK: - The stop

    /// The session is stopped while the task that asks the engine is on its
    /// way: the engine is not asked at all (§6.15).
    ///
    /// The check that stands before the task is created is not enough: a
    /// cancellation is cooperative, and the body of the task runs even when
    /// the task was cancelled. The token is checked inside the task, right
    /// before the engine is asked.
    func testTheEngineIsNotAskedWhenTheSessionStoppedBeforeTheTaskBegan() async {
        let engine = FakeLiveEngine()
        let token = LiveHintsStopToken()
        let gate = RequestGate()
        let transcriber = LiveEngineTranscriber(
            engineProvider: { engine },
            languageProvider: { "en" },
            promptWordsProvider: { _ in [] },
            generationProvider: { 1 },
            stopToken: token,
            beforeDispatch: { await gate.wait() })

        let call = Task { await transcriber.call(samples: [0.1], stream: .them) }
        // The task is on its way: it waits before the engine is asked.
        let deadline = Date().addingTimeInterval(5)
        while gate.waiterCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(gate.waiterCount, 1, "the task never reached the engine")

        // The meeting ends while the task is on its way.
        token.stop()
        gate.open()

        let outcome = await call.value
        XCTAssertEqual(engine.callCount, 0, "the engine was asked after the session stopped")
        guard case .cancelled = outcome else {
            return XCTFail("the call did not say it was cancelled — \(outcome)")
        }
    }

    // MARK: - The balance

    /// The monthly meeting minutes running out stops the live hints for the
    /// meeting — and every call after that fails at once, without the engine.
    func testASpentBalanceFailsEveryCallAtOnce() async {
        let spent = expectation(description: "the balance ran out")
        let engine = FakeLiveEngine(responder: { _ in
            throw FakeEngineError(description: "Monthly limit reached")
        })
        let transcriber = makeTranscriber(engine: engine, onBalanceSpent: { spent.fulfill() })

        let first = await transcriber.call(samples: [0.1], stream: .them)
        guard case .failed(let error) = first else {
            return XCTFail("the call did not fail — \(first)")
        }
        XCTAssertTrue("\(error)".contains("Monthly limit reached"),
                      "the error lost the server's message")
        await fulfillment(of: [spent], timeout: 2)

        let spentFlag = await transcriber.isBalanceSpent
        XCTAssertTrue(spentFlag, "the balance was not marked as spent")

        let second = await transcriber.call(samples: [0.2], stream: .them)
        guard case .failed = second else {
            return XCTFail("the call after the balance ran out did not fail — \(second)")
        }
        XCTAssertEqual(engine.callCount, 1, "the engine was called after the balance ran out")
    }
}
