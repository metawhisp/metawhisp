import XCTest
@testable import MetaWhisp

/// The user message and its budgets (T6).
///
/// The message is built in the order the design names — the memo, the
/// memories, the transcript, the earlier exchanges, the ask — and it is
/// brought inside the budget by dropping the oldest things first. The ask is
/// the one part that never goes.
final class MeetingAnswerBudgetTests: XCTestCase {

    // MARK: - The helpers

    /// A transcript of `count` lines, each `size` characters long.
    private func lines(count: Int, size: Int, newest: String) -> [String] {
        var lines: [String] = []
        for index in 0..<count {
            lines.append("Them: " + String(repeating: "a", count: size))
        }
        lines[lines.count - 1] = newest
        return lines
    }

    /// A message with everything in it.
    private func message(transcript: [String],
                         answeredIndex: Int? = nil,
                         memo: String? = nil,
                         memories: String? = nil,
                         history: [MeetingAnswerPrompts.Exchange] = [],
                         ask: String = "Heard in the meeting: \"a question\"\n\nThe user wants an answer to this: answer it directly.",
                         budget: MeetingAnswerPrompts.Budget = .cloud) -> String {
        MeetingAnswerPrompts.userMessage(memo: memo,
                                         memories: memories,
                                         transcriptLines: transcript,
                                         answeredIndex: answeredIndex,
                                         history: history,
                                         ask: ask,
                                         budget: budget)
    }

    // MARK: - The budgets

    /// A long transcript still leaves the ask and the newest line inside the
    /// budget — for the cloud routes and for the local one.
    func testALongTranscriptStillLeavesTheAskAndTheNewestLineInsideTheBudget() {
        let newest = "Them: the newest line of the meeting"
        let transcript = lines(count: 250, size: 200, newest: newest)

        let cloud = message(transcript: transcript)
        XCTAssertLessThanOrEqual(cloud.count, MeetingAnswerPrompts.Budget.cloud.totalCharacters)
        XCTAssertTrue(cloud.contains(newest), "the newest line did not survive the cloud budget")
        XCTAssertTrue(cloud.contains("Heard in the meeting:"), "the ask did not survive the cloud budget")

        let local = message(transcript: transcript, budget: .local)
        XCTAssertLessThanOrEqual(local.count, MeetingAnswerPrompts.Budget.local.totalCharacters)
        XCTAssertTrue(local.contains(newest), "the newest line did not survive the local budget")
        XCTAssertTrue(local.contains("Heard in the meeting:"), "the ask did not survive the local budget")
    }

    /// The ask is never cut, even when the transcript does not fit at all.
    func testTheAskIsNeverCutEvenWhenTheTranscriptDoesNotFit() {
        // One line of fifty thousand characters: no whole line can be dropped
        // to make room, so the transcript itself has to give way — and the ask
        // must stay whole.
        let huge = "Them: " + String(repeating: "x", count: 49_994)
        let ask = "Heard in the meeting: \"a question\"\n\nThe user wants an answer to this: answer it directly."

        let cloud = message(transcript: [huge], ask: ask)
        XCTAssertLessThanOrEqual(cloud.count, MeetingAnswerPrompts.Budget.cloud.totalCharacters)
        XCTAssertTrue(cloud.hasSuffix(ask), "the ask was cut by the budget")
        XCTAssertTrue(cloud.contains(String(repeating: "x", count: 100)), "the newest words of the line did not survive")

        let local = message(transcript: [huge], ask: ask, budget: .local)
        XCTAssertLessThanOrEqual(local.count, MeetingAnswerPrompts.Budget.local.totalCharacters)
        XCTAssertTrue(local.hasSuffix(ask), "the ask was cut by the local budget")
    }

    /// The memo and the earlier exchanges go before the transcript does.
    func testTheMemoAndTheEarlierExchangesAreDroppedFirst() {
        let memo = "memo-" + String(repeating: "m", count: 5_000)
        let memories = "memories-" + String(repeating: "n", count: 5_000)
        let history = (0..<6).map { index in
            MeetingAnswerPrompts.Exchange(heard: "heard \(index)",
                                          answer: "answer-" + String(repeating: "h", count: 2_000))
        }
        let transcript = lines(count: 40, size: 100, newest: "Them: the newest line")

        let built = message(transcript: transcript,
                            memo: memo,
                            memories: memories,
                            history: history)

        XCTAssertFalse(built.contains("memo-m"), "the memo was kept although it does not fit")
        XCTAssertFalse(built.contains("memories-n"), "the memories were kept although they do not fit")
        XCTAssertFalse(built.contains("answer-h"), "the earlier answers were kept although they do not fit")
        XCTAssertTrue(built.contains("the newest line"), "the transcript was dropped although the memo could go")
        XCTAssertTrue(built.contains("Heard in the meeting:"), "the ask was dropped")
    }

    /// The whole message stays inside the budget, whatever is put into it.
    func testTheWholeMessageStaysInsideTheBudget() {
        let memo = String(repeating: "m", count: 20_000)
        let memories = String(repeating: "n", count: 20_000)
        let history = (0..<6).map { _ in
            MeetingAnswerPrompts.Exchange(heard: String(repeating: "h", count: 2_000),
                                          answer: String(repeating: "a", count: 2_000))
        }
        let transcript = lines(count: 300, size: 200, newest: "Them: the newest line")

        let cloud = message(transcript: transcript, memo: memo, memories: memories, history: history)
        XCTAssertLessThanOrEqual(cloud.count, MeetingAnswerPrompts.Budget.cloud.totalCharacters)

        let local = message(transcript: transcript, memo: memo, memories: memories, history: history, budget: .local)
        XCTAssertLessThanOrEqual(local.count, MeetingAnswerPrompts.Budget.local.totalCharacters)
    }

    /// The transcript's own window holds on its own: one very long line is
    /// cut from its oldest end, and its newest words stay.
    func testTheTranscriptWindowHoldsOnItsOwnWithOneVeryLongLine() {
        let long = "Them: " + String(repeating: "x", count: 4_990) + " the newest words"
        let built = message(transcript: [long])

        guard let window = built.range(of: MeetingAnswerPrompts.transcriptWrapper) else {
            return XCTFail("the message holds no transcript")
        }
        let after = String(built[window.upperBound...])
        let transcriptPart = after.components(separatedBy: "\n\n").first ?? ""
        XCTAssertLessThanOrEqual(transcriptPart.count,
                                 MeetingAnswerPrompts.Budget.cloud.transcriptCharacters,
                                 "the transcript was over its own window")
        XCTAssertTrue(transcriptPart.hasSuffix("the newest words"),
                      "the newest words of the long line did not survive")
    }

    // MARK: - The order

    /// The parts stand in the order the design names.
    func testThePartsStandInTheOrderTheDesignNames() {
        let built = message(transcript: ["Them: the line"],
                            memo: "the memo",
                            memories: "the memories",
                            history: [MeetingAnswerPrompts.Exchange(heard: "the heard line", answer: "the answer")],
                            ask: "the ask")

        let order = ["the memo", "the memories", "the line", "the heard line", "the ask"]
        var last = built.startIndex
        for part in order {
            guard let range = built.range(of: part, range: last..<built.endIndex) else {
                XCTFail("the part '\(part)' is missing or out of order")
                return
            }
            last = range.upperBound
        }
    }

    /// The divider stands before the line that came after the last answer.
    func testTheDividerStandsBeforeTheLineThatCameAfterTheLastAnswer() {
        let built = message(transcript: ["Them: the old line", "Them: the new line"],
                            answeredIndex: 1)

        XCTAssertTrue(built.contains("Them: the old line\n\(LiveMeetingTranscript.newSinceLastAnswerDivider)\nThem: the new line"),
                      "the divider did not stand before the line after the last answer")
    }

    /// The earlier exchanges carry their labels.
    func testTheEarlierExchangesCarryTheirLabels() {
        let built = message(transcript: ["Them: the line"],
                            history: [MeetingAnswerPrompts.Exchange(heard: "what was heard", answer: "what was said")])

        XCTAssertTrue(built.contains("[Heard in the meeting] what was heard"))
        XCTAssertTrue(built.contains("[Answered] what was said"))
    }

    /// The transcript's own window is what the budget asks for.
    func testTheTranscriptStaysInsideItsOwnWindow() {
        let transcript = lines(count: 100, size: 200, newest: "Them: the newest line")
        let built = message(transcript: transcript)

        let window = try? XCTUnwrap(built.range(of: MeetingAnswerPrompts.transcriptWrapper))
        XCTAssertNotNil(window)
        let after = String(built[built.range(of: MeetingAnswerPrompts.transcriptWrapper)!.upperBound...])
        let transcriptPart = after.components(separatedBy: "\n\n").first ?? ""
        XCTAssertLessThanOrEqual(transcriptPart.count, MeetingAnswerPrompts.Budget.cloud.transcriptCharacters)
    }
}
