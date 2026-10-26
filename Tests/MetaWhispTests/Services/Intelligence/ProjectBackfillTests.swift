import XCTest
import SwiftData
@testable import MetaWhisp

/// ITER-075 step 1 (1.6) — the project backfill, run against an in-memory
/// store with its LLM run passed in: it never blanks a conversation, checks
/// each once, and only reaches conversations from before the project question.
@MainActor
final class ProjectBackfillTests: XCTestCase {

    private var folder: URL!
    private var ledgerURL: URL { ProjectBackfillLedger.fileURL(in: folder) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-project-backfill-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func store(_ rows: [Conversation]) throws -> (ProjectAggregator, ModelContainer) {
        let schema = Schema([HistoryItem.self, Conversation.self, ProjectAlias.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration("Test", isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        rows.forEach { ctx.insert($0) }
        try ctx.save()
        let aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: container)
        return (aggregator, container)
    }

    /// A completed, titled conversation from `days` days before the project question.
    private func legacy(_ title: String, days: Double) -> Conversation {
        let conv = Conversation(source: "meeting",
                                startedAt: ProjectAggregator.projectQuestionShipped.addingTimeInterval(-days * 86_400))
        conv.status = "completed"
        conv.title = title
        conv.overview = "About \(title)"
        return conv
    }

    func testARunWithNoAnswerLeavesTheConversationAsItWasAndTriesAgain() async throws {
        let row = legacy("Planning", days: 10)
        let (aggregator, container) = try store([row])
        for outcome in [StructuredOutcome.failed, .notNow] {
            await aggregator.backfillProjects(hasLLMAccess: true, ledgerURL: ledgerURL, pause: .zero) { _ in
                // The 2026-09-22 row went blank in the middle of a run, not after it.
                let during = try? ModelContext(container).fetch(FetchDescriptor<Conversation>()).first
                XCTAssertEqual(during?.title, "Planning", "never blank while the run is on")
                XCTAssertEqual(during?.overview, "About Planning")
                return outcome
            }
            let fresh = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
            XCTAssertEqual(fresh.title, "Planning", "\(outcome)")
            XCTAssertEqual(fresh.overview, "About Planning", "\(outcome)")
        }
        XCTAssertTrue(ProjectBackfillLedger(fileURL: ledgerURL).checked.isEmpty, "tried again at the next launch")
    }

    func testCheckedConversationsAreSkippedAndOlderOnesReached() async throws {
        let rows = (1...5).map { legacy("Meeting \($0)", days: Double($0)) }
        let (aggregator, _) = try store(rows)
        var asked: [UUID] = []
        await aggregator.backfillProjects(hasLLMAccess: true, ledgerURL: ledgerURL, limit: 2, pause: .zero) {
            asked.append($0)
            return .written
        }
        XCTAssertEqual(asked, [rows[0].id, rows[1].id], "the newest two first")
        asked = []
        await aggregator.backfillProjects(hasLLMAccess: true, ledgerURL: ledgerURL, limit: 2, pause: .zero) {
            asked.append($0)
            return .written
        }
        XCTAssertEqual(asked, [rows[2].id, rows[3].id], "checked ones are skipped, older ones reached")
    }

    /// A conversation from after the project question already had it asked;
    /// its empty project is the LLM's answer.
    func testOnlyConversationsFromBeforeTheProjectQuestionAreBackfilled() async throws {
        let old = legacy("Old", days: 1)
        let recent = Conversation(source: "meeting",
                                  startedAt: ProjectAggregator.projectQuestionShipped.addingTimeInterval(86_400))
        recent.status = "completed"
        recent.title = "Recent"
        let (aggregator, _) = try store([old, recent])
        var asked: [UUID] = []
        await aggregator.backfillProjects(hasLLMAccess: true, ledgerURL: ledgerURL, pause: .zero) {
            asked.append($0)
            return .written
        }
        XCTAssertEqual(asked, [old.id])
    }

    func testWithoutAccessNothingRuns() async throws {
        let (aggregator, _) = try store([legacy("Planning", days: 3)])
        var asked = 0
        await aggregator.backfillProjects(hasLLMAccess: false, ledgerURL: ledgerURL, pause: .zero) { _ in
            asked += 1
            return .written
        }
        XCTAssertEqual(asked, 0)
    }

    /// A project the owner deleted doesn't come back with the next backfill.
    func testADeletedProjectIsNotGivenBack() async throws {
        let row = legacy("Tagged", days: 2)
        row.primaryProject = "ProjectAlpha"
        let (aggregator, _) = try store([row])
        _ = aggregator.resolveCanonical("ProjectAlpha")
        XCTAssertEqual(aggregator.deleteProject(canonicalName: "ProjectAlpha", ledgerURL: ledgerURL), 1)
        var asked: [UUID] = []
        await aggregator.backfillProjects(hasLLMAccess: true, ledgerURL: ledgerURL, pause: .zero) {
            asked.append($0)
            return .written
        }
        XCTAssertEqual(asked, [])
    }
}
