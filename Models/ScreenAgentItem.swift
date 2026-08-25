import Foundation
import SwiftData

/// One thing the Screen Agent had to say, as a durable object.
///
/// Until now a comment was an `MWNotification`: a title, a body and a closure,
/// alive for six seconds. Nothing recorded that it existed, so a useful remark
/// seen out of the corner of an eye was gone — not archived, not findable,
/// simply over. The same six seconds also had to serve as the only chance to
/// react to it.
///
/// Making it a row is what turns a banner into something the product can point
/// at later: opened from an Inbox after the fact, explained, continued in a
/// conversation, or corrected.
@Model
final class ScreenAgentItem {
    /// Stable identity. The run that produced this item is recorded too, so a
    /// retried or duplicated run cannot create a second copy.
    @Attribute(.unique) var id: UUID
    var runID: UUID

    var createdAt: Date

    /// What the user reads.
    var headline: String
    var body: String

    /// Where it came from. Kept from the capture envelope rather than from
    /// anything the model said about itself.
    var sourceApp: String
    var sourceWindowTitle: String
    /// When the screen it refers to was captured — not when the model answered.
    var capturedAt: Date
    /// The visit and generation this belongs to, so an item can still be tied
    /// back to the exact stretch of screen time that produced it.
    var visitID: UUID?
    var visitGeneration: Int

    /// The screen rows this claim was drawn from. Answers "why am I seeing
    /// this?" without keeping a copy of the screen.
    var evidenceContextIDsJSON: String

    /// Terminal delivery outcome: whether the user actually had a chance to see
    /// it. Generated and presented are different facts, and counting the first
    /// as the second is how a feature convinces itself it is working.
    var deliveryOutcome: String
    var deliveredAt: Date?
    /// Why it was not presented, when it was not. Reason codes only.
    var suppressionReason: String?

    /// What the user did with it afterwards, separately from whether it was
    /// shown at all.
    var interaction: String
    var interactedAt: Date?

    /// ITER-070 — what the user said was wrong with it, when they said so.
    ///
    /// Kept apart from `interaction` on purpose. Closing a popup because you
    /// are busy is not criticism, and a product that reads it as criticism
    /// learns the wrong lesson from its most common event.
    var feedbackReason: String?
    var feedbackAt: Date?

    /// Content words of the headline, for suppressing the same idea in
    /// different words. Computed once at creation so a later comparison does
    /// not have to re-derive it for every candidate.
    var semanticSignature: String = ""

    init(
        runID: UUID,
        headline: String,
        body: String,
        sourceApp: String,
        sourceWindowTitle: String,
        capturedAt: Date,
        visitID: UUID? = nil,
        visitGeneration: Int = 0,
        evidenceContextIDs: [UUID] = []
    ) {
        self.id = UUID()
        self.runID = runID
        self.createdAt = Date()
        self.headline = headline
        self.body = body
        self.sourceApp = sourceApp
        self.sourceWindowTitle = sourceWindowTitle
        self.capturedAt = capturedAt
        self.visitID = visitID
        self.visitGeneration = visitGeneration
        self.evidenceContextIDsJSON =
            (try? String(data: JSONEncoder().encode(evidenceContextIDs), encoding: .utf8) ?? "[]") ?? "[]"
        self.deliveryOutcome = ScreenAgentDelivery.Outcome.pending.rawValue
        self.interaction = ScreenAgentDelivery.Interaction.none.rawValue
        self.semanticSignature = ScreenAgentDirector.semanticSignature(of: headline)
    }

    var evidenceContextIDs: [UUID] {
        guard let data = evidenceContextIDsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }
}

/// The lifecycle vocabulary. Kept as strings in the store so a future value
/// cannot make an existing row unreadable.
enum ScreenAgentDelivery {

    /// What the user says is wrong with a comment.
    ///
    /// Each one means something different about what to change, which is the
    /// whole reason for asking. A single thumbs-down would say "worse" without
    /// saying "worse how", and the fix for a wrong claim is nothing like the
    /// fix for a correct one that arrived at a bad moment.
    enum Feedback: String, CaseIterable {
        /// The claim is not true. The most serious one: it means grounding let
        /// something through.
        case wrong
        /// True, but the user already knew. Nothing was added.
        case obvious
        /// Was true about a screen the user had already left.
        case outdated
        /// Already said, already handled.
        case repeated
        /// Fine in itself, wrong moment or too often. Says nothing about
        /// whether the content was correct.
        case tooIntrusive

        /// What the user reads when choosing.
        var label: String {
            switch self {
            case .wrong: return "Not true"
            case .obvious: return "I knew that"
            case .outdated: return "Too late"
            case .repeated: return "Already said this"
            case .tooIntrusive: return "Bad moment"
            }
        }
    }

    /// What happened to the attempt to show this.
    enum Outcome: String, CaseIterable {
        /// Created, not yet decided.
        case pending
        /// The user had a chance to see it.
        case presented
        /// Policy said no at the final check — paused, in a meeting, too soon
        /// after the last one, no room on screen.
        case suppressed
        /// Something broke on the way to the screen.
        case failed
    }

    /// What the user did after it was presented. Deliberately separate from
    /// `Outcome`: a popup timing out is not a judgement, and treating silence
    /// as rejection would teach the product the wrong lesson.
    enum Interaction: String, CaseIterable {
        case none
        case opened
        case dismissed
        case timedOut
        /// Pushed off the stack by newer cards. It was shown; it may not have
        /// been read.
        case replaced
        case later
    }

    /// Why an item was not presented. Reason codes only — never screen content.
    enum SuppressionReason: String, CaseIterable {
        case paused
        case meetingInProgress
        case pacing
        case staleVisit
        case stackFull
        case featureOff
        case persistenceFailed
    }
}
