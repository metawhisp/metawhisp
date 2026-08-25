import XCTest
@testable import MetaWhisp

/// Whether a comment's claim actually rests on anything.
///
/// The old gate set two booleans — some search happened, some record was read —
/// and neither was tied to what the comment ended up saying. A model could look
/// one thing up, read another, and assert a third, and the gate would call that
/// grounded. That is the difference between an assistant and a confident
/// stranger.
final class ScreenAgentEvidenceTests: XCTestCase {

    private let slackID = UUID()
    private let docsID = UUID()

    private func evidence() -> ScreenAgentEvidence {
        ScreenAgentEvidence([
            .init(id: "e1", contextID: slackID,
                  text: "Anna: please send the final deck today by 16:00"),
            .init(id: "e2", contextID: docsID,
                  text: "Q3 roadmap — owner: platform team"),
        ])
    }

    func testTheModelIsToldExactlyWhatItMayCite() {
        XCTAssertEqual(evidence().allowlist, ["e1", "e2"])
    }

    /// The failure this exists for: a reference that sounds real and was never
    /// offered. It is not a weaker claim, it is an invented one.
    func testAnInventedReferenceRejectsTheWholeItem() {
        XCTAssertEqual(evidence().validate(citedIDs: ["e7"], quote: nil),
                       .unknownReference("e7"))
    }

    /// One good citation does not launder a bad one.
    func testOneBadReferenceAmongGoodOnesStillRejects() {
        XCTAssertEqual(evidence().validate(citedIDs: ["e1", "e9"], quote: nil),
                       .unknownReference("e9"))
    }

    func testAClaimWithNoCitationAtAllIsRejected() {
        XCTAssertEqual(evidence().validate(citedIDs: [], quote: nil), .noEvidence)
    }

    func testACitationWithoutAQuoteIsAccepted() {
        XCTAssertNil(evidence().validate(citedIDs: ["e1"], quote: nil))
    }

    /// A quote has to be in the thing it points at, not merely plausible.
    func testAQuoteMustAppearInTheSourceItCites() {
        XCTAssertNil(evidence().validate(citedIDs: ["e1"], quote: "send the final deck today"))
        XCTAssertEqual(
            evidence().validate(citedIDs: ["e1"], quote: "Anna approved the budget"),
            .quoteNotInSource,
            "an invented quote of plausible length used to pass a length check")
    }

    /// Quoting the right words but citing the wrong source is still wrong: it
    /// is what "search A, read B, claim from C" looks like from the outside.
    func testAQuoteFromADifferentSourceThanCitedIsRejected() {
        XCTAssertEqual(
            evidence().validate(citedIDs: ["e2"], quote: "send the final deck today"),
            .quoteNotInSource)
    }

    /// OCR spacing is not stable enough to compare literally, and being strict
    /// about it would throw away real quotes.
    func testWhitespaceAndCaseDoNotDefeatARealQuote() {
        XCTAssertNil(evidence().validate(
            citedIDs: ["e1"], quote: "  SEND   the Final\nDeck  today "))
    }

    func testAnEmptyQuoteIsTreatedAsNoQuoteRatherThanAMatch() {
        XCTAssertNil(evidence().validate(citedIDs: ["e1"], quote: "   "))
    }

    /// Whitespace of any shape is the same case as no quote at all.
    func testWhitespaceOnlyQuotesAreAllTheAbsentCase() {
        XCTAssertNil(evidence().validate(citedIDs: ["e1"], quote: "\n\t"))
    }

    /// A one-character "quote" substring-matches almost any screen, so it
    /// evidences nothing while looking like it does.
    func testAQuoteTooShortToMeanAnythingIsRejected() {
        XCTAssertEqual(evidence().validate(citedIDs: ["e1"], quote: "a"), .quoteNotInSource)
        XCTAssertEqual(evidence().validate(citedIDs: ["e1"], quote: "e:"), .quoteNotInSource)
    }

    /// But short and specific still counts — a deadline is worth quoting.
    func testAShortButSpecificQuoteIsAccepted() {
        XCTAssertNil(evidence().validate(citedIDs: ["e1"], quote: "16:00"))
    }
}
