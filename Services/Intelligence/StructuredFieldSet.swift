import Foundation

/// The eleven structured fields a conversation carries, and the rules for
/// replacing them.
///
/// `regenerate()` used to clear all eleven and SAVE before calling the
/// generator, on the reasoning that a missing title is what makes the
/// generator take the full LLM path. But the generator has five ways to
/// return without writing anything — no LLM access, a transcript under the
/// floor, a run already in flight, a parse failure, a network error — and each
/// of them left the conversation permanently blank (audit, 2026-09-06, P1).
///
/// The rule is the ordinary one for replacing something: keep what you have
/// until you hold the replacement.
struct StructuredFieldSet: Equatable {
    var title: String?
    var overview: String?
    var category: String?
    var emoji: String?
    var primaryProject: String?
    var topicsJSON: String?
    var decisionsJSON: String?
    var actionItemsJSON: String?
    var participantsJSON: String?
    var keyQuotesJSON: String?
    var nextStepsJSON: String?

    /// A regeneration that produced nothing changes nothing.
    static func afterFailedRegeneration(previous: StructuredFieldSet) -> StructuredFieldSet { previous }

    /// A regeneration that produced a result replaces every field — including
    /// the ones the new result left empty. Half-old, half-new would be a
    /// conversation that never happened.
    static func afterSuccessfulRegeneration(fresh: StructuredFieldSet) -> StructuredFieldSet { fresh }

    /// The generator takes the full path when there is no title yet. A
    /// regeneration asks for that path outright instead of deleting the title
    /// to simulate it.
    static func forcesFullRegeneration(isRegeneration: Bool, hasTitle: Bool) -> Bool {
        isRegeneration || !hasTitle
    }
}
