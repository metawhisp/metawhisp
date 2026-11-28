import Foundation
import SwiftData

/// FEAT-0005 §5 — a draft is an automatic suggestion (`TaskItem.status == "staged"`) the user accepts or drops,
/// in Tasks → Suggested or on the after-call card. Both places go through here, so a draft accepted twice is one
/// task (the row keeps its id) and a draft dropped in one place cannot be accepted in the other.
///
/// Every write is a fresh fetch by id in a new context: a view's copy of the row may be older than another
/// place's write, and a save writes back every field of the object it changed (stale-save rule, 2026-11-24).
/// spec://intelligence/FEAT-0005#drafts
@MainActor
enum TaskDrafts {

    /// K10 — at most this many suggestions are shown at once.
    static let maxVisible = 5

    /// The suggestions to show: drafts not dropped, not done, inside the 7-day window (expiry computed on read,
    /// I3), newest first, at most `maxVisible`.
    static func visible(_ tasks: [TaskItem], now: Date = Date()) -> [TaskItem] {
        Array(tasks
            .filter {
                $0.effectiveStatus == "staged" && !$0.isDismissed && !$0.completed
                    && !TaskHygiene.isStaleUnreviewedCandidate(status: "staged", createdAt: $0.createdAt, now: now)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maxVisible))
    }

    enum AcceptOutcome: Equatable {
        /// The draft is a task now.
        case added
        /// It was accepted before (elsewhere, or a second tap): nothing written.
        case alreadyAdded
        /// It was dropped: refused.
        case dismissed
        /// Older than the review window: refused, the row left as it is (no expiry writer).
        case expired
        /// No such row.
        case gone
        /// The store refused the save.
        case failed
    }

    enum DropOutcome: Equatable {
        case dropped
        /// It is a task already (accepted elsewhere): refused, a drop never removes an accepted task.
        case alreadyAdded
        case gone
        case failed
    }

    static func accept(_ id: UUID, in container: ModelContainer, now: Date = Date(),
                       mutations: MutationService = .shared) -> AcceptOutcome {
        let ctx = ModelContext(container)
        guard let row = fetch(id, in: ctx) else { return .gone }
        if row.isDismissed || row.effectiveStatus == "dismissed" { return .dismissed }
        if row.effectiveStatus != "staged" { return .alreadyAdded }
        if TaskHygiene.isStaleUnreviewedCandidate(status: "staged", createdAt: row.createdAt, now: now) {
            return .expired
        }
        do {
            try mutations.commit(.taskSaved(id), in: ctx) {
                row.status = "committed"
                row.updatedAt = now
            }
            return .added
        } catch {
            NSLog("[TaskDrafts] accept save failed: %@", error.localizedDescription)
            return .failed
        }
    }

    static func drop(_ id: UUID, in container: ModelContainer, now: Date = Date(),
                     mutations: MutationService = .shared) -> DropOutcome {
        let ctx = ModelContext(container)
        guard let row = fetch(id, in: ctx) else { return .gone }
        if row.isDismissed || row.effectiveStatus == "dismissed" { return .dropped }
        if row.effectiveStatus != "staged" { return .alreadyAdded }
        do {
            try mutations.commit(.taskDismissed(id), in: ctx) {
                row.status = "dismissed"
                row.isDismissed = true
                row.updatedAt = now
            }
            return .dropped
        } catch {
            NSLog("[TaskDrafts] drop save failed: %@", error.localizedDescription)
            return .failed
        }
    }

    private static func fetch(_ id: UUID, in ctx: ModelContext) -> TaskItem? {
        var desc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        return (try? ctx.fetch(desc))?.first
    }
}
