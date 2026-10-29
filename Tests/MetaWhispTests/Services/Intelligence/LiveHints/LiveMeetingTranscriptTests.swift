import XCTest
@testable import MetaWhisp

/// The live transcript: the lines of the meeting as they are said.
///
/// The `.them` side arrives out of order — a candidate that waited for the
/// engine comes back after a later utterance — so the lines are ordered by
/// their start, not by their arrival. The render keeps the newest lines and
/// drops the oldest whole ones, and the divider shows what came after the
/// last answer.
final class LiveMeetingTranscriptTests: XCTestCase {

    // MARK: - The helpers

    @discardableResult
    private func appendThem(_ transcript: LiveMeetingTranscript,
                             text: String,
                             from startSample: Int,
                             to endSample: Int? = nil,
                             isContinuation: Bool = false) async -> LiveMeetingTranscript.Line? {
        await transcript.appendThem(text: text,
                                    startSample: startSample,
                                    endSample: endSample ?? startSample + 16_000,
                                    rms: 0.05,
                                    isContinuation: isContinuation)
    }

    private func appendMe(_ transcript: LiveMeetingTranscript,
                          text: String,
                          from startSample: Int) async {
        await transcript.appendMe(parts: [LiveMeetingTranscript.Part(text: text,
                                                                      startSample: startSample,
                                                                      endSample: startSample + 16_000)],
                                   rms: 0.05)
    }

    // MARK: - The labels

    /// Every line says who said it.
    func testEveryLineSaysWhoSaidIt() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the other side", from: 0)
        await appendMe(transcript, text: "my own words", from: 16_000)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: the other side\nMe: my own words")
    }

    /// The lines are ordered by their start, not by their arrival.
    func testTheLinesAreOrderedByTheirStartNotByTheirArrival() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the later line", from: 32_000)
        await appendThem(transcript, text: "the earlier line", from: 0)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: the earlier line\nThem: the later line")
    }

    /// The oldest whole lines go when the transcript does not fit.
    func testTheOldestLinesAreDroppedWhenTheTranscriptDoesNotFit() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the first line", from: 0)
        await appendThem(transcript, text: "the second line", from: 16_000)
        await appendThem(transcript, text: "the third line", from: 32_000)

        // The two newest lines are 42 characters with the newline between
        // them; the third one does not fit.
        let rendered = await transcript.render(maxChars: 42)

        XCTAssertEqual(rendered, "Them: the second line\nThem: the third line",
                       "the oldest line was not dropped")
        XCTAssertFalse(rendered.contains("the first line"))
    }

    // MARK: - The divider

    /// The divider goes before the lines that came after the last answer.
    func testTheDividerGoesBeforeTheLinesThatCameAfterTheLastAnswer() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the first question", from: 0)
        await transcript.markAnswered()
        await appendThem(transcript, text: "the second question", from: 16_000)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered,
                       "Them: the first question\n[NEW SINCE LAST ANSWER]\nThem: the second question")
    }

    /// Without an answer there is no divider.
    func testThereIsNoDividerBeforeTheFirstAnswer() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the first question", from: 0)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertFalse(rendered.contains("[NEW SINCE LAST ANSWER]"))
    }

    // MARK: - The memo

    /// The lines that fall out of the window are folded into a rolling memo.
    func testTheLinesBeyondTheWindowAreFoldedIntoTheMemo() async {
        let folded = expectation(description: "the memo was folded")
        let provider: LiveMeetingTranscript.MemoProvider = { previousMemo, lines, _ in
            XCTAssertNil(previousMemo, "the first fold has no memo yet")
            XCTAssertFalse(lines.isEmpty, "the fold carried no lines")
            folded.fulfill()
            return "the meeting so far"
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)

        // Fifteen lines of 400 rendered characters: the window (4,000) is full
        // after ten of them, and the five that fell out of it add up to the
        // 2,000 that start a memo call.
        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()

        await fulfillment(of: [folded], timeout: 2)
        let memo = await transcript.memo
        XCTAssertEqual(memo, "the meeting so far", "the memo was not stored")
    }

    /// The fold asks with the token of the session it belongs to: the token
    /// travels with the fold, and the provider gets no other one (§6.15).
    func testTheFoldAsksWithTheTokenOfItsOwnSession() async {
        let token = LiveHintsStopToken()
        let seen = SeenBox<LiveHintsStopToken>()
        let folded = expectation(description: "the memo was folded")
        let provider: LiveMeetingTranscript.MemoProvider = { _, _, foldToken in
            seen.append(foldToken)
            folded.fulfill()
            return "the meeting so far"
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider, stopToken: token)

        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()

        await fulfillment(of: [folded], timeout: 2)
        XCTAssertTrue(seen.values.first === token,
                      "the fold asked with the token of another session")
    }

    /// The memo never runs ahead of an answer: the answer path has the
    /// meeting's attention first.
    func testTheMemoNeverRunsAheadOfAnAnswer() async {
        let provider: LiveMeetingTranscript.MemoProvider = { _, _, _ in
            XCTFail("the memo was folded before any answer")
            return nil
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)

        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let memo = await transcript.memo
        XCTAssertNil(memo, "the memo was folded before any answer")
    }

    /// A meeting that stays inside the window never calls for a memo.
    func testAMeetingInsideTheWindowNeverFoldsAMemo() async {
        let provider: LiveMeetingTranscript.MemoProvider = { _, _, _ in
            XCTFail("the memo was folded although the meeting stayed inside the window")
            return nil
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)

        let text = String(repeating: "a", count: 394)
        for index in 0..<9 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }

        let memo = await transcript.memo
        XCTAssertNil(memo)
    }

    /// The meeting ends before the lines fall out of the window: no memo is
    /// ever called for (§6.15).
    func testTheStoppedTranscriptNeverFoldsAMemo() async {
        let provider: LiveMeetingTranscript.MemoProvider = { _, _, _ in
            XCTFail("the memo was folded although the meeting was over")
            return nil
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)
        await transcript.stop()

        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let memo = await transcript.memo
        XCTAssertNil(memo)
    }

    /// The meeting ends while the fold is still running: the memo it brings
    /// back belongs to a meeting that is over (§6.15).
    func testTheStoppedTranscriptDropsTheMemoThatIsBeingFolded() async {
        let gate = MemoGate()
        let provider: LiveMeetingTranscript.MemoProvider = { _, _, _ in
            await gate.wait()
            return "the meeting so far"
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)

        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()

        // The meeting ends while the fold is still waiting.
        await transcript.stop()
        gate.open()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let memo = await transcript.memo
        XCTAssertNil(memo, "the stopped transcript kept the memo of a meeting that is over")
    }

    // MARK: - The filters

    /// The operation gives back the line it made — or the rejection, when the
    /// gate dropped the text.
    func testTheLineIsGivenBackAndTheRejectionIsToldApart() async {
        let transcript = LiveMeetingTranscript()

        let kept = await appendThem(transcript, text: "the first question", from: 0)
        XCTAssertEqual(kept?.text, "the first question", "the line was not given back")

        let rejected = await appendThem(transcript, text: "To be continued.", from: 16_000)
        XCTAssertNil(rejected, "the rejected text was given back as a line")

        let joined = await appendThem(transcript, text: "and the second part",
                                      from: 16_000, isContinuation: true)
        XCTAssertEqual(joined?.text, "the first question and the second part",
                       "the joined line was not given back")
    }

    /// Two folds do not run at the same time: the second one waits for the
    /// first and builds on the memo it brought back.
    func testTheFoldsAreOneAfterAnother() async {
        let log = MemoFoldLog()
        let transcript = LiveMeetingTranscript(memoProvider: log.provider)

        // Enough text to fill the window and start a fold.
        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()

        // More text arrives while the fold is running: a second fold is due.
        for index in 15..<30 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(log.folds.count, 1, "a second fold started while the first one was running")

        // The first fold comes back: the second one starts on top of it.
        log.openTheFirstFold()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, log.folds.count < 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(log.folds.count, 2, "the second fold never started")
        guard log.folds.count == 2 else { return }
        XCTAssertEqual(log.folds[1].previous, "the summary 1",
                       "the second fold did not build on the memo of the first")
    }

    /// A fold that failed leaves its lines eligible: they are folded with the
    /// next one.
    func testAFailedFoldLeavesItsLinesEligible() async {
        let folds = SeenBox<[LiveMeetingTranscript.Line]>()
        let shouldFail = LiveValueBox(true)
        let provider: LiveMeetingTranscript.MemoProvider = { _, lines, _ in
            folds.append(lines)
            if shouldFail.value { return nil }
            return "the meeting so far"
        }
        let transcript = LiveMeetingTranscript(memoProvider: provider)

        let text = String(repeating: "a", count: 394)
        for index in 0..<15 {
            await appendThem(transcript, text: text, from: index * 16_000)
        }
        await transcript.markAnswered()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(folds.values.count, 1, "the fold did not run")
        let afterFailure = await transcript.memo
        XCTAssertNil(afterFailure, "a fold that failed stored a memo")

        // The next fold works: the lines of the failed fold are still
        // eligible.
        shouldFail.value = false
        await appendThem(transcript, text: text, from: 15 * 16_000)
        await transcript.markAnswered()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(folds.values.count, 2, "the lines of the failed fold were lost")
        guard folds.values.count == 2 else { return }
        XCTAssertGreaterThan(folds.values[1].count, folds.values[0].count,
                             "the second fold did not carry the lines of the failed one")
        let memo = await transcript.memo
        XCTAssertEqual(memo, "the meeting so far")
    }

    /// The gate drops the artifacts before the line is a line.
    func testTheGateDropsAnArtifact() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "", from: 0)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "", "an empty line became a line")
    }

    /// The brand corrections repair the names the decoder mangled, on every kept line.
    func testTheCorrectionsRepairTheMangledNames() async {
        let transcript = LiveMeetingTranscript(corrections: { $0.replacingOccurrences(of: "Breevo", with: "Brevo") })
        await appendThem(transcript, text: "Breevo sends the mail", from: 0)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: Brevo sends the mail")
    }

    /// The microphone hears the speakers: a copy of the other side's words,
    /// said just now, is dropped.
    func testAnEchoOfTheOtherSideIsDropped() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "we should ship it on friday", from: 0)
        await appendMe(transcript, text: "we should ship it on friday", from: 0)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: we should ship it on friday",
                       "the echo of the other side was kept")
    }

    /// The user's own words are kept.
    func testTheUsersOwnWordsAreKept() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "we should ship it on friday", from: 0)
        await appendMe(transcript, text: "i agree about the deadline", from: 16_000)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: we should ship it on friday\nMe: i agree about the deadline")
    }

    // MARK: - The continuation

    /// A `.them` utterance that continues the one before it is joined to it:
    /// the joined text is the line.
    func testTheContinuationIsJoinedToThePreviousLine() async {
        let transcript = LiveMeetingTranscript()
        await appendThem(transcript, text: "the first part of the question", from: 0)
        await appendThem(transcript, text: "and the second part", from: 16_000, isContinuation: true)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: the first part of the question and the second part")
        let lines = await transcript.lines
        XCTAssertEqual(lines.count, 1, "the continuation became a line of its own")
    }

    /// A continuation keeps the time of every one of its parts: the echo of
    /// the second part is dropped, although the joined line starts at the
    /// first part (§3.4).
    func testTheEchoOfTheSecondPartOfAContinuationIsDropped() async {
        let transcript = LiveMeetingTranscript()
        // The other side speaks from 0 to 3 s, pauses, and goes on at 4.8 s.
        await appendThem(transcript, text: "the budget is approved.", from: 0, to: 48_000)
        await appendThem(transcript, text: "send the contract please.", from: 76_800, to: 124_800,
                         isContinuation: true)
        // The microphone hears the second part at 4.55 s.
        await appendMe(transcript, text: "send the contract please.", from: 72_800)

        let rendered = await transcript.render(maxChars: 1_000)
        XCTAssertEqual(rendered, "Them: the budget is approved. send the contract please.",
                       "the echo of the second part was kept")
    }
}

/// The folds the test watches: every fold is recorded, and the first one
/// waits for the gate.
final class MemoFoldLog: @unchecked Sendable {
    /// One fold: the memo it had and the lines it took.
    struct Fold {
        let previous: String?
        let lines: [LiveMeetingTranscript.Line]
    }

    private let lock = NSLock()
    private var stored: [Fold] = []
    /// The gate the first fold waits for.
    private let gate = MemoGate()

    /// The provider the transcript gets.
    var provider: LiveMeetingTranscript.MemoProvider {
        { [self] previous, lines, _ in
            let index = record(previous, lines)
            if index == 0 { await gate.wait() }
            return "the summary \(index + 1)"
        }
    }

    /// The folds that ran, in order.
    var folds: [Fold] {
        lock.withLock { stored }
    }

    /// Lets the first fold go.
    func openTheFirstFold() {
        gate.open()
    }

    private func record(_ previous: String?, _ lines: [LiveMeetingTranscript.Line]) -> Int {
        lock.withLock {
            stored.append(Fold(previous: previous, lines: lines))
            return stored.count - 1
        }
    }
}

/// A gate the test opens: the memo fold waits for it.
///
/// The gate does not notice a cancellation — a fold that was cancelled still
/// comes back with its text, and the transcript has to drop it.
final class MemoGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until the gate is open.
    func wait() async {
        if lock.withLock({ isOpen }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isAlreadyOpen: Bool = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if isAlreadyOpen { continuation.resume() }
        }
    }

    /// Opens the gate and lets everything through.
    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let waiting = self.waiters
            self.waiters = []
            return waiting
        }
        for waiter in waiting { waiter.resume() }
    }
}
