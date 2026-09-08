import SwiftData
import XCTest
@testable import MetaWhisp

/// Saying out loud something the screen agent had already proposed is how a
/// proposal gets confirmed. It never worked: `fetchPendingProposals()` built
/// its OWN `ModelContext`, so the objects it returned belonged to a context
/// nobody saved. The extraction cleared `needsReview` on those throwaway
/// objects, counted a confirmation, and `continue`d — skipping the memory from
/// this extraction too. The fact was lost twice: still pending in the store,
/// and not inserted (audit, 2026-09-06, P1).
///
/// The rule under it is ordinary: read and write in the same context, or the
/// write goes nowhere.
@MainActor
final class MemoryProposalConfirmationTests: XCTestCase {

    private func makeStore() throws -> ModelContainer {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func pending(_ text: String, in ctx: ModelContext) -> UserMemory {
        let m = UserMemory(content: text, category: "preference", sourceApp: "TestApp", confidence: 0.9)
        m.needsReview = true
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    /// The confirmation must be visible to anyone who opens the store next —
    /// not only to the context that made it.
    func testConfirmingAProposalSurvivesInTheStore() throws {
        let container = try makeStore()
        let writing = ModelContext(container)
        _ = pending("prefers morning meetings", in: writing)

        // Read the proposals in the SAME context that will be saved.
        let found = MemoryExtractor.pendingProposals(in: writing)
        XCTAssertEqual(found.count, 1)
        MemoryExtractor.confirm(found[0])
        try writing.save()

        let reading = ModelContext(container)
        let all = try reading.fetch(FetchDescriptor<UserMemory>())
        XCTAssertEqual(all.count, 1, "confirming must not insert a second copy")
        XCTAssertFalse(all[0].needsReview, "the confirmation must be in the store, not in a context nobody saved")
    }

    /// Reading through a context that is never saved is exactly the bug; the
    /// test pins that the helper takes the caller's context rather than making
    /// its own.
    func testTheProposalsComeBackInTheCallersContext() throws {
        let container = try makeStore()
        let mine = ModelContext(container)
        _ = pending("drinks tea, not coffee", in: mine)

        let found = MemoryExtractor.pendingProposals(in: mine)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].modelContext === mine,
                      "a proposal fetched into a foreign context cannot be saved by this one")
    }

    /// A dismissed or already-confirmed memory is not a pending proposal.
    func testOnlyPendingProposalsComeBack() throws {
        let container = try makeStore()
        let ctx = ModelContext(container)
        let confirmed = pending("already known", in: ctx); confirmed.needsReview = false
        let dismissed = pending("rejected", in: ctx); dismissed.isDismissed = true
        _ = pending("still waiting", in: ctx)
        try ctx.save()

        let found = MemoryExtractor.pendingProposals(in: ctx)
        XCTAssertEqual(found.map(\.content), ["still waiting"])
    }
}
