import XCTest
@testable import MetaWhisp

/// Pure-function tests for `InsightPrompts.buildUserPrompt(...)`.
///
/// `InsightPrompts.systemPrompt` is the strict reference-derived rule sheet
/// (do/don't, GOOD/BAD examples, confidence calibration). Not unit-tested
/// directly — its purpose is shaping the LLM's output, validated by the
/// `InsightOutputParser` tests downstream.
///
/// `buildUserPrompt(...)` is the per-call payload assembled from current
/// screen state + activity history + previous insights for dedup. It IS a
/// pure function of its inputs and gets these tests.
final class InsightPromptsTests: XCTestCase {

    // MARK: - Header (current screen context)

    /// App name + window title appear at the top so the LLM has immediate
    /// context for "what is the user looking at right now".
    func test_userPrompt_includesAppAndWindow() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Terminal",
            windowTitle: "ssh prod-db-01 — vim deploy.sh",
            ocr: "git stash list\nstash@{0}: WIP on main",
            activitySummary: "",
            previousInsights: []
        )
        XCTAssertTrue(p.contains("CURRENT APP: Terminal"))
        XCTAssertTrue(p.contains("ssh prod-db-01 — vim deploy.sh"))
    }

    /// Window title is optional. When absent, the line should still parse
    /// and not produce empty quotes that confuse the model.
    func test_userPrompt_skipsBlankWindowTitle() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Slack",
            windowTitle: nil,
            ocr: "anything here",
            activitySummary: "",
            previousInsights: []
        )
        XCTAssertTrue(p.contains("CURRENT APP: Slack"))
        XCTAssertFalse(p.contains("Window: \"\""))
    }

    // MARK: - Current screen OCR

    /// OCR text is included so the LLM can reason about visible content.
    func test_userPrompt_includesOCR() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Calendar",
            windowTitle: "September 2026",
            ocr: "Q3 review · Sept 12, 2026 · 2:00 PM",
            activitySummary: "",
            previousInsights: []
        )
        XCTAssertTrue(p.contains("Q3 review · Sept 12, 2026"))
    }

    /// Very long OCR is truncated so we don't blow the prompt window.
    /// Reference truncation: 1500 chars (matches MetaWhisp existing
    /// `embedOne` cap and is well under any model's input limit).
    func test_userPrompt_truncatesLongOCR() {
        let huge = String(repeating: "x", count: 5000)
        let p = InsightPrompts.buildUserPrompt(
            appName: "Notion",
            windowTitle: "Doc",
            ocr: huge,
            activitySummary: "",
            previousInsights: []
        )
        // Whole prompt should be reasonably bounded — not 5000+ chars of x's.
        XCTAssertLessThan(p.count, 3500,
                          "Prompt grew too large; OCR truncation didn't apply")
    }

    // MARK: - Activity summary

    /// Activity summary block (last hour aggregate) is included verbatim.
    /// Builder is just stitching strings; aggregation lives elsewhere.
    func test_userPrompt_includesActivitySummary() {
        let summary = """
            ACTIVITY SUMMARY (last 60 min, 25 frames):
            App | Window | Screenshots | Est. Duration
            ------------------------------------------------------------
            Terminal | ssh prod-db-01 | 12 | 0.2 min
            Slack    | #deploys       |  8 | 0.1 min
            """
        let p = InsightPrompts.buildUserPrompt(
            appName: "Terminal",
            windowTitle: "ssh prod-db-01",
            ocr: "...",
            activitySummary: summary,
            previousInsights: []
        )
        XCTAssertTrue(p.contains("ACTIVITY SUMMARY"))
        XCTAssertTrue(p.contains("Terminal | ssh prod-db-01 | 12"))
    }

    /// Empty activity summary is fine — the block is just skipped.
    func test_userPrompt_omitsEmptyActivitySummary() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Mail",
            windowTitle: "Inbox",
            ocr: "From: boss@…",
            activitySummary: "",
            previousInsights: []
        )
        XCTAssertFalse(p.contains("ACTIVITY SUMMARY"))
    }

    // MARK: - Previous insights for dedup

    /// Each previous insight is listed under "PREVIOUSLY PROVIDED INSIGHTS"
    /// with an explicit "do not repeat" instruction. Mirrors reference
    /// `runAdviceExtraction` dedup section (`InsightAssistant.swift:540-553`).
    func test_userPrompt_listsPreviousInsightsForDedup() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Terminal",
            windowTitle: "ssh ...",
            ocr: "...",
            activitySummary: "",
            previousInsights: [
                "Stashed changes 2h ago — git stash pop",
                "Sensitive credentials visible — mask before sharing"
            ]
        )
        XCTAssertTrue(p.contains("PREVIOUSLY PROVIDED INSIGHTS"))
        XCTAssertTrue(p.contains("Stashed changes 2h ago"))
        XCTAssertTrue(p.contains("Sensitive credentials visible"))
        XCTAssertTrue(
            p.localizedCaseInsensitiveContains("do not repeat") ||
            p.localizedCaseInsensitiveContains("don't repeat")
        )
    }

    /// On first-ever run there are no previous insights — block is omitted
    /// rather than included as an empty list (which the LLM might
    /// misinterpret as "you've said zero things, so anything's fresh").
    func test_userPrompt_omitsPreviousInsightsBlockWhenEmpty() {
        let p = InsightPrompts.buildUserPrompt(
            appName: "Slack",
            windowTitle: "DM",
            ocr: "...",
            activitySummary: "",
            previousInsights: []
        )
        XCTAssertFalse(p.contains("PREVIOUSLY PROVIDED INSIGHTS"))
    }

    /// Cap previous insights to 30 entries to keep prompt size bounded
    /// even after months of accumulation. Mirrors reference
    /// `maxInsightsInPrompt = 30` (`InsightAssistant.swift:27`).
    func test_userPrompt_capsPreviousInsightsAt30() {
        let many = (1...50).map { "Insight number \($0) about something" }
        let p = InsightPrompts.buildUserPrompt(
            appName: "Slack",
            windowTitle: "x",
            ocr: "x",
            activitySummary: "",
            previousInsights: many
        )
        XCTAssertTrue(p.contains("Insight number 1 about something"))
        XCTAssertTrue(p.contains("Insight number 30 about something"))
        XCTAssertFalse(p.contains("Insight number 31 about something"))
    }
}
