import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-057.2 — re-ranking pure logic.
@MainActor
final class TaskPrioritizationServiceTests: XCTestCase {

    // MARK: - shouldRerank guards

    func test_shouldRerank_tooFewStaged_false() {
        XCTAssertFalse(TaskPrioritizationService.shouldRerank(lastRerankAt: nil, stagedCount: 0, now: Date()))
        XCTAssertFalse(TaskPrioritizationService.shouldRerank(lastRerankAt: nil, stagedCount: 1, now: Date()))
    }

    func test_shouldRerank_firstRun_true() {
        XCTAssertTrue(TaskPrioritizationService.shouldRerank(lastRerankAt: nil, stagedCount: 2, now: Date()))
    }

    func test_shouldRerank_intervalNotElapsed_false() {
        let now = Date()
        let last = now.addingTimeInterval(-1800)   // 30 min ago < 3600s
        XCTAssertFalse(TaskPrioritizationService.shouldRerank(lastRerankAt: last, stagedCount: 5, now: now))
    }

    func test_shouldRerank_intervalElapsed_true() {
        let now = Date()
        let last = now.addingTimeInterval(-3601)
        XCTAssertTrue(TaskPrioritizationService.shouldRerank(lastRerankAt: last, stagedCount: 5, now: now))
    }

    // MARK: - parseRerank

    func test_parse_cleanJSON() {
        let id = UUID().uuidString
        let parsed = TaskPrioritizationService.parseRerank(
            #"{"reranked":[{"id":"\#(id)","new_position":1}]}"#)
        XCTAssertEqual(parsed, [.init(id: id, new_position: 1)])
    }

    func test_parse_markdownFencedJSON() {
        let id = UUID().uuidString
        let response = """
        ```json
        {"reranked":[{"id":"\(id)","new_position":2}]}
        ```
        """
        XCTAssertEqual(TaskPrioritizationService.parseRerank(response), [.init(id: id, new_position: 2)])
    }

    func test_parse_garbage_nil() {
        XCTAssertNil(TaskPrioritizationService.parseRerank("no json here"))
        XCTAssertNil(TaskPrioritizationService.parseRerank(#"{"wrong":"shape"}"#))
    }

    /// The 2026-07-17 incident: a reasoning model returned pure chain-of-thought
    /// prose with no JSON at all — must yield nil (→ hourly backoff), not crash.
    func test_parse_reasoningProseOnly_nil() {
        XCTAssertNil(TaskPrioritizationService.parseRerank(
            "We need to re-rank based on criteria. We have a list of staged candidates with ids and brief descriptions."))
    }

    func test_parse_malformedEntry_lossyNotFatal() {
        let good = UUID().uuidString
        let response = #"{"reranked":[{"id":"\#(good)","new_position":1},{"id":2},{"new_position":"x"}]}"#
        XCTAssertEqual(TaskPrioritizationService.parseRerank(response), [.init(id: good, new_position: 1)])
    }

    func test_parse_allEntriesMalformed_nil() {
        XCTAssertNil(TaskPrioritizationService.parseRerank(#"{"reranked":[{"id":2},{"id":3}]}"#))
    }

    // MARK: - apply

    private func makeTask(_ desc: String) -> TaskItem {
        TaskItem(taskDescription: desc, status: "staged")
    }

    func test_apply_setsScoresByMatchingId() {
        let a = makeTask("Send Alex the onboarding deck")
        let b = makeTask("Reply to Sam about the contract")
        let positions: [TaskPrioritizationService.RankedPosition] = [
            .init(id: b.id.uuidString, new_position: 1),
            .init(id: a.id.uuidString, new_position: 2),
        ]
        let applied = TaskPrioritizationService.apply(positions: positions, to: [a, b])
        XCTAssertEqual(applied, 2)
        XCTAssertEqual(b.relevanceScore, 1)
        XCTAssertEqual(a.relevanceScore, 2)
    }

    func test_apply_unknownAndInvalidIdsIgnored() {
        let a = makeTask("Send Alex the onboarding deck")
        let positions: [TaskPrioritizationService.RankedPosition] = [
            .init(id: UUID().uuidString, new_position: 1),   // unknown
            .init(id: "not-a-uuid", new_position: 2),        // garbage
            .init(id: a.id.uuidString, new_position: 0),     // position < 1
        ]
        XCTAssertEqual(TaskPrioritizationService.apply(positions: positions, to: [a]), 0)
        XCTAssertNil(a.relevanceScore)
    }

    func test_apply_duplicateId_firstWins() {
        let a = makeTask("Send Alex the onboarding deck")
        let positions: [TaskPrioritizationService.RankedPosition] = [
            .init(id: a.id.uuidString, new_position: 3),
            .init(id: a.id.uuidString, new_position: 9),
        ]
        XCTAssertEqual(TaskPrioritizationService.apply(positions: positions, to: [a]), 1)
        XCTAssertEqual(a.relevanceScore, 3)
    }

    // MARK: - buildPrompt

    func test_buildPrompt_includesAllSections() {
        let id = UUID()
        let prompt = TaskPrioritizationService.buildPrompt(
            goals: ["Ship v2: land the release"],
            staged: [(id: id, description: "Send Alex the deck", dueAt: nil, createdAt: Date(timeIntervalSince1970: 0))],
            completed: ["Paid the Stripe invoice"],
            dismissed: ["Watch a webinar recording"]
        )
        XCTAssertTrue(prompt.contains("USER GOALS"))
        XCTAssertTrue(prompt.contains("Ship v2"))
        XCTAssertTrue(prompt.contains(id.uuidString))
        XCTAssertTrue(prompt.contains("RECENTLY COMPLETED"))
        XCTAssertTrue(prompt.contains("RECENTLY DISMISSED"))
    }

    func test_buildPrompt_emptyOptionalSectionsOmitted() {
        let prompt = TaskPrioritizationService.buildPrompt(
            goals: [], staged: [(id: UUID(), description: "x y z w", dueAt: nil, createdAt: Date())],
            completed: [], dismissed: [])
        XCTAssertFalse(prompt.contains("USER GOALS"))
        XCTAssertFalse(prompt.contains("RECENTLY COMPLETED"))
        XCTAssertFalse(prompt.contains("RECENTLY DISMISSED"))
        XCTAssertTrue(prompt.contains("STAGED CANDIDATES"))
    }

    // MARK: - FEAT-0005 voice drafts

    /// I2 — the hourly re-rank orders screen candidates only: voice drafts never start a paid call nobody sees.
    func test_candidates_areScreenCandidatesOnly() throws {
        let container = try ModelContainer(for: TaskItem.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        ctx.insert(TaskItem(taskDescription: "Screen candidate", screenContextId: UUID(), status: "staged"))
        ctx.insert(TaskItem(taskDescription: "Voice draft one", sourceApp: "microphone", status: "staged"))
        ctx.insert(TaskItem(taskDescription: "Voice draft two", sourceApp: "meeting", status: "staged"))
        ctx.insert(TaskItem(taskDescription: "A task", screenContextId: UUID(), status: "committed"))
        try ctx.save()

        let found = try ctx.fetch(TaskPrioritizationService.candidatesDescriptor(limit: 30))
        XCTAssertEqual(found.map(\.taskDescription), ["Screen candidate"])
        XCTAssertFalse(TaskPrioritizationService.shouldRerank(lastRerankAt: nil, stagedCount: found.count, now: Date()),
                       "two voice drafts and one screen candidate are not enough to re-rank")
    }
}
