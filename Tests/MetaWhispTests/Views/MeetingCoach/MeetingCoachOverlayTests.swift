import XCTest
@testable import MetaWhisp

/// The answers model and the text the overlay draws (T12).
///
/// The model keeps the answers of the meeting: the newest one first, at most
/// three of them, and nothing is taken away while the meeting runs. The
/// overlay draws them — the bold headline and the catch points — and the
/// tests below check the text it draws, not the pixels.
@MainActor
final class MeetingCoachOverlayTests: XCTestCase {

    // MARK: - The model

    /// The answers are kept newest first, and at most three of them.
    func testTheAnswersAreKeptNewestFirstAndAtMostThree() {
        let state = MeetingCoachState()

        for index in 0..<5 {
            state.publish(answer(index))
        }

        XCTAssertEqual(state.answers.count, 3, "the card kept more than three answers")
        XCTAssertEqual(state.answers.map(\.headline),
                       ["**Answer 4.**", "**Answer 3.**", "**Answer 2.**"],
                       "the answers are not in the newest-first order")
    }

    /// Nothing takes an answer away: the card keeps its answers until the
    /// meeting is armed again.
    func testNoAnswerIsTakenAwayOverTime() {
        let clock = FakeClock()
        let state = MeetingCoachState(clock: { clock.now })
        state.publish(answer(0))

        clock.advance(by: 10 * 60)

        XCTAssertEqual(state.answers.count, 1, "an answer was taken away by the clock")
    }

    /// Arming the meeting clears the card.
    func testArmingClearsTheCard() {
        let state = MeetingCoachState()
        state.publish(answer(0))
        state.setStatus(MeetingAnswerStatus.nothingHeard)
        state.setThinking(true)

        state.arm()

        XCTAssertTrue(state.answers.isEmpty, "the answers were not cleared")
        XCTAssertNil(state.status, "the status line was not cleared")
        XCTAssertFalse(state.isThinking, "the thinking flag was not cleared")
    }

    /// The service publishes its answers into the card.
    func testTheServicePublishesItsAnswersIntoTheCard() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.state.answers.count, 1, "the answer did not reach the card")
        XCTAssertEqual(harness.state.answers.first?.headline, "**The answer.**")
        XCTAssertFalse(harness.state.isThinking, "the card still thinks a request runs")
    }

    // MARK: - The status line

    /// The status line shows, and it goes away when it is cleared.
    func testTheStatusLineShowsAndHides() {
        let state = MeetingCoachState()

        state.setStatus(MeetingAnswerStatus.nothingHeard)
        XCTAssertEqual(state.status, MeetingAnswerStatus.nothingHeard, "the status line did not show")

        state.setStatus(nil)
        XCTAssertNil(state.status, "the status line did not go away")
    }

    /// A status line with a lifetime goes away when the lifetime is over.
    func testAStatusLineWithALifetimeGoesAway() {
        let clock = FakeClock()
        let state = MeetingCoachState(clock: { clock.now })

        state.setStatus(MeetingAnswerStatus.couldNotGetAnAnswer, seconds: 5)
        XCTAssertEqual(state.status, MeetingAnswerStatus.couldNotGetAnAnswer)

        clock.advance(by: 6)
        XCTAssertNil(state.status, "the status line outlived its lifetime")
    }

    // MARK: - The text the overlay draws

    /// The bold run of the headline comes out bold.
    func testTheBoldRunOfTheHeadlineComesOutBold() {
        let answer = answer(0, headline: "**We should ship on Friday.**", bullets: [])

        let headline = MeetingAnswerRender.headline(answer)

        let boldRuns = headline.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertFalse(boldRuns.isEmpty, "the bold run of the headline is not bold")
        XCTAssertEqual(String(headline.characters), "We should ship on Friday.",
                       "the markup of the headline stayed in the text")
    }

    /// A catch point keeps its bold run too.
    func testACatchPointKeepsItsBoldRun() {
        let answer = answer(0, headline: "**Ship it.**", bullets: ["**Friday** works"])

        let bullet = MeetingAnswerRender.bullet(answer.bullets[0])

        let boldRuns = bullet.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertFalse(boldRuns.isEmpty, "the bold run of the catch point is not bold")
    }

    /// The catch points keep their order.
    func testTheCatchPointsKeepTheirOrder() {
        let answer = answer(0,
                            headline: "**Ship it.**",
                            bullets: ["First point", "Second point", "Third point"])

        let bullets = answer.bullets.map { MeetingAnswerRender.bullet($0) }

        XCTAssertEqual(bullets.map { String($0.characters) },
                       ["• First point", "• Second point", "• Third point"],
                       "the catch points are not in the order the model gave them")
    }

    func testTheEmptyCardOnlyOffersControlsOnHover() {
        let state = MeetingCoachState()
        state.arm()
        state.shortcutLabel = "⌃↩"
        XCTAssertFalse(state.shouldShowPanel(isExpanded: false))
        XCTAssertTrue(state.shouldShowPanel(isExpanded: true))
        XCTAssertTrue(state.displayedBlocks.isEmpty)
    }

    // MARK: - The helpers

    /// One answer, as the service publishes it.
    private func answer(_ index: Int) -> MeetingAnswer {
        answer(index, headline: "**Answer \(index).**", bullets: [])
    }

    /// One answer with a headline and catch points.
    private func answer(_ index: Int, headline: String, bullets: [String]) -> MeetingAnswer {
        MeetingAnswer(id: UUID(),
                      heard: "shall we ship on Friday?",
                      kind: .answer,
                      provenance: .transcript,
                      action: nil,
                      blocks: [.headline(headline)] + bullets.map { .bullet($0) },
                      createdAt: Date())
    }
}
