import XCTest
@testable import MetaWhisp

/// Pressing "regenerate" on a conversation used to be a bet: the eleven
/// structured fields were set to nil and SAVED before the generator ran, and
/// the generator has five paths that write nothing back — no LLM access, a
/// transcript too short, a run already in flight, a parse failure, a network
/// error. Any of them left the conversation permanently blank: the title, the
/// overview, the decisions, the action items and the quotes it had before were
/// gone, and the only way back was to run it again and hope (audit,
/// 2026-09-06, P1).
///
/// What is kept is a decision, so it is decided here rather than inside a
/// SwiftData context.
final class StructuredRegenerateTests: XCTestCase {

    private func filled() -> StructuredFieldSet {
        StructuredFieldSet(title: "Пятничный созвон", overview: "Обсудили сроки", category: "meeting",
                           emoji: "bubble.left", primaryProject: "ProjectAlpha",
                           topicsJSON: "[\"сроки\"]", decisionsJSON: "[\"перенести релиз\"]",
                           actionItemsJSON: "[\"написать письмо\"]", participantsJSON: "[\"Sam\"]",
                           keyQuotesJSON: "[\"это блокер\"]", nextStepsJSON: "[\"созвон в среду\"]")
    }

    /// Nothing is cleared up front any more: the old values stand until there
    /// is something to put in their place.
    func testRegenerateKeepsWhatItHasUntilItHasSomethingBetter() {
        let before = filled()
        XCTAssertEqual(StructuredFieldSet.afterFailedRegeneration(previous: before), before,
                       "a regeneration that produced nothing must leave the conversation as it was")
    }

    /// A regeneration that produced a result replaces every field, including
    /// the ones the new result left empty — that is what "regenerate" means.
    func testASuccessfulRegenerationReplacesEverything() {
        let fresh = StructuredFieldSet(title: "Новый заголовок", overview: "Новый обзор", category: "call",
                                       emoji: "phone", primaryProject: nil, topicsJSON: nil,
                                       decisionsJSON: nil, actionItemsJSON: nil, participantsJSON: nil,
                                       keyQuotesJSON: nil, nextStepsJSON: nil)
        XCTAssertEqual(StructuredFieldSet.afterSuccessfulRegeneration(fresh: fresh), fresh)
    }

    /// The generator takes the full LLM path when the title is missing. A
    /// regeneration must therefore ASK for that path explicitly instead of
    /// faking it by deleting the title first.
    func testRegenerationAsksForTheFullPathWithoutBlankingAnything() {
        XCTAssertTrue(StructuredFieldSet.forcesFullRegeneration(isRegeneration: true, hasTitle: true),
                      "an existing title must not stop a regeneration the user asked for")
        XCTAssertTrue(StructuredFieldSet.forcesFullRegeneration(isRegeneration: false, hasTitle: false),
                      "a conversation with no title still needs the full path")
        XCTAssertFalse(StructuredFieldSet.forcesFullRegeneration(isRegeneration: false, hasTitle: true),
                       "an ordinary pass over an already-structured conversation stays cheap")
    }
}
