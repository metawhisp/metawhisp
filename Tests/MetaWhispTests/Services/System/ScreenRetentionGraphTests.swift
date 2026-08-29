import SwiftData
import XCTest
@testable import MetaWhisp

/// "Delete screen history" is a promise with a confirmation dialog in front of
/// it. Two things walked past it.
///
/// The insight path writes a UserMemory with no `screenContextId`, and deletion
/// selects memories BY that field — so every fact the agent derived from the
/// screen survived the wipe, and so did its exported copy in the user's Obsidian
/// vault, because the vault cleanup runs over the same list. Measured on the
/// real store: 1441 such rows.
///
/// And `ScreenAgentRunMetrics`, added a day earlier, was never wired into
/// retention at all.
@MainActor
final class ScreenRetentionGraphTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ScreenContext.self, ScreenObservation.self, UserMemory.self,
            TaskItem.self, ScreenAgentItem.self, ScreenAgentRun.self,
            ScreenAgentDeliveryRecord.self, ContextVisitRecord.self,
            ScreenAgentRunMetrics.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// The one that leaves files on disk. A fact derived from the screen has to
    /// be reachable by the delete, or its Obsidian copy is never named either.
    func testAnInsightDerivedFactIsReachableByTheDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let screenID = UUID()
        let insight = ExtractedInsight(
            body: "The ads payment was declined", headline: "Payment declined",
            reasoning: nil, category: "system", sourceApp: "Chrome", confidence: 0.9)
        context.insert(InsightStorage.toUserMemory(insight, screenContextId: screenID))
        try context.save()

        let result = try ScreenRetention.deleteAll(in: context)

        XCTAssertEqual(result.memoryIds.count, 1,
                       "a fact derived from the screen must be named by the delete — "
                       + "the Obsidian cleanup runs over exactly this list")
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserMemory>()).isEmpty)
    }

    /// Counters describing runs over screens that no longer exist.
    func testDeletingScreenHistoryTakesTheRunMetricsWithIt() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(ScreenAgentRunMetrics(runID: UUID(), gateOutcome: "fired"))
        context.insert(ScreenAgentRunMetrics(runID: UUID(), gateOutcome: "skipped"))
        try context.save()

        _ = try ScreenRetention.deleteAll(in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<ScreenAgentRunMetrics>()).isEmpty,
                      "metrics describe runs over history that is now gone")
    }

    /// What the user confirmed is theirs and stays — the delete dialog says so.
    func testConfirmedWorkSurvivesTheDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let committed = TaskItem(taskDescription: "Send the deck",
                                 screenContextId: UUID(), status: "committed")
        context.insert(committed)
        let ownFact = UserMemory(content: "I prefer morning meetings",
                                 category: "user", sourceApp: "", confidence: 1)
        context.insert(ownFact)
        try context.save()

        _ = try ScreenRetention.deleteAll(in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 1,
                       "a task the user promoted lives its own life")
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserMemory>()).count, 1,
                       "a fact with no screen origin was never screen history")
    }

    /// The 1442 already written. Their origin is genuinely lost — the link was
    /// never recorded — so it cannot be recovered, only guessed at from
    /// timestamps, and a guessed link is a wrong deletion waiting to happen.
    /// They are identifiable by what they are instead: the `insight` tag is
    /// written from exactly one place in the app.
    func testLegacyInsightsWithNoLinkAreStillScreenHistory() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let legacy = InsightStorage.toUserMemory(
            ExtractedInsight(body: "The ads payment was declined",
                             headline: "Payment declined", reasoning: nil,
                             category: "system", sourceApp: "Chrome", confidence: 0.9))
        XCTAssertNil(legacy.screenContextId, "this is the shape that already exists on disk")
        context.insert(legacy)
        try context.save()

        let result = try ScreenRetention.deleteAll(in: context)

        XCTAssertEqual(result.memoryIds.count, 1,
                       "an unlinked insight is still a fact read off the screen — "
                       + "and its Obsidian copy is named by this same list")
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserMemory>()).isEmpty)
    }

    /// The boundary that makes the widened selection safe. 445 rows on the real
    /// store are system-category with no link and no insight tag — profile
    /// facts, calendar-derived things. They were never screen history and the
    /// delete must not take them.
    func testSystemFactsThatAreNotInsightsAreLeftAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let other = UserMemory(content: "User works European hours",
                               category: "system", sourceApp: "Calendar", confidence: 0.8)
        other.tagsCSV = "profile,schedule"
        context.insert(other)
        try context.save()

        let result = try ScreenRetention.deleteAll(in: context)

        XCTAssertTrue(result.memoryIds.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserMemory>()).count, 1,
                       "no screen origin, no insight tag — not screen history")
    }
}
