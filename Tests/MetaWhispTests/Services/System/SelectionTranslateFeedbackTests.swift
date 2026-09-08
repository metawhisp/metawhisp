import XCTest
@testable import MetaWhisp

/// A selection-translate that fails used to say nothing at all. The failure
/// path called `soundService.playError()` — an empty method body — hid the
/// overlay and returned; `SelectionTranslator` has no banner and posts no
/// card, so a network error, an expired licence or a refused prompt looked
/// exactly like "nothing happened" (audit, 2026-09-06, P1).
///
/// What the user is told is a decision, so it is a function with tests rather
/// than a string built at the call site.
final class SelectionTranslateFeedbackTests: XCTestCase {

    func testAFailureSaysWhatWentWrong() {
        let words = SelectionTranslateFeedback.wording(
            for: NSError(domain: "T", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Structured proxy HTTP 401 — Invalid or expired license"
            ]))
        XCTAssertEqual(words.title, "Translation failed")
        XCTAssertTrue(words.body.contains("Invalid or expired license"),
                      "the reason the app already has must reach the person: \(words.body)")
        XCTAssertTrue(words.body.contains("selection"), "and it says what was being done: \(words.body)")
    }

    /// The selected text is never quoted back — this card is shown on screen
    /// and the words are the user's own.
    func testTheCardNeverQuotesWhatWasSelected() {
        let words = SelectionTranslateFeedback.wording(
            for: NSError(domain: "T", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"]))
        XCTAssertFalse(words.body.contains("\""), "no quoted text in a card about a failure")
    }

    /// A refusal with no message of its own still produces a sentence a person
    /// can act on, not an empty one.
    func testAnErrorWithNothingToSayStillProducesASentence() {
        let words = SelectionTranslateFeedback.wording(
            for: NSError(domain: "T", code: 1, userInfo: [NSLocalizedDescriptionKey: ""]))
        XCTAssertFalse(words.body.isEmpty)
        XCTAssertTrue(words.body.count > 20, "a card that says nothing is the bug being fixed")
    }
}
