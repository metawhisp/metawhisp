import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerFailedQuestionTests: XCTestCase {
    func testFailedTypedQuestionKeepsCardsHistoryAndShowsStatus() async throws {
        let harness = makeAnswerHarness()
        let seed = "**The delivery date is Friday.**"
        let failedQuestion = "Who owns the fallback checklist?"
        let failedReply = "**This failed reply must never enter history.**"
        await appendThemLine(harness.transcript, text: "The delivery date is Friday.", from: 0)
        harness.pro.replies = [
            MeetingAnswerReply(status: 200, retryAfter: nil, text: seed),
            MeetingAnswerReply(status: 429, retryAfter: 17, text: failedReply),
            MeetingAnswerReply(status: 200, retryAfter: nil, text: MeetingAnswerPrompts.skipToken)
        ]
        await harness.service.requestShortcut()?.value
        let existingCards = harness.state.answers
        XCTAssertEqual(existingCards.map(\.headline), [seed])

        await harness.service.requestQuestion(failedQuestion)?.value

        XCTAssertEqual(harness.state.answers, existingCards)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        harness.clock.advance(by: 1.1)
        await harness.service.requestShortcut()?.value

        XCTAssertEqual(harness.requestCount, 3)
        let followingRequest = try XCTUnwrap(harness.pro.requests.last)
        XCTAssertTrue(followingRequest.user.contains("[Answered] " + seed))
        XCTAssertEqual(followingRequest.user.components(separatedBy: "[Answered] ").count - 1, 1)
        XCTAssertFalse(followingRequest.user.contains(failedQuestion))
        XCTAssertFalse(followingRequest.user.contains(failedReply))
        XCTAssertEqual(harness.state.answers, existingCards)
    }
}
