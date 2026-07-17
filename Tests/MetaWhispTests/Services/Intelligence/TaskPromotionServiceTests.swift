import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-057.1 — pins the promotion loop: slot math, ordering, hygiene window,
/// silence rules, and one-promotion-per-task (a promoted task leaves staged, so
/// it can never notify twice by construction).
@MainActor
final class TaskPromotionServiceTests: XCTestCase {

    private func makeService() throws -> (TaskPromotionService, ModelContext) {
        let container = try ModelContainer(
            for: TaskItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let svc = TaskPromotionService()
        svc.configure(modelContainer: container)
        // Test mutation service: real save, no production hooks (no Obsidian/
        // MCP/promotion re-entry from tests).
        svc.mutationService = MutationService(runHooks: { _ in })
        return (svc, ModelContext(container))
    }

    private func staged(_ desc: String, ageDays: Double = 0.1) -> TaskItem {
        let t = TaskItem(taskDescription: desc, screenContextId: UUID(), status: "staged")
        t.createdAt = Date(timeIntervalSinceNow: -ageDays * 86_400)
        return t
    }

    private func activeAI(_ desc: String) -> TaskItem {
        TaskItem(taskDescription: desc, screenContextId: UUID(), status: "committed")
    }

    // MARK: - Pure slot math

    func test_promotionsNeeded_slotMath() {
        XCTAssertEqual(TaskPromotionService.promotionsNeeded(activeAICount: 0), 5)
        XCTAssertEqual(TaskPromotionService.promotionsNeeded(activeAICount: 3), 2)
        XCTAssertEqual(TaskPromotionService.promotionsNeeded(activeAICount: 5), 0)
        XCTAssertEqual(TaskPromotionService.promotionsNeeded(activeAICount: 9), 0, "never negative")
    }

    // MARK: - Promotion pass

    /// Empty active set → promotes up to the target, newest staged first.
    func test_promote_fillsSlots_newestFirst() throws {
        let (svc, ctx) = try makeService()
        for i in 0..<7 { ctx.insert(staged("cand \(i)", ageDays: Double(7 - i) * 0.1)) }
        try ctx.save()

        let promoted = svc.promoteIfNeeded(notify: false)

        XCTAssertEqual(promoted, 5, "fills all 5 slots")
        let committed = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "committed" }))
        XCTAssertEqual(committed.count, 5)
        // Newest candidates won (cand 6 has the smallest age).
        XCTAssertTrue(Set(committed.map(\.taskDescription)).contains("cand 6"))
        XCTAssertFalse(Set(committed.map(\.taskDescription)).contains("cand 0"), "oldest two stay staged")
    }

    /// Slots already full → nothing happens; second pass is a no-op (one
    /// promotion per task, ever).
    func test_promote_respectsTarget_andIsIdempotent() throws {
        let (svc, ctx) = try makeService()
        for i in 0..<5 { ctx.insert(activeAI("active \(i)")) }
        ctx.insert(staged("waiting"))
        try ctx.save()

        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 0, "target already met")

        // Free one slot → exactly one promotion, then stable.
        let victim = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "committed" })).first!
        victim.isDismissed = true
        try ctx.save()
        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 1)
        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 0, "no staged left → stable")
    }

    /// Week-old staged candidates are hygiene-hidden noise — never promoted.
    func test_promote_skipsStaleCandidates() throws {
        let (svc, ctx) = try makeService()
        ctx.insert(staged("fresh", ageDays: 1))
        ctx.insert(staged("stale", ageDays: 9))
        try ctx.save()

        _ = svc.promoteIfNeeded(notify: false)

        let committed = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "committed" }))
        XCTAssertEqual(committed.map(\.taskDescription), ["fresh"])
        let stillStaged = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "staged" }))
        XCTAssertEqual(stillStaged.map(\.taskDescription), ["stale"])
    }

    /// Dismissed staged candidates (user said no) never come back.
    func test_promote_neverResurrectsDismissed() throws {
        let (svc, ctx) = try makeService()
        let rejected = staged("rejected")
        rejected.isDismissed = true
        ctx.insert(rejected)
        try ctx.save()

        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 0)
    }

    // MARK: - ITER-057.2 ordering

    func test_ranksHigher_comparator() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 1000)
        // Ranked beats unranked regardless of age.
        XCTAssertTrue(TaskPromotionService.ranksHigher(scoreA: 7, createdA: older, scoreB: nil, createdB: newer))
        XCTAssertFalse(TaskPromotionService.ranksHigher(scoreA: nil, createdA: newer, scoreB: 7, createdB: older))
        // Lower score = more important.
        XCTAssertTrue(TaskPromotionService.ranksHigher(scoreA: 1, createdA: older, scoreB: 2, createdB: newer))
        // Equal scores / both nil → recency tiebreak.
        XCTAssertTrue(TaskPromotionService.ranksHigher(scoreA: nil, createdA: newer, scoreB: nil, createdB: older))
        XCTAssertTrue(TaskPromotionService.ranksHigher(scoreA: 3, createdA: newer, scoreB: 3, createdB: older))
    }

    /// A ranked real commitment beats fresher unranked junk (the founder's exact
    /// complaint: dev-screen noise won slots from Mattermost commitments).
    func test_promote_rankedCandidateBeatsNewerUnranked() throws {
        let (svc, ctx) = try makeService()
        let ranked = staged("Send Alex the onboarding deck", ageDays: 3)
        ranked.relevanceScore = 1
        let junk = staged("Allow keychain access for xctest", ageDays: 0.01)
        // Fill 4 of 5 slots so exactly one promotion happens.
        for i in 0..<4 { ctx.insert(activeAI("active \(i)")) }
        ctx.insert(ranked); ctx.insert(junk)
        try ctx.save()

        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 1)
        // Refetch — promotion mutates through its own ModelContext.
        let committed = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "committed" })).map(\.taskDescription)
        XCTAssertTrue(committed.contains("Send Alex the onboarding deck"), "ranked candidate wins the slot")
        let stillStaged = try ctx.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.status == "staged" })).map(\.taskDescription)
        XCTAssertEqual(stillStaged, ["Allow keychain access for xctest"])
    }

    /// ITER-057.5 — a fulfilled (auto-completed) staged candidate never surfaces.
    func test_promote_skipsCompletedCandidates() throws {
        let (svc, ctx) = try makeService()
        let done = staged("Reply to Sam about the contract")
        done.completed = true
        ctx.insert(done)
        try ctx.save()

        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 0)
        XCTAssertEqual(done.status, "staged", "completed candidate stays put")
    }

    /// tasksEnabled OFF → the loop is inert.
    func test_promote_respectsMasterToggle() throws {
        let (svc, ctx) = try makeService()
        ctx.insert(staged("cand"))
        try ctx.save()
        let saved = AppSettings.shared.tasksEnabled
        AppSettings.shared.tasksEnabled = false
        defer { AppSettings.shared.tasksEnabled = saved }

        XCTAssertEqual(svc.promoteIfNeeded(notify: false), 0)
    }
}
