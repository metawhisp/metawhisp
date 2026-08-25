import XCTest
@testable import MetaWhisp

/// What the user says is wrong, and what the product does about it.
///
/// A single thumbs-down would say "worse" without saying "worse how", and the
/// fix for a false claim is nothing like the fix for a true one that arrived at
/// a bad moment. Each reason has to move a different thing or asking was
/// pointless.
final class ScreenAgentFeedbackTests: XCTestCase {

    // MARK: closing is not criticism

    /// The most common thing a user does with a popup is nothing. A product
    /// that reads that as rejection learns the wrong lesson from its most
    /// frequent event.
    func testInteractionAndFeedbackAreSeparateFields() {
        let item = ScreenAgentItem(
            runID: UUID(), headline: "Anna needs the deck by 16:00", body: "",
            sourceApp: "Slack", sourceWindowTitle: "#launch", capturedAt: Date())
        XCTAssertNil(item.feedbackReason, "a fresh item carries no judgement")
        item.interaction = ScreenAgentDelivery.Interaction.timedOut.rawValue
        XCTAssertNil(item.feedbackReason,
                     "timing out is not the user saying anything was wrong")
        item.interaction = ScreenAgentDelivery.Interaction.dismissed.rawValue
        XCTAssertNil(item.feedbackReason,
                     "closing a popup because you are busy is not criticism")
    }

    func testEveryReasonReadsAsSomethingAPersonWouldSay() {
        for reason in ScreenAgentDelivery.Feedback.allCases {
            XCTAssertFalse(reason.label.isEmpty)
            XCTAssertFalse(reason.label.contains("_"), "labels are for humans")
        }
        XCTAssertEqual(ScreenAgentDelivery.Feedback.wrong.label, "Not true")
        XCTAssertEqual(ScreenAgentDelivery.Feedback.tooIntrusive.label, "Bad moment")
    }

    // MARK: the same idea in different words

    func testTheSameIdeaRewordedIsRecognised() {
        let signature = ScreenAgentDirector.semanticSignature(
            of: "Anna is waiting for the deck by 16:00")
        XCTAssertTrue(ScreenAgentDirector.wasRejected(
            "The deck is due to Anna at 16:00", rejectedSignatures: [signature]))
    }

    func testADifferentIdeaIsNotSuppressed() {
        let signature = ScreenAgentDirector.semanticSignature(
            of: "Anna is waiting for the deck by 16:00")
        XCTAssertFalse(ScreenAgentDirector.wasRejected(
            "The build is failing on main", rejectedSignatures: [signature]))
    }

    func testAnEmptyHistorySuppressesNothing() {
        XCTAssertFalse(ScreenAgentDirector.wasRejected("Anything at all",
                                                       rejectedSignatures: []))
    }

    /// A rejected comment coming back in other words is exactly what the user
    /// objected to.
    func testARejectedIdeaIsSilencedByTheDirector() {
        let evidence = ScreenAgentEvidence([
            .init(id: "e1", contextID: UUID(), text: "Anna: send the deck by 16:00"),
        ])
        let candidate = ScreenAgentDirector.Candidate(
            headline: "The deck is due to Anna at 16:00", body: "",
            citedEvidenceIDs: ["e1"], quote: "16:00",
            confidence: 0.95, namesReferent: true)
        let decision = ScreenAgentDirector.decide(
            candidates: [candidate], evidence: evidence,
            screenText: "Slack", recentHeadlines: [],
            rejectedSignatures: [ScreenAgentDirector.semanticSignature(
                of: "Anna is waiting for the deck by 16:00")])
        XCTAssertEqual(decision, .silence(.userRejected))
    }

    // MARK: pacing

    /// One choice a person can make, instead of several unrelated intervals in
    /// different parts of Settings.
    func testEachModeIsQuieterThanTheNext() {
        XCTAssertGreaterThan(ScreenAgentPacing.quiet.minimumSecondsBetween,
                             ScreenAgentPacing.balanced.minimumSecondsBetween)
        XCTAssertGreaterThan(ScreenAgentPacing.balanced.minimumSecondsBetween,
                             ScreenAgentPacing.frequent.minimumSecondsBetween)
    }

    /// A quieter setting has to remember repeats for longer, or the user still
    /// gets the same thought twice in a day they asked to be quiet.
    func testQuieterAlsoMeansALongerMemoryForRepeats() {
        XCTAssertGreaterThan(ScreenAgentPacing.quiet.duplicateWindowSeconds,
                             ScreenAgentPacing.balanced.duplicateWindowSeconds)
        XCTAssertGreaterThan(ScreenAgentPacing.balanced.duplicateWindowSeconds,
                             ScreenAgentPacing.frequent.duplicateWindowSeconds)
    }

    /// "Bad moment" moves timing and nothing else. Treating it as a factual
    /// complaint would silence content the user never said was wrong.
    func testBadMomentMakesItQuieterRatherThanWrong() {
        XCTAssertEqual(ScreenAgentPacing.frequent.quieter, .balanced)
        XCTAssertEqual(ScreenAgentPacing.balanced.quieter, .quiet)
        XCTAssertEqual(ScreenAgentPacing.quiet.quieter, .quiet,
                       "already at the quietest; there is nowhere further to go")
    }

    func testEveryModeExplainsItselfInTime() {
        for mode in ScreenAgentPacing.allCases {
            XCTAssertFalse(mode.explanation.isEmpty)
            XCTAssertFalse(mode.label.isEmpty)
        }
    }
}
