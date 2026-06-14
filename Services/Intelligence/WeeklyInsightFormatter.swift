import Foundation

/// Pure row-formatting for the Weekly Insights tab.
///
/// A `PatternDigest` (ITER-022 G5) stores arrays of themes / people / stuck
/// loops / insights. The Weekly Insights list shows each week as one row:
/// ISO week number + analysed date range + a single short summary sentence.
/// Keeping this logic pure (no SwiftUI / SwiftData) lets the view stay a dumb
/// renderer and the row text stay deterministic under test.
enum WeeklyInsightFormatter {

    /// ISO week-of-year for the analysed window's start. An ISO-8601 calendar is
    /// the default so the number is stable regardless of the user's week-start
    /// preference (Settings → General → "Week starts on").
    static func weekNumber(for weekStart: Date,
                           calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        calendar.component(.weekOfYear, from: weekStart)
    }

    /// Date-range label for the analysed window, e.g. "Jun 8 – Jun 14".
    /// `windowDays` is the length of the window; the end is inclusive.
    static func dateRange(weekStart: Date,
                          windowDays: Int,
                          calendar: Calendar = Calendar(identifier: .iso8601),
                          locale: Locale = .current) -> String {
        let span = max(0, windowDays - 1)
        let end = calendar.date(byAdding: .day, value: span, to: weekStart) ?? weekStart
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = locale
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(fmt.string(from: weekStart)) – \(fmt.string(from: end))"
    }

    /// One short summary sentence for a week row. Prefers a synthesized
    /// cross-context insight, then the top recurring theme, then a neutral count
    /// line. An empty digest reads as a quiet week. Blank entries are skipped so
    /// a stored `""` never surfaces as an empty row.
    static func summaryLine(isEmpty: Bool,
                            insights: [String],
                            themes: [String],
                            conversationsAnalyzed: Int) -> String {
        if isEmpty { return "Quiet week — no recurring patterns" }
        if let insight = firstNonBlank(insights) { return insight }
        if let theme = firstNonBlank(themes) { return "Recurring theme: \(theme)" }
        let n = max(0, conversationsAnalyzed)
        return "\(n) conversation\(n == 1 ? "" : "s") analyzed"
    }

    private static func firstNonBlank(_ items: [String]) -> String? {
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
