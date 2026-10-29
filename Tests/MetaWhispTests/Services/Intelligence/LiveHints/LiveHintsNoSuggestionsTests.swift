import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsNoSuggestionsTests: XCTestCase {
    func testAcceptedTranscriptDoesNotScheduleBackgroundQuestionRequests() async throws {
        let harness = LiveHintsSessionTests.Harness()
        await harness.session.start()
        defer { harness.session.stop() }
        XCTAssertTrue(harness.state.autoAnswerOn)

        harness.session.remember(.init(speaker: .me,
            text: "The delivery plan includes implementation, review, and release preparation before the team confirms the next milestone.",
            startSample: 0, endSample: 16_000))
        harness.clock.value = harness.clock.value.addingTimeInterval(3)
        try await Task.sleep(for: .milliseconds(2_200))

        XCTAssertTrue(harness.pro.requests.isEmpty,
                      "Accepted transcript must not start background suggested-question calls")
        XCTAssertEqual(harness.session.transcriptRenderCount, 0)

        harness.state.updateQuestionText("What is the next milestone?")
        harness.state.submitQuestion()
        await harness.waitUntil { !harness.pro.requests.isEmpty }
        XCTAssertEqual(harness.pro.requests.count, 1)
        XCTAssertTrue(harness.pro.requests.first?.user.contains("What is the next milestone?") == true)
    }
}
