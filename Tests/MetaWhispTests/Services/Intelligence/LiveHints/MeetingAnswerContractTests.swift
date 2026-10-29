import XCTest
@testable import MetaWhisp

/// The output contract (T7).
///
/// The reply of the model is read in six steps: the reasoning block goes, the
/// code fence goes, the skip probe runs on a copy, the shape is checked, the
/// answer is parsed, and every piece is rendered. The answer itself is never
/// stripped — a canonical bold headline keeps its bold run.
final class MeetingAnswerContractTests: XCTestCase {

    // MARK: - The helpers

    /// The outcome of a reply.
    private func outcome(_ reply: String) -> MeetingAnswerContract.Outcome {
        MeetingAnswerContract.evaluate(reply)
    }

    /// The answer of a reply, when there is one.
    private func answer(_ reply: String) -> MeetingAnswerText? {
        if case .answer(let text) = outcome(reply) { return text }
        return nil
    }

    // MARK: - The skips

    /// The marker alone means there is nothing to answer.
    func testTheMarkerAloneIsASkip() {
        XCTAssertEqual(outcome("[no-answer]"), .skip)
    }

    /// The marker behind a bold run is a skip as well.
    func testTheMarkerBehindABoldRunIsASkip() {
        XCTAssertEqual(outcome("**[no-answer]**"), .skip)
    }

    /// A reasoning block before the marker does not hide it.
    func testAReasoningBlockBeforeTheMarkerDoesNotHideIt() {
        XCTAssertEqual(outcome("<think>the other side asked something</think>\n[no-answer]"), .skip)
    }

    /// A reasoning block that is never closed drops everything after it: the
    /// answer cannot be trusted when the model never came back from its own
    /// thoughts.
    func testAReasoningBlockThatIsNeverClosedDropsTheRest() {
        XCTAssertEqual(outcome("<think>the other side asked something\n[no-answer]"), .reject)
        XCTAssertEqual(outcome("<think>**Private reasoning must not be an answer.**"), .reject)
    }

    /// The text before an unclosed reasoning block stays — and the text after
    /// it goes.
    func testAnUnclosedReasoningBlockKeepsWhatCameBeforeIt() {
        let reply = "**We should ship on Friday.**\n<think>and then some more thoughts"

        let text = answer(reply)

        XCTAssertEqual(text?.headline, "**We should ship on Friday.**")
    }

    // MARK: - The rejects

    /// A JSON answer is not an answer.
    func testAJsonAnswerIsRejected() {
        XCTAssertEqual(outcome("{\"answer\": \"ship on Friday\"}"), .reject)
    }

    /// A fenced JSON block is unwrapped and then rejected.
    func testAFencedJsonBlockIsRejected() {
        XCTAssertEqual(outcome("```json\n{\"answer\": \"ship on Friday\"}\n```"), .reject)
    }

    /// A reply that is too long is rejected.
    func testAReplyThatIsTooLongIsRejected() {
        let reply = "**" + String(repeating: "a", count: 951) + "**"
        XCTAssertEqual(outcome(reply), .reject)
    }

    /// A first line that is too long is rejected, however short the rest is.
    func testAFirstLineThatIsTooLongIsRejected() {
        let reply = "**" + String(repeating: "a", count: 300) + "**\n- a point"
        XCTAssertEqual(outcome(reply), .reject)
    }

    /// Reasoning returned as plain text has no headline and is rejected.
    func testReasoningReturnedAsPlainTextIsRejected() {
        let reply = "We need a deep insight. They discuss the roadmap and nothing else."
        XCTAssertEqual(outcome(reply), .reject)
    }

    /// A headline without a bold run is not the shape that was asked for.
    func testAHeadlineWithoutABoldRunIsRejected() {
        XCTAssertEqual(outcome("We should ship on Friday.\n- a point"), .reject)
    }

    /// A bold run with fewer than three characters inside is no bold run.
    func testABoldRunWithFewerThanThreeCharactersIsRejected() {
        XCTAssertEqual(outcome("**ab**"), .reject)
    }

    // MARK: - The answers

    /// The canonical answer is an answer, and its headline keeps the bold run.
    func testTheCanonicalAnswerIsAnAnswerAndKeepsItsBoldRun() {
        let text = answer("**We should ship on Friday.**")
        XCTAssertEqual(text?.headline, "**We should ship on Friday.**")
        XCTAssertEqual(text?.bullets, [])
    }

    /// A headline with no points is still an answer.
    func testAHeadlineWithNoPointsIsStillAnAnswer() {
        XCTAssertNotNil(answer("**We should ship on Friday.**"))
    }

    /// The same answer with three points keeps them.
    func testTheSameAnswerWithThreePointsKeepsThem() {
        let reply = """
        **We should ship on Friday.**

        - The freeze starts on Monday
        - The tests are green
        - The docs are written
        """
        let text = answer(reply)
        XCTAssertEqual(text?.bullets.count, 3)
        XCTAssertEqual(text?.bullets.first, "The freeze starts on Monday")
    }

    /// The points may be marked in four ways.
    func testThePointsMayBeMarkedInFourWays() {
        let reply = """
        **We should ship on Friday.**

        - a dash
        • a bullet
        * a star
        – an en dash
        """
        let text = answer(reply)
        XCTAssertEqual(text?.bullets, ["a dash", "a bullet", "a star", "an en dash"])
    }

    /// At most four points are kept.
    func testAtMostFourPointsAreKept() {
        let reply = """
        **We should ship on Friday.**

        - one
        - two
        - three
        - four
        - five
        """
        let text = answer(reply)
        XCTAssertEqual(text?.bullets.count, 4)
    }

    /// A line that is not a point ends the parse.
    func testALineThatIsNotAPointEndsTheParse() {
        let reply = """
        **We should ship on Friday.**

        - one
        and then some prose
        - two
        """
        let text = answer(reply)
        XCTAssertEqual(text?.bullets, ["one"])
    }

    /// A point that is too long is not a point.
    func testAPointThatIsTooLongIsNotAPoint() {
        let reply = "**We should ship on Friday.**\n- " + String(repeating: "a", count: 121)
        let text = answer(reply)
        XCTAssertEqual(text?.bullets, [])
    }

    /// A bold run inside the headline is kept.
    func testABoldRunInsideTheHeadlineIsKept() {
        let text = answer("**We should ship on Friday.**")
        XCTAssertEqual(text?.headline, "**We should ship on Friday.**")
    }

    /// The reply is never stripped: the answer keeps its markup.
    func testTheReplyIsNeverStripped() {
        let reply = "**We should ship on Friday.**\n- The freeze starts on Monday"
        let text = answer(reply)
        XCTAssertEqual(text?.headline, "**We should ship on Friday.**")
        XCTAssertEqual(text?.bullets, ["The freeze starts on Monday"])
    }

    // MARK: - The rendering

    /// Every piece is rendered as attributed text, and a piece that cannot be
    /// rendered falls back to its plain text.
    func testEveryPieceIsRenderedAsAttributedText() {
        let text = answer("**We should ship on Friday.**\n- The freeze starts on Monday")
        XCTAssertNotNil(text)

        let headline = MeetingAnswerContract.rendered(text!.headline)
        XCTAssertFalse(headline.characters.isEmpty)

        let bullet = MeetingAnswerContract.rendered(text!.bullets[0])
        XCTAssertFalse(bullet.characters.isEmpty)

        // A piece that markdown cannot read keeps its plain text.
        let broken = MeetingAnswerContract.rendered("**unclosed bold")
        XCTAssertFalse(broken.characters.isEmpty)
    }

    // MARK: - The ask

    /// A joined line that is too long is quoted by its newest characters.
    func testAnOversizedJoinedAskIsCutToItsNewestCharacters() {
        let oldest = String(repeating: "o", count: 1_000)
        let newest = String(repeating: "n", count: 1_000)
        let line = oldest + newest

        let ask = MeetingAnswerPrompts.forcedAsk(line: line)

        XCTAssertTrue(ask.contains(newest), "the newest characters of the line did not survive")
        XCTAssertFalse(ask.contains(oldest), "the oldest characters of the line were quoted")
        XCTAssertTrue(ask.contains("The user wants an answer to this:"), "the ask did not survive")
    }

    /// The gated ask asks the same question and quotes the line the same way.
    func testTheGatedAskAsksTheModelToDecline() {
        let ask = MeetingAnswerPrompts.gatedAsk(line: "shall we ship on Friday?")

        XCTAssertTrue(ask.hasPrefix("Heard in the meeting: \"shall we ship on Friday?\""))
        XCTAssertTrue(ask.contains("reply with exactly [no-answer] and nothing else"))
        XCTAssertTrue(ask.contains("answer it directly"))
    }

    /// The forced ask asks for the answer itself.
    func testTheForcedAskAsksForTheAnswerItself() {
        let ask = MeetingAnswerPrompts.forcedAsk(line: "shall we ship on Friday?")

        XCTAssertTrue(ask.hasPrefix("Heard in the meeting: \"shall we ship on Friday?\""))
        XCTAssertTrue(ask.contains("The user wants an answer to this:"))
        XCTAssertFalse(ask.contains("[no-answer]"))
    }
}
