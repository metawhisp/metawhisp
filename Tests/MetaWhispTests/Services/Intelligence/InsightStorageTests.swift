import XCTest
@testable import MetaWhisp

/// Pure-function tests for `InsightStorage` mappers.
///
/// `InsightStorage.save(...)` and `loadRecent(...)` are thin SwiftData
/// glue and aren't unit-tested directly (per `specs/TDD.md` —
/// SwiftData ModelContainer setup needs live FS). The conversion
/// helpers `toUserMemory(_:)` and `fromUserMemory(_:)` are pure
/// functions and ARE tested here — that's where data corruption
/// tends to creep in (wrong category string, dropped headline,
/// confidence mis-cast, etc.).
final class InsightStorageTests: XCTestCase {

    // MARK: - ExtractedInsight → UserMemory (save shape)

    /// Insight is stored under `category="system"` and tagged
    /// `tagsCSV` contains "insight". This is the shape MetaChat
    /// already filters out (system memories aren't surfaced as
    /// regular facts to the user) — perfect for our use.
    func test_toUserMemory_setsCategorySystemAndInsightTag() {
        let insight = ExtractedInsight(
            body: "Stashed changes 2h ago — git stash pop",
            headline: "Pop git stash",
            reasoning: "User had stash from morning, hasn't restored",
            category: "productivity",
            sourceApp: "Terminal",
            confidence: 0.92
        )
        let mem = InsightStorage.toUserMemory(insight)
        XCTAssertEqual(mem.category, "system")
        XCTAssertNotNil(mem.tagsCSV)
        XCTAssertTrue(
            (mem.tagsCSV ?? "").contains("insight"),
            "expected tagsCSV to contain 'insight', got \(mem.tagsCSV ?? "nil")"
        )
    }

    /// Tag list also contains the insight's `category` so future filtering
    /// by domain (productivity vs communication) is easy.
    func test_toUserMemory_includesCategoryInTags() {
        let insight = ExtractedInsight(
            body: "Replying to thread, not DM — check recipient",
            headline: "Wrong recipient",
            reasoning: nil,
            category: "communication",
            sourceApp: "Slack",
            confidence: 0.88
        )
        let mem = InsightStorage.toUserMemory(insight)
        XCTAssertTrue(
            (mem.tagsCSV ?? "").contains("communication"),
            "expected tagsCSV to contain 'communication'"
        )
    }

    /// Body, headline, reasoning, sourceApp, confidence all carry over.
    func test_toUserMemory_carriesAllFields() {
        let insight = ExtractedInsight(
            body: "Year 2026 — did you mean 2027?",
            headline: "Year typo",
            reasoning: "Calendar event date appears to be 1y off from neighbours",
            category: "productivity",
            sourceApp: "Calendar",
            confidence: 0.95
        )
        let mem = InsightStorage.toUserMemory(insight)
        XCTAssertEqual(mem.content, "Year 2026 — did you mean 2027?")
        XCTAssertEqual(mem.headline, "Year typo")
        XCTAssertEqual(mem.reasoning, "Calendar event date appears to be 1y off from neighbours")
        XCTAssertEqual(mem.sourceApp, "Calendar")
        XCTAssertEqual(mem.confidence, 0.95, accuracy: 0.001)
    }

    // MARK: - UserMemory → ExtractedInsight (dedup seeding shape)

    /// Round-trips a memory created from an insight back into an insight
    /// without losing the body/headline/category/confidence.
    func test_fromUserMemory_recoversInsight() {
        let original = ExtractedInsight(
            body: "Sensitive credentials visible — mask before sharing",
            headline: "Creds visible",
            reasoning: nil,
            category: "communication",
            sourceApp: "Terminal",
            confidence: 0.91
        )
        let mem = InsightStorage.toUserMemory(original)
        let recovered = InsightStorage.fromUserMemory(mem)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.body, original.body)
        XCTAssertEqual(recovered?.headline, original.headline)
        XCTAssertEqual(recovered?.sourceApp, original.sourceApp)
        XCTAssertEqual(recovered?.confidence ?? -1, original.confidence, accuracy: 0.001)
    }

    /// Memory rows that do NOT have the insight tag must NOT be
    /// recovered as insights — they're just regular memories that
    /// happen to be `category=system`.
    func test_fromUserMemory_returnsNilWhenNotTaggedAsInsight() {
        let mem = UserMemory(
            content: "Some other system fact",
            category: "system",
            sourceApp: "Slack",
            confidence: 0.8
        )
        // Tag with something else, not "insight".
        mem.tagsCSV = "preference,workhabit"
        XCTAssertNil(InsightStorage.fromUserMemory(mem))
    }

    /// Recovered insights inherit `category` from the memory's
    /// non-system tag (if any), defaulting to "other" when absent.
    func test_fromUserMemory_extractsDomainCategoryFromTags() {
        let insight = ExtractedInsight(
            body: "Test body",
            headline: nil,
            reasoning: nil,
            category: "learning",
            sourceApp: "Xcode",
            confidence: 0.8
        )
        let mem = InsightStorage.toUserMemory(insight)
        let recovered = InsightStorage.fromUserMemory(mem)
        XCTAssertEqual(recovered?.category, "learning")
    }
}
