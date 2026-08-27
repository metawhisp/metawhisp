import Foundation
import SwiftData

/// ITER-057.1 — the promotion loop: the ONLY mechanism that resurfaces staged
/// task candidates on its own (reference-parity, все каденции из первоисточника).
///
/// Reference model: «напоминает сам» is NOT a timer on each task — it's a slot
/// system. The app keeps ≈`targetActiveAITasks` screen-sourced tasks active;
/// whenever a slot frees up (user completed/dismissed one) the TOP staged
/// candidate is promoted to committed and — if the opt-in toggle is on — the
/// user gets ONE notification. Anti-nagging by construction:
///   • startup pass is always SILENT (reference);
///   • one task notifies at most once (promotion moves it out of staged);
///   • notifications default OFF (`taskPromotionNotificationsEnabled`);
///   • only fresh candidates promote (TaskHygiene review window — week-old
///     staged is noise and stays hidden).
@MainActor
final class TaskPromotionService: ObservableObject {
    static let shared = TaskPromotionService()

    /// Reference numbers (see ITER-057 §4): ≈5 active AI tasks, 300s safety timer.
    static let targetActiveAITasks = 5
    static let safetyInterval: TimeInterval = 300

    private var modelContainer: ModelContainer?
    private var safetyTimer: Timer?
    /// Injectable for tests (same seam as ChatToolExecutor).
    var mutationService: MutationService = .shared

    /// Set when the last promotion pass ran (surfaced nowhere yet; debug aid).
    private(set) var lastRunAt: Date?
    /// Codex review — promotion commits fire MutationService hooks, and the
    /// hooks poke this service back; without the guard a pass filling several
    /// slots would re-enter mid-count and overshoot the target.
    private var isPromoting = false

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Call once at launch: silent catch-up pass + the safety-net timer.
    func start() {
        promoteIfNeeded(notify: false)   // startup is SILENT (reference)
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.safetyInterval, repeats: true) { _ in
            Task { @MainActor in TaskPromotionService.shared.promoteIfNeeded(notify: true) }
        }
    }

    /// A task was deleted/dismissed — a slot may have opened. Called from
    /// MutationService production hooks; completions are caught by the timer.
    func noteSlotMaybeVacated() {
        promoteIfNeeded(notify: true)
    }

    /// Pure slot math, pinned by tests.
    nonisolated static func promotionsNeeded(activeAICount: Int, target: Int = targetActiveAITasks) -> Int {
        max(0, target - activeAICount)
    }

    /// ITER-057.2 — candidate ordering: ranked first (relevanceScore ascending,
    /// 1 = most important), unranked (nil) after ALL ranked, recency as tiebreak.
    /// This is what stops fresh dev-screen junk from beating a ranked real
    /// commitment. Pure, pinned by tests.
    nonisolated static func ranksHigher(scoreA: Int?, createdA: Date, scoreB: Int?, createdB: Date) -> Bool {
        switch (scoreA, scoreB) {
        case let (a?, b?) where a != b: return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        default: return createdA > createdB
        }
    }

    /// One promotion pass. Screen-sourced active tasks count toward the target;
    /// candidates = staged, not dismissed, not completed (a fulfilled candidate
    /// must never surface), inside the TaskHygiene review window, ordered by
    /// `ranksHigher` (ITER-057.2 relevance, then recency).
    @discardableResult
    func promoteIfNeeded(notify: Bool, now: Date = Date()) -> Int {
        guard !isPromoting else { return 0 }
        guard AppSettings.shared.tasksEnabled else { return 0 }
        guard StoreHealthSignal.shared.isHealthy else { return 0 }
        guard let container = modelContainer else { return 0 }
        isPromoting = true
        defer { isPromoting = false }
        lastRunAt = now
        let ctx = ModelContext(container)

        let activePred = #Predicate<TaskItem> {
            $0.screenContextId != nil && $0.status == "committed" && !$0.completed && !$0.isDismissed
        }
        let activeCount = (try? ctx.fetchCount(FetchDescriptor<TaskItem>(predicate: activePred))) ?? 0
        let need = Self.promotionsNeeded(activeAICount: activeCount)
        guard need > 0 else { return 0 }

        var stagedDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "staged" && !$0.isDismissed && !$0.completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Recency-capped pool: the re-ranker scores within this same window, and
        // the hygiene filter drops week-old candidates anyway.
        stagedDesc.fetchLimit = 200
        let staged = ((try? ctx.fetch(stagedDesc)) ?? [])
            .filter { !TaskHygiene.isStaleUnreviewedCandidate(status: $0.status ?? "staged", createdAt: $0.createdAt, now: now) }
            .sorted { Self.ranksHigher(scoreA: $0.relevanceScore, createdA: $0.createdAt,
                                       scoreB: $1.relevanceScore, createdB: $1.createdAt) }
            .prefix(need)

        var promoted = 0
        for candidate in staged {
            do {
                try mutationService.commit(.taskSaved(candidate.id), in: ctx) {
                    candidate.status = "committed"
                    candidate.updatedAt = now
                }
                promoted += 1
                NSLog("[TaskPromotion] ⬆️ promoted: %@", String(candidate.taskDescription.prefix(60)))
                if notify, AppSettings.shared.taskPromotionNotificationsEnabled {
                    postPromotionNotification(for: candidate)
                }
            } catch {
                NSLog("[TaskPromotion] ⚠️ promote failed: %@", error.localizedDescription)
                break   // store trouble — retry on the next pass
            }
        }
        return promoted
    }

    /// Reference copy: title "Task", body "New task: {description}". Tap opens
    /// the Tasks surface (Workspace tab) — same route as extraction notifications.
    private func postPromotionNotification(for task: TaskItem) {
        let note = MWNotification(
            kind: .task,
            title: "Task added",
            body: String(task.taskDescription.prefix(200)),
            onTap: { AppDelegate.shared?.openMainWindow(tab: .workspace) },
            proactiveItems: nil
        )
        MWNotificationStack.shared.push(note)
    }
}
