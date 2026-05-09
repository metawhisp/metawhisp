import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ActivitySummaryBuilder.build(...)`.
///
/// The builder aggregates `ScreenContext`-shaped rows from the last hour
/// into the textual summary block consumed by `InsightPrompts.buildUserPrompt`.
///
/// Format is deliberately reference-shaped (`App | Window | Frames | Est. Duration`)
/// because the system prompt's GOOD/BAD examples implicitly reference
/// that visual layout — the LLM is more reliable when the surrounding
/// context matches the prompt's training shape.
final class ActivitySummaryBuilderTests: XCTestCase {

    // MARK: - Empty

    /// No rows in the lookback window → empty string. Caller skips the
    /// whole "ACTIVITY SUMMARY" block when input is empty.
    func test_emptyRows_returnsEmptyString() {
        let result = ActivitySummaryBuilder.build(
            rows: [],
            lookbackStart: Date().addingTimeInterval(-3600),
            now: Date()
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - Header

    /// Output begins with the human-readable header line so the LLM
    /// recognizes this as the activity block (not OCR or insights).
    func test_outputStartsWithACTIVITYSUMMARYHeader() {
        let now = Date()
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "Slack", windowTitle: "DM", timestamp: now.addingTimeInterval(-300))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        XCTAssertTrue(result.hasPrefix("ACTIVITY SUMMARY"),
                      "got:\n\(result)")
    }

    // MARK: - Aggregation

    /// Rows with same (app, window) pair collapse into one entry with a
    /// frame count — the LLM gets density info, not raw timestamps.
    func test_aggregatesByAppAndWindow() {
        let now = Date()
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "Terminal", windowTitle: "ssh prod", timestamp: now.addingTimeInterval(-100)),
            .init(appName: "Terminal", windowTitle: "ssh prod", timestamp: now.addingTimeInterval(-200)),
            .init(appName: "Terminal", windowTitle: "ssh prod", timestamp: now.addingTimeInterval(-300)),
            .init(appName: "Slack",    windowTitle: "DM",       timestamp: now.addingTimeInterval(-400))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        XCTAssertTrue(result.contains("Terminal | ssh prod | 3"),
                      "expected 'Terminal | ssh prod | 3', got:\n\(result)")
        XCTAssertTrue(result.contains("Slack | DM | 1"),
                      "expected 'Slack | DM | 1', got:\n\(result)")
    }

    /// Highest-count row appears first (the dominant activity gets prime
    /// position so the LLM weights it correctly).
    func test_sortedByCountDescending() {
        let now = Date()
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "Slack",    windowTitle: "DM",  timestamp: now.addingTimeInterval(-100)),
            .init(appName: "Terminal", windowTitle: "ssh", timestamp: now.addingTimeInterval(-200)),
            .init(appName: "Terminal", windowTitle: "ssh", timestamp: now.addingTimeInterval(-300)),
            .init(appName: "Terminal", windowTitle: "ssh", timestamp: now.addingTimeInterval(-400)),
            .init(appName: "Notion",   windowTitle: "Doc", timestamp: now.addingTimeInterval(-500))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        let terminalIdx = result.range(of: "Terminal | ssh | 3")?.lowerBound
        let notionIdx = result.range(of: "Notion | Doc | 1")?.lowerBound
        XCTAssertNotNil(terminalIdx)
        XCTAssertNotNil(notionIdx)
        XCTAssertLessThan(terminalIdx!, notionIdx!,
                          "dominant Terminal should appear before Notion")
    }

    // MARK: - Lookback window

    /// Rows older than `lookbackStart` are excluded from aggregation —
    /// caller is responsible for the time-window contract.
    func test_excludesRowsBeforeLookbackStart() {
        let now = Date()
        let lookback = now.addingTimeInterval(-3600)
        let rows: [ActivitySummaryBuilder.Row] = [
            // In window
            .init(appName: "Slack", windowTitle: "DM", timestamp: now.addingTimeInterval(-1800)),
            // Out of window (older than 1h)
            .init(appName: "OldApp", windowTitle: "x", timestamp: now.addingTimeInterval(-7200))
        ]
        let result = ActivitySummaryBuilder.build(rows: rows, lookbackStart: lookback, now: now)
        XCTAssertTrue(result.contains("Slack | DM"))
        XCTAssertFalse(result.contains("OldApp"))
    }

    /// Rows with `timestamp > now` (clock-skew, future-dated) are also
    /// excluded — defensive against bad timestamps.
    func test_excludesFutureDatedRows() {
        let now = Date()
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "Now", windowTitle: "x", timestamp: now.addingTimeInterval(-100)),
            .init(appName: "Future", windowTitle: "x", timestamp: now.addingTimeInterval(+3600))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        XCTAssertTrue(result.contains("Now | x"))
        XCTAssertFalse(result.contains("Future"))
    }

    // MARK: - Truncation

    /// Long window titles are truncated to keep prompt size bounded.
    /// Reference uses 50 chars; we mirror.
    func test_truncatesLongWindowTitlesAt50Chars() {
        let now = Date()
        let longTitle = String(repeating: "A", count: 80)
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "App", windowTitle: longTitle, timestamp: now.addingTimeInterval(-100))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        // Find the entry line — extract the window-title segment between the
        // first " | " and the next " | ".
        let line = result.split(separator: "\n").first(where: { $0.contains("App |") })?
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        XCTAssertGreaterThanOrEqual(line.count, 3)
        XCTAssertLessThanOrEqual(line[1].count, 50,
                                 "window title not truncated; got len=\(line[1].count)")
    }

    /// Rows whose window title is the empty string render as `(no title)`
    /// rather than producing a confusing blank cell.
    func test_emptyWindowTitleRendersPlaceholder() {
        let now = Date()
        let rows: [ActivitySummaryBuilder.Row] = [
            .init(appName: "App", windowTitle: "", timestamp: now.addingTimeInterval(-100))
        ]
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        XCTAssertTrue(result.contains("App | (no title)"),
                      "expected '(no title)' placeholder; got:\n\(result)")
    }

    // MARK: - Cap on rows

    /// Limit total rows in the output to a sane number even when many
    /// distinct (app, window) pairs exist. Mirrors reference cap = 30.
    func test_capsAt30Rows() {
        let now = Date()
        var rows: [ActivitySummaryBuilder.Row] = []
        for i in 0..<60 {
            rows.append(.init(appName: "App\(i)", windowTitle: "w", timestamp: now.addingTimeInterval(-Double(i))))
        }
        let result = ActivitySummaryBuilder.build(
            rows: rows,
            lookbackStart: now.addingTimeInterval(-3600),
            now: now
        )
        // Each kept row produces one line containing " | w | 1".
        let entryLines = result.split(separator: "\n").filter { $0.contains(" | w | 1") }
        XCTAssertEqual(entryLines.count, 30,
                       "expected 30 entries, got \(entryLines.count)")
    }
}
