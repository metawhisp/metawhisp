import XCTest
@testable import MetaWhisp

/// Whether a comment names anything, and whether what it names was on screen.
///
/// The prompts do not ask for a verbatim quote, so there is none to verify.
/// What can be verified is narrower and still catches the failure that matters:
/// a comment naming a person, a time or a file that appears nowhere in what was
/// captured. "Anna is waiting for the deck by 16:00" is useful when Anna and
/// 16:00 are on the screen and a fabrication when they are not.
final class InsightReferentTests: XCTestCase {

    func testAClockTimeCounts() {
        XCTAssertTrue(InsightReferent.namesSomethingSpecific("Deck is due by 16:00"))
    }

    func testAFilenameCounts() {
        XCTAssertTrue(InsightReferent.namesSomethingSpecific("Check ScreenContextService.swift"))
    }

    func testANumberCounts() {
        XCTAssertTrue(InsightReferent.namesSomethingSpecific("Budget is over by 40%"))
    }

    func testAPersonCounts() {
        XCTAssertTrue(InsightReferent.namesSomethingSpecific("Reply to Anna about the review"))
    }

    /// The comments that make people stop reading them.
    func testGesturingAtNothingDoesNotCount() {
        XCTAssertFalse(InsightReferent.namesSomethingSpecific("Something may need your attention"))
        XCTAssertFalse(InsightReferent.namesSomethingSpecific("You have unfinished work"))
        XCTAssertFalse(InsightReferent.namesSomethingSpecific("Consider taking a break"))
    }

    /// Times and numbers are preferred: it is much harder to be accidentally
    /// right about 16:00 than about a capitalized word.
    func testTheStrongestAnchorPrefersHardFacts() {
        XCTAssertEqual(InsightReferent.strongestAnchor("Anna wants the deck by 16:00"), "16:00")
    }

    func testTheStrongestAnchorFallsBackToAName() {
        XCTAssertEqual(InsightReferent.strongestAnchor("Reply to Anna soon"), "Anna")
    }

    func testNothingNamedMeansNoAnchor() {
        XCTAssertNil(InsightReferent.strongestAnchor("Something may need your attention"))
    }

    /// The first word of a sentence is capitalized by grammar, not because it
    /// names anyone.
    func testASentenceOpenerIsNotAProperNoun() {
        XCTAssertFalse(InsightReferent.properNouns(in: "Reply to the thread").contains("Reply"))
    }

    /// Together with the evidence check this is the real guard: a comment
    /// naming 16:00 when the screen never said 16:00 does not get shown.
    func testAnAnchorAbsentFromTheScreenFailsValidation() {
        let evidence = ScreenAgentEvidence([
            .init(id: "e1", contextID: UUID(), text: "Anna: send the deck when you can"),
        ])
        let anchor = InsightReferent.strongestAnchor("Anna wants the deck by 16:00")
        XCTAssertEqual(evidence.validate(citedIDs: ["e1"], quote: anchor), .quoteNotInSource)
    }

    func testAnAnchorPresentOnTheScreenPassesValidation() {
        let evidence = ScreenAgentEvidence([
            .init(id: "e1", contextID: UUID(), text: "Anna: send the deck today by 16:00"),
        ])
        let anchor = InsightReferent.strongestAnchor("Anna wants the deck by 16:00")
        XCTAssertNil(evidence.validate(citedIDs: ["e1"], quote: anchor))
    }
}
