import XCTest
@testable import MetaWhisp

/// Weekly Insights tab — pure row-formatting logic (ITER-047 dead-UI follow-up).
/// `WeeklyInsightFormatter` turns a `PatternDigest`'s fields into the three
/// things a week row shows: ISO week number, a date range, and one short
/// summary sentence. Pinned here so the row text stays deterministic and the
/// view stays a dumb renderer.
final class WeeklyInsightFormatterTests: XCTestCase {

    /// ISO-8601, UTC — stable week numbers + date math regardless of host TZ.
    private var cal: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - weekNumber (ISO week-of-year)

    func testWeekNumberIsISOWeekOfYear() {
        // 2026-01-01 is a Thursday → ISO week 1 spans Dec 29 2025 – Jan 4 2026,
        // so Mon Jan 5 2026 starts ISO week 2.
        XCTAssertEqual(WeeklyInsightFormatter.weekNumber(for: date(2026, 1, 5), calendar: cal), 2)
        // 22 whole weeks later → ISO week 24.
        XCTAssertEqual(WeeklyInsightFormatter.weekNumber(for: date(2026, 6, 8), calendar: cal), 24)
    }

    // MARK: - dateRange

    func testDateRangeSpansTheAnalysedWindow() {
        let range = WeeklyInsightFormatter.dateRange(
            weekStart: date(2026, 6, 8),
            windowDays: 7,
            calendar: cal,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(range, "Jun 8 – Jun 14")
    }

    // MARK: - summaryLine

    func testSummaryLinePrefersFirstInsight() {
        let line = WeeklyInsightFormatter.summaryLine(
            isEmpty: false,
            insights: ["You keep revisiting onboarding but logged no tasks"],
            themes: ["Release 1.3.12"],
            conversationsAnalyzed: 12
        )
        XCTAssertEqual(line, "You keep revisiting onboarding but logged no tasks")
    }

    func testSummaryLineFallsBackToTopThemeWhenNoInsights() {
        let line = WeeklyInsightFormatter.summaryLine(
            isEmpty: false,
            insights: ["   "],            // whitespace-only → skipped
            themes: ["Pricing"],
            conversationsAnalyzed: 5
        )
        XCTAssertEqual(line, "Recurring theme: Pricing")
    }

    func testSummaryLineFallsBackToConversationCount() {
        XCTAssertEqual(
            WeeklyInsightFormatter.summaryLine(isEmpty: false, insights: [], themes: [], conversationsAnalyzed: 1),
            "1 conversation analyzed"
        )
        XCTAssertEqual(
            WeeklyInsightFormatter.summaryLine(isEmpty: false, insights: [], themes: [], conversationsAnalyzed: 3),
            "3 conversations analyzed"
        )
    }

    func testSummaryLineEmptyWeekReadsAsQuiet() {
        let line = WeeklyInsightFormatter.summaryLine(
            isEmpty: true,
            insights: [],
            themes: [],
            conversationsAnalyzed: 0
        )
        XCTAssertEqual(line, "Quiet week — no recurring patterns")
    }
}
