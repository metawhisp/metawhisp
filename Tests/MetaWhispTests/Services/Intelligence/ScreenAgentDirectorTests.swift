import XCTest
@testable import MetaWhisp

/// The single decision about whether to say anything.
///
/// Four loops used to decide this independently, each with its own idea of what
/// counts as a fact and its own way of interrupting. Nothing could answer "why
/// did MetaWhisp speak just then", because nothing made that decision once.
///
/// Most of these cases end in silence. That is the point: most screens are
/// someone reading, and a comment about an ordinary screen is worse than none —
/// it teaches the user to stop looking.
final class ScreenAgentDirectorTests: XCTestCase {

    private let contextID = UUID()

    private func evidence() -> ScreenAgentEvidence {
        ScreenAgentEvidence([
            .init(id: "e1", contextID: contextID,
                  text: "Anna: please send the final deck today by 16:00"),
        ])
    }

    private func candidate(
        headline: String = "Anna is waiting for the deck by 16:00",
        body: String = "You said you would send it",
        cited: [String] = ["e1"],
        quote: String? = "by 16:00",
        confidence: Double = 0.9,
        namesReferent: Bool = true
    ) -> ScreenAgentDirector.Candidate {
        .init(headline: headline, body: body, citedEvidenceIDs: cited,
              quote: quote, confidence: confidence, namesReferent: namesReferent)
    }

    private func decide(
        _ candidates: [ScreenAgentDirector.Candidate],
        screenText: String = "Slack #launch",
        recent: [String] = []
    ) -> ScreenAgentDirector.Decision {
        ScreenAgentDirector.decide(candidates: candidates, evidence: evidence(),
                                   screenText: screenText, recentHeadlines: recent)
    }

    // MARK: the common case

    /// An ordinary screen produces nothing, and that is a success.
    func testNothingProposedIsSilence() {
        XCTAssertEqual(decide([]), .silence(.nothingToSay))
    }

    func testAGroundedSpecificClaimBecomesAnItem() {
        guard case .item(let headline, _, let ids) = decide([candidate()]) else {
            return XCTFail("a grounded, specific, confident claim should be shown")
        }
        XCTAssertEqual(headline, "Anna is waiting for the deck by 16:00")
        XCTAssertEqual(ids, ["e1"])
    }

    // MARK: reasons to stay quiet

    /// The claim cited something it was never given. Confidence does not repair
    /// that — a model being sure is not evidence.
    func testAnUngroundedClaimIsSilenced() {
        XCTAssertEqual(decide([candidate(cited: ["e9"], quote: nil, confidence: 0.99)]),
                       .silence(.ungrounded))
    }

    /// A quote that is not in the source it points at is an invention.
    func testAnInventedQuoteIsSilenced() {
        XCTAssertEqual(decide([candidate(quote: "Anna approved the budget")]),
                       .silence(.ungrounded))
    }

    /// Reading the screen back to the user is the single most common way an
    /// assistant becomes noise.
    func testAClaimThatOnlyRepeatsTheScreenIsSilenced() {
        let onScreen = "Anna: please send the final deck today by 16:00"
        XCTAssertEqual(
            decide([candidate(headline: "please send the final deck today")],
                   screenText: onScreen),
            .silence(.echoesTheScreen))
    }

    /// A comment naming nothing cannot be acted on.
    func testAVagueClaimIsSilenced() {
        XCTAssertEqual(decide([candidate(namesReferent: false)]), .silence(.tooVague))
    }

    func testAnUnconfidentClaimIsSilenced() {
        XCTAssertEqual(decide([candidate(confidence: 0.4)]), .silence(.lowConfidence))
    }

    /// Rewording does not make it new.
    func testTheSameIdeaInDifferentWordsIsSilenced() {
        XCTAssertEqual(
            decide([candidate(headline: "Anna is waiting for the deck by 16:00")],
                   recent: ["The deck is due to Anna at 16:00"]),
            .silence(.duplicate))
    }

    /// Two producers proposing equally strong and different things means they
    /// disagree. Picking by array order is how the wrong one gets shown.
    func testTwoEquallyStrongProposalsAreRefusedRatherThanGuessed() {
        let a = candidate(headline: "Anna is waiting for the deck by 16:00", confidence: 0.90)
        let b = candidate(headline: "The roadmap review is unscheduled", confidence: 0.92)
        XCTAssertEqual(decide([a, b]), .silence(.ambiguous))
    }

    /// A clear winner is still chosen — the tie rule must not silence
    /// everything.
    func testAClearWinnerAmongProposalsIsStillShown() {
        let weak = candidate(headline: "Something might need attention", confidence: 0.72)
        let strong = candidate(headline: "Anna is waiting for the deck by 16:00", confidence: 0.95)
        guard case .item(let headline, _, _) = decide([weak, strong]) else {
            return XCTFail("a clear winner should be shown")
        }
        XCTAssertEqual(headline, "Anna is waiting for the deck by 16:00")
    }

    // MARK: the ordering that matters

    /// Grounding is checked before novelty and before echo. A fabricated claim
    /// must be reported as fabricated, not as a duplicate — the reason codes
    /// are how anyone will diagnose this later.
    func testGroundingIsJudgedBeforeTasteIs() {
        XCTAssertEqual(
            decide([candidate(cited: ["e9"], quote: nil)],
                   recent: ["Anna is waiting for the deck by 16:00"]),
            .silence(.ungrounded))
    }

    /// Every silence has a name. A silent agent nobody can explain is
    /// indistinguishable from a broken one.
    func testEverySilenceReasonIsNameable() {
        for reason in ScreenAgentDirector.Reason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
        }
        XCTAssertEqual(ScreenAgentDirector.Reason.allCases.count, 7)
    }

    // MARK: helpers

    func testNearDuplicateIgnoresFillerWords() {
        XCTAssertTrue(ScreenAgentDirector.isNearDuplicate(
            "Anna needs the deck by 16:00", "The deck is due to Anna at 16:00"))
        XCTAssertFalse(ScreenAgentDirector.isNearDuplicate(
            "Anna needs the deck", "The build is failing on main"))
    }

    /// A short headline can coincidentally appear in a page of text; only a
    /// substantial repeat counts as an echo.
    func testAShortHeadlineIsNotTreatedAsAnEcho() {
        XCTAssertFalse(ScreenAgentDirector.echoes("send it", of: "please send it now"))
    }
}
