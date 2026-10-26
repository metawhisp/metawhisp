import XCTest
@testable import MetaWhisp

/// 2026-10-20 — the proactive relevance gate was handed the current screen,
/// the last hour's window titles, and the texts of the last five cards as
/// topics not to repeat. It read both lists as the present: in the owner's
/// log that day 262 of 298 fires scored exactly 0.95, 95 of the reasons cited
/// a "recent topic", and "currently in a Telegram chat" fired from runs in
/// Safari, Preview and Arc. The gate now judges only what is on screen;
/// repeats stay blocked after the model, by the dedup.
@MainActor
final class InsightAssistantGateTests: XCTestCase {

    private func insight(_ body: String) -> ExtractedInsight {
        ExtractedInsight(body: body, headline: nil, reasoning: nil,
                         category: "other", sourceApp: "Test", confidence: 0.9)
    }

    private let recentCard = "Send the salary report to Sam before 18:00"

    /// What the gate is asked, read where it is asked: the app, the window
    /// and what is on it — no window-title history, no recent topics.
    func testTheGateIsAskedAboutTheScreenNowOnly() async {
        let assistant = InsightAssistantService()
        assistant.seedDedup(from: [insight(recentCard)])
        var asked: [String] = []
        assistant.relevanceGate = { context, _ in
            asked.append(context)
            return (shouldFire: false, score: 0, reasoning: "test", failedOpen: false)
        }

        _ = await assistant.evaluate(
            appName: "Mail",
            windowTitle: "Inbox - Alex",
            ocr: "Lunch on Friday?",
            activitySummary: "Telegram - Project chat (12 min)\nPreview - invoice.pdf (4 min)",
            licenseKey: "test-key")

        XCTAssertEqual(asked.count, 1, "the gate is asked once per run")
        let context = asked.first ?? ""
        XCTAssertTrue(context.contains("Mail"))
        XCTAssertTrue(context.contains("Inbox - Alex"))
        XCTAssertTrue(context.contains("Lunch on Friday?"))
        XCTAssertFalse(context.contains("Telegram"), "no history of window titles")
        XCTAssertFalse(context.contains("invoice.pdf"), "no history of window titles")
        XCTAssertFalse(context.contains("salary report"), "no recent topics")
    }

    /// Repeats are still stopped where they always were, after the model: a
    /// card equal to a recent one is dropped.
    func testACardEqualToARecentOneIsStillDropped() {
        let assistant = InsightAssistantService()
        assistant.seedDedup(from: [insight(recentCard)])
        XCTAssertNil(assistant.acceptCandidate(insight(recentCard)))
    }

    /// The pair to the test above: a new topic on screen fires anyway.
    func testANewTopicOnScreenFiresAnyway() {
        let assistant = InsightAssistantService()
        assistant.seedDedup(from: [insight(recentCard)])
        let fresh = insight("The invoice total on screen is $120 more than the order")
        XCTAssertEqual(assistant.acceptCandidate(fresh), fresh)
    }
}
