import Foundation
import SwiftData

/// The one thing allowed to put a Screen Agent comment on screen.
///
/// Before this, `ProactiveContextService` pushed straight onto the notification
/// stack with `onTap: nil`. Three consequences, all of them the user's problem:
/// the comment bypassed the meeting quiet-hours and pacing that
/// `NotificationService` owns, clicking it did nothing at all, and nothing
/// anywhere recorded that it had happened — so "we generated an insight" and
/// "the user saw an insight" were the same number.
///
/// Everything now goes: persist the item, re-check policy at the last possible
/// moment, record what was decided, and only then show anything.
@MainActor
final class ScreenAgentDeliveryService {

    /// What the world looks like at the instant before presenting. Passed in
    /// rather than read here so the decision is testable without a running app.
    struct Preflight {
        var featureEnabled: Bool
        var isPaused: Bool
        var meetingInProgress: Bool
        var pauseDuringMeetings: Bool
        var visitIsStillCurrent: Bool
        var secondsSinceLastPresented: TimeInterval?
        var minimumSecondsBetween: TimeInterval
        var popupSlotsFree: Int
        /// Presentations in the trailing 24 hours, against the mode's ceiling.
        var presentedLast24h: Int = 0
        var dailyLimit: Int = .max
    }

    enum Decision: Equatable {
        case present
        case suppress(ScreenAgentDelivery.SuppressionReason)
    }

    /// Pure: the last gate before something interrupts the user.
    ///
    /// Deliberately ordered so the most user-intentional reasons win. Being
    /// told to be quiet outranks anything the agent believes about its own
    /// usefulness.
    nonisolated static func decide(_ p: Preflight) -> Decision {
        guard p.featureEnabled else { return .suppress(.featureOff) }
        guard !p.isPaused else { return .suppress(.paused) }
        if p.meetingInProgress && p.pauseDuringMeetings { return .suppress(.meetingInProgress) }
        // Freshness is checked here, not only when the run started: the whole
        // point is that the user may have moved on while the model was thinking.
        guard p.visitIsStillCurrent else { return .suppress(.staleVisit) }
        if let since = p.secondsSinceLastPresented, since < p.minimumSecondsBetween {
            return .suppress(.pacing)
        }
        // Ported from the reference budget: a cooldown bounds the gap between
        // interruptions, the daily ceiling bounds the day. Without it a busy
        // day at one-per-cooldown is still dozens of interruptions.
        guard p.presentedLast24h < p.dailyLimit else { return .suppress(.dailyBudget) }
        guard p.popupSlotsFree > 0 else { return .suppress(.stackFull) }
        return .present
    }

    private let container: ModelContainer
    private var lastPresentedAt: Date?

    /// Pacing has to outlive the process. Keeping it only in memory meant a
    /// relaunch reset the user's chosen quiet interval and the next comment
    /// could arrive immediately — the app forgetting a preference precisely
    /// because it restarted.
    private var lastPresentedAtPersisted: Date? {
        get {
            let seconds = UserDefaults.standard.double(forKey: Self.lastPresentedKey)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastPresentedKey)
        }
    }

    private static let lastPresentedKey = "screenAgentLastPresentedAt"

    init(container: ModelContainer) {
        self.container = container
    }

    /// Save the item, decide, record the outcome. Returns the item when it
    /// should be shown — the caller renders it, this decides whether it may.
    ///
    /// The item is stored whatever the decision is: a comment suppressed
    /// because the user was in a meeting is still a comment they can go and
    /// read afterwards, which is the difference between quiet hours and
    /// throwing work away.
    @discardableResult
    func deliver(_ item: ScreenAgentItem, preflight: Preflight) -> ScreenAgentItem? {
        let context = ModelContext(container)

        // Idempotent by run: a retried run must not produce a second comment.
        let runID = item.runID
        var existing = FetchDescriptor<ScreenAgentItem>(
            predicate: #Predicate { $0.runID == runID }
        )
        existing.fetchLimit = 1
        do {
            if try !context.fetch(existing).isEmpty {
                NSLog("[ScreenAgentDelivery] run %@ already produced an item — not duplicating",
                      runID.uuidString)
                return nil
            }
        } catch {
            // A failed duplicate check is not proof there is no duplicate.
            // Reading it as "go ahead" is how one comment becomes two.
            NSLog("[ScreenAgentDelivery] duplicate check failed (%@) — not delivering",
                  error.localizedDescription)
            return nil
        }

        let decision = Self.decide(preflight)
        switch decision {
        case .present:
            // Still pending. Writing `presented` here would be a claim about
            // something that has not happened yet: the popup is built and
            // pushed afterwards, and a quit or a render failure in between
            // would leave durable history saying the user saw something they
            // never did. `confirmPresented` is what makes it true.
            item.deliveryOutcome = ScreenAgentDelivery.Outcome.pending.rawValue
        case .suppress(let reason):
            item.deliveryOutcome = ScreenAgentDelivery.Outcome.suppressed.rawValue
            item.suppressionReason = reason.rawValue
        }

        context.insert(item)
        do {
            try context.save()
        } catch {
            // Nothing may be shown that could not be written down: the user
            // would have no way to get back to it.
            NSLog("[ScreenAgentDelivery] persist failed (%@) — not presenting",
                  error.localizedDescription)
            return nil
        }

        guard case .present = decision else {
            NSLog("[ScreenAgentDelivery] suppressed (%@) — item kept in Inbox",
                  item.suppressionReason ?? "?")
            return nil
        }
        return item
    }

    /// The card is on screen. Only now is `presented` a fact, and only now does
    /// pacing start counting — advancing it earlier would let a comment nobody
    /// saw hold back the next one.
    func confirmPresented(itemID: UUID) {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ScreenAgentItem>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        guard let item = (try? context.fetch(descriptor))?.first else { return }
        item.deliveryOutcome = ScreenAgentDelivery.Outcome.presented.rawValue
        item.deliveredAt = Date()
        do {
            try context.save()
        } catch {
            NSLog("[ScreenAgentDelivery] could not record presentation: %@", error.localizedDescription)
            return
        }
        lastPresentedAt = Date()
        lastPresentedAtPersisted = Date()
    }

    /// Seconds since the last comment the user actually saw. Pacing counts
    /// presentations, not generations — otherwise a quiet period spent
    /// suppressing things reads as a busy one.
    var secondsSinceLastPresented: TimeInterval? {
        let last = lastPresentedAt ?? lastPresentedAtPersisted
        return last.map { Date().timeIntervalSince($0) }
    }

    /// Record what the user did, separately from whether it was shown.
    func recordInteraction(_ interaction: ScreenAgentDelivery.Interaction, itemID: UUID) {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ScreenAgentItem>(
            predicate: #Predicate { $0.id == itemID }
        )
        descriptor.fetchLimit = 1
        guard let item = (try? context.fetch(descriptor))?.first else { return }
        // First answer wins. A card can be opened and then also time out, and
        // overwriting `opened` with `timedOut` would turn something the user
        // acted on into something they ignored.
        guard item.interaction == ScreenAgentDelivery.Interaction.none.rawValue else { return }
        item.interaction = interaction.rawValue
        item.interactedAt = Date()
        do {
            try context.save()
        } catch {
            NSLog("[ScreenAgentDelivery] could not record interaction: %@", error.localizedDescription)
        }
    }

    /// Newest first, for the Inbox.
    /// Record what the user said was wrong, and act on it where the reason
    /// says to.
    ///
    /// `tooIntrusive` moves pacing and nothing else: the user complained about
    /// the moment, not the claim, and silencing the claim would be answering a
    /// question they did not ask.
    func recordFeedback(_ feedback: ScreenAgentDelivery.Feedback, itemID: UUID) {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ScreenAgentItem>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        guard let item = (try? context.fetch(descriptor))?.first else { return }
        item.feedbackReason = feedback.rawValue
        item.feedbackAt = Date()
        if item.semanticSignature.isEmpty {
            item.semanticSignature = ScreenAgentDirector.semanticSignature(of: item.headline)
        }
        do {
            try context.save()
        } catch {
            NSLog("[ScreenAgentDelivery] could not record feedback: %@", error.localizedDescription)
            return
        }
        if feedback == .tooIntrusive {
            let current = ScreenAgentPacing(rawValue: AppSettings.shared.screenAgentPacing) ?? .balanced
            AppSettings.shared.screenAgentPacing = current.quieter.rawValue
            NSLog("[ScreenAgentDelivery] bad moment — pacing now %@", current.quieter.rawValue)
        }
    }

    /// Signatures of ideas the user said were untrue or already handled, inside
    /// the current pacing window. `tooIntrusive` is deliberately absent: it was
    /// about timing, and blocking the content would answer a complaint nobody
    /// made.
    ///
    /// Codex P1, confirmed by a live probe: the predicate version of this
    /// force-unwrapped an optional, SwiftData rejected it at runtime, and
    /// `(try? …) ?? []` read that failure as "no feedback exists" — feedback
    /// was being recorded and then never consulted, with nothing in any log.
    /// Plain fetch, in-memory filter: the table is small and a failure is loud.
    func rejectedSignatures() -> [String] {
        let pacing = ScreenAgentPacing(rawValue: AppSettings.shared.screenAgentPacing) ?? .balanced
        let cutoff = Date().addingTimeInterval(-pacing.duplicateWindowSeconds)
        let blocking: Set<String> = [ScreenAgentDelivery.Feedback.wrong.rawValue,
                                     ScreenAgentDelivery.Feedback.repeated.rawValue,
                                     ScreenAgentDelivery.Feedback.obvious.rawValue]
        let rows: [ScreenAgentItem]
        do {
            rows = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentItem>())
        } catch {
            NSLog("[ScreenAgentDelivery] could not read feedback (%@)", error.localizedDescription)
            return []
        }
        return rows.compactMap { row in
            guard let at = row.feedbackAt, at > cutoff,
                  blocking.contains(row.feedbackReason ?? "") else { return nil }
            // Rows migrated from V4 carry an empty signature; compute rather
            // than silently exempting exactly the comments the user already
            // complained about.
            return row.semanticSignature.isEmpty
                ? ScreenAgentDirector.semanticSignature(of: row.headline)
                : row.semanticSignature
        }
    }

    /// Presentations in the trailing 24 hours — the reference counts a rolling
    /// window, not local midnight.
    func presentedInLast24h() -> Int {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let presented = ScreenAgentDelivery.Outcome.presented.rawValue
        let descriptor = FetchDescriptor<ScreenAgentItem>(
            predicate: #Predicate { $0.deliveryOutcome == presented && $0.createdAt > cutoff })
        return (try? ModelContext(container).fetchCount(descriptor)) ?? 0
    }

    /// Newest first. The cap used to be 100 with no way past it, so a comment
    /// older than that stayed in the database and vanished from every filter —
    /// durable in name only.
    func recentItems(limit: Int = 500) -> [ScreenAgentItem] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ScreenAgentItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
