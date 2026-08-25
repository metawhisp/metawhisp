import Foundation
import SwiftData

/// One Screen Agent run, as a row: when it started, what triggered it, how it
/// ended and why — including the silences.
///
/// Until now "why did MetaWhisp speak just then" had an answer (the director
/// decides once) but "why did it speak at 15:04 and not at 15:02" had none:
/// a run that ended in silence left no trace at all, and a run that produced
/// an item recorded the item, not the run. The journal is the difference
/// between a policy that can be audited and one that has to be believed.
///
/// Plan §4: no raw OCR and no image data ever lands here — reason codes,
/// enums, IDs and timings only.
@Model
final class ScreenAgentRun {
    @Attribute(.unique) var id: UUID
    /// The captured context this run analyzed. The run's identity for
    /// idempotency is the context's own ID (one analysis per capture).
    var contextID: UUID
    /// What woke the run: appActivation, poll, retry.
    var trigger: String

    var startedAt: Date
    var deadlineAt: Date
    var completedAt: Date?

    /// Where the decision came from, so a prompt or model change can be
    /// correlated with a behavior change after the fact.
    var promptVersion: String
    var modelRoute: String

    /// running → completed | expired | cancelled.
    var status: String
    /// The director's reason code when the outcome was silence; "item" when
    /// something was shown. Never prose.
    var outcomeReason: String?
    /// The evidence refs the decision actually cited (allowlist IDs, not
    /// content) — what "grounded" pointed at, preserved past the run.
    var evidenceRefsJSON: String

    init(
        contextID: UUID,
        trigger: String,
        startedAt: Date = Date(),
        deadlineAt: Date,
        promptVersion: String = "",
        modelRoute: String = ""
    ) {
        self.id = UUID()
        self.contextID = contextID
        self.trigger = trigger
        self.startedAt = startedAt
        self.deadlineAt = deadlineAt
        self.promptVersion = promptVersion
        self.modelRoute = modelRoute
        self.status = "running"
        self.outcomeReason = nil
        self.evidenceRefsJSON = "[]"
    }

    var evidenceRefs: [String] {
        guard let data = evidenceRefsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func setEvidenceRefs(_ refs: [String]) {
        evidenceRefsJSON =
            (try? String(data: JSONEncoder().encode(refs), encoding: .utf8) ?? "[]") ?? "[]"
    }
}

/// One delivery attempt of one item, as a row.
///
/// `ScreenAgentItem` keeps its lifecycle fields — they are what the Inbox
/// reads — but an item is the THING while a delivery is an EVENT, and folding
/// events into the thing meant a re-presented item overwrote the history of
/// its first presentation. The record is named `…Record` because the
/// lifecycle vocabulary already owns the plain name.
@Model
final class ScreenAgentDeliveryRecord {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var runID: UUID

    var queuedAt: Date
    var presentedAt: Date?
    var terminalAt: Date?

    /// pending → presented | suppressed, mirroring the vocabulary the
    /// delivery authority already speaks.
    var deliveryOutcome: String
    /// Reason code when suppressed. Never prose.
    var outcomeReason: String?

    /// What the user did with this presentation, when they did it.
    var interactionOutcome: String?
    var interactionAt: Date?

    init(itemID: UUID, runID: UUID, queuedAt: Date = Date()) {
        self.id = UUID()
        self.itemID = itemID
        self.runID = runID
        self.queuedAt = queuedAt
        self.deliveryOutcome = "pending"
    }
}
