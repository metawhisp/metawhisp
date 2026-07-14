import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-053.1 — retention for the screen-intelligence store. History: neither
/// ScreenContext nor ScreenObservation was EVER pruned — a plaintext OCR
/// history of everything on screen grew unbounded (thousands of rows/day).
/// The flagship promise «локально + bounded + one-click delete» starts here.
@MainActor
final class ScreenRetentionTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ScreenContext.self, ScreenObservation.self,
            TaskItem.self, UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func insertContext(_ ctx: ModelContext, ageDays: Double) {
        let row = ScreenContext(appName: "Safari", windowTitle: "t", ocrText: "text")
        row.timestamp = Date(timeIntervalSinceNow: -ageDays * 86_400)
        ctx.insert(row)
    }

    private func insertObservation(_ ctx: ModelContext, ageDays: Double) {
        let end = Date(timeIntervalSinceNow: -ageDays * 86_400)
        let row = ScreenObservation(
            screenContextId: nil, appName: "Safari", windowTitle: "t",
            contextSummary: "s", currentActivity: "a", hasTask: false,
            startedAt: end.addingTimeInterval(-60), endedAt: end
        )
        ctx.insert(row)
    }

    private func counts(_ ctx: ModelContext) throws -> (contexts: Int, observations: Int) {
        let c = try ctx.fetchCount(FetchDescriptor<ScreenContext>())
        let o = try ctx.fetchCount(FetchDescriptor<ScreenObservation>())
        return (c, o)
    }

    // MARK: - cutoff policy (pure)

    /// 0 (and anything below) means «keep forever» — no cutoff date.
    func test_cutoff_zeroOrNegativeDays_meansForever() {
        XCTAssertNil(ScreenRetention.cutoff(now: Date(), days: 0))
        XCTAssertNil(ScreenRetention.cutoff(now: Date(), days: -5))
    }

    func test_cutoff_positiveDays_isExactlyNDaysBack() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let cut = ScreenRetention.cutoff(now: now, days: 30)
        XCTAssertEqual(cut, now.addingTimeInterval(-30 * 86_400))
    }

    // MARK: - prune

    /// Rows older than the retention window are deleted; newer ones stay.
    func test_prune_deletesOldKeepsRecent() throws {
        let ctx = try makeContext()
        insertContext(ctx, ageDays: 45)   // old — must go
        insertContext(ctx, ageDays: 5)    // recent — must stay
        insertObservation(ctx, ageDays: 200)  // old — must go
        insertObservation(ctx, ageDays: 10)   // recent — must stay
        try ctx.save()

        let deleted = try ScreenRetention.prune(in: ctx, rawDays: 30, observationDays: 180)

        XCTAssertEqual(deleted.contexts, 1)
        XCTAssertEqual(deleted.observations, 1)
        let after = try counts(ctx)
        XCTAssertEqual(after.contexts, 1)
        XCTAssertEqual(after.observations, 1)
    }

    /// Retention 0 = forever: prune must be a no-op even on ancient rows.
    func test_prune_zeroDays_keepsEverything() throws {
        let ctx = try makeContext()
        insertContext(ctx, ageDays: 400)
        insertObservation(ctx, ageDays: 400)
        try ctx.save()

        let deleted = try ScreenRetention.prune(in: ctx, rawDays: 0, observationDays: 0)

        XCTAssertEqual(deleted.contexts, 0)
        XCTAssertEqual(deleted.observations, 0)
        let after = try counts(ctx)
        XCTAssertEqual(after.contexts, 1)
        XCTAssertEqual(after.observations, 1)
    }

    /// The two tables have INDEPENDENT windows — raw OCR (privacy-hot) dies
    /// young, distilled observations live longer.
    func test_prune_independentWindows() throws {
        let ctx = try makeContext()
        insertContext(ctx, ageDays: 45)       // > 30 → dies
        insertObservation(ctx, ageDays: 45)   // < 180 → stays
        try ctx.save()

        let deleted = try ScreenRetention.prune(in: ctx, rawDays: 30, observationDays: 180)

        XCTAssertEqual(deleted.contexts, 1)
        XCTAssertEqual(deleted.observations, 0)
    }

    /// Empty store — prune is a harmless no-op (fresh installs, post-delete-all).
    func test_prune_emptyStore_noop() throws {
        let ctx = try makeContext()
        let deleted = try ScreenRetention.prune(in: ctx, rawDays: 30, observationDays: 180)
        XCTAssertEqual(deleted.contexts, 0)
        XCTAssertEqual(deleted.observations, 0)
    }

    // MARK: - delete all (the one-click promise)

    func test_deleteAll_wipesBothTables() throws {
        let ctx = try makeContext()
        insertContext(ctx, ageDays: 1)
        insertContext(ctx, ageDays: 100)
        insertObservation(ctx, ageDays: 1)
        try ctx.save()

        let deleted = try ScreenRetention.deleteAll(in: ctx)

        XCTAssertEqual(deleted.contexts, 2)
        XCTAssertEqual(deleted.observations, 1)
        let after = try counts(ctx)
        XCTAssertEqual(after.contexts, 0)
        XCTAssertEqual(after.observations, 0)
    }

    func test_deleteAll_emptyStore_noop() throws {
        let ctx = try makeContext()
        let deleted = try ScreenRetention.deleteAll(in: ctx)
        XCTAssertEqual(deleted.contexts, 0)
        XCTAssertEqual(deleted.observations, 0)
        XCTAssertEqual(deleted.tasks, 0)
        XCTAssertEqual(deleted.memories, 0)
    }

    /// The privacy promise covers UNCONFIRMED screen-derived artifacts (Codex
    /// review): staged screen tasks + screen memories die with the history.
    /// What the user confirmed (promoted task) and what didn't come from the
    /// screen (dictation task, conversation memory) stays — I3/I4.
    func test_deleteAll_wipesUnconfirmedScreenArtifacts_keepsConfirmedAndNonScreen() throws {
        let ctx = try makeContext()
        let screenId = UUID()
        // Staged + dismissed screen tasks → die. Promoted screen task → stays.
        ctx.insert(TaskItem(taskDescription: "staged from screen",
                            screenContextId: screenId, status: "staged"))
        ctx.insert(TaskItem(taskDescription: "dismissed from screen",
                            screenContextId: screenId, status: "dismissed"))
        ctx.insert(TaskItem(taskDescription: "promoted from screen",
                            screenContextId: screenId, status: "committed"))
        // Staged NON-screen task → stays (didn't come from the purged history).
        ctx.insert(TaskItem(taskDescription: "staged from dictation", status: "staged"))
        // Screen memory → dies. Conversation memory → stays.
        ctx.insert(UserMemory(content: "from screen", category: "system",
                              sourceApp: "Safari", confidence: 0.9,
                              screenContextId: screenId))
        ctx.insert(UserMemory(content: "from conversation", category: "system",
                              sourceApp: "conversation", confidence: 0.9))
        try ctx.save()

        let deleted = try ScreenRetention.deleteAll(in: ctx)

        XCTAssertEqual(deleted.tasks, 2)
        XCTAssertEqual(deleted.memories, 1)
        XCTAssertEqual(Set(deleted.taskIds).count, 2, "IDs surface for external cleanup hooks")
        let tasksLeft = try ctx.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(tasksLeft.map(\.taskDescription)),
                       ["promoted from screen", "staged from dictation"])
        let memoriesLeft = try ctx.fetch(FetchDescriptor<UserMemory>())
        XCTAssertEqual(memoriesLeft.map(\.content), ["from conversation"])
    }
}
