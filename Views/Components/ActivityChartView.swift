import Charts
import SwiftUI

/// Bar chart showing transcription activity — BLOCKS monochromatic style.
/// Independent from period switcher. Shows data based on scale (DAYS/WEEKS/MONTHS) and metric.
struct ActivityChartView: View {
    let items: [HistoryItem]
    let scale: String       // "DAYS", "WEEKS", "MONTHS"
    let metric: String      // "WORDS", "TRANSCRIPTIONS", "TRANSLATIONS", "WPM", "SAVED TIME", "RECORDED"

    var body: some View {
        if items.isEmpty {
            Text("No data yet").font(MW.monoSm).foregroundStyle(MW.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(chartData, id: \.label) { point in
                BarMark(
                    x: .value("Time", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(MW.isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.55))
                .cornerRadius(0)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(MW.border)
                    AxisValueLabel()
                        .foregroundStyle(MW.textMuted)
                        .font(MW.monoSm)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .foregroundStyle(MW.textMuted)
                        .font(MW.monoSm)
                }
            }
        }
    }

    // MARK: - Data

    private struct ChartPoint { let label: String; let value: Double }

    private var chartData: [ChartPoint] {
        switch scale {
        case "WEEKS": return groupByWeek()
        case "MONTHS": return groupByMonth()
        default: return groupByDay()
        }
    }

    /// Last 10 days, each bar = 1 day
    private func groupByDay() -> [ChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        return (0..<10).reversed().map { daysAgo in
            let day = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            let dayItems = items.filter { cal.isDate(cal.startOfDay(for: $0.createdAt), inSameDayAs: day) }
            return ChartPoint(label: fmt.string(from: day), value: metricValue(for: dayItems))
        }
    }

    /// Last 8 weeks, each bar = 1 week. Respects user's week start day preference.
    private func groupByWeek() -> [ChartPoint] {
        var cal = Calendar.current
        cal.firstWeekday = AppSettings.shared.weekStartsOn // 1=Sunday, 2=Monday
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        // Find start of current week
        let today = Date()
        guard let currentWeekInterval = cal.dateInterval(of: .weekOfYear, for: today) else { return [] }

        return (0..<8).reversed().compactMap { weeksAgo in
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: currentWeekInterval.start) else { return nil }
            let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart)!
            let weekItems = items.filter { $0.createdAt >= weekStart && $0.createdAt < weekEnd }
            return ChartPoint(label: fmt.string(from: weekStart), value: metricValue(for: weekItems))
        }
    }

    /// Last 6 months, each bar = 1 month
    private func groupByMonth() -> [ChartPoint] {
        let cal = Calendar.current
        let today = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"

        return (0..<6).reversed().compactMap { monthsAgo in
            guard let monthStart = cal.date(byAdding: .month, value: -monthsAgo, to: today),
                  let interval = cal.dateInterval(of: .month, for: monthStart) else { return nil }
            let monthItems = items.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end }
            return ChartPoint(label: fmt.string(from: interval.start), value: metricValue(for: monthItems))
        }
    }

    /// Extract metric value from a group of items
    private func metricValue(for group: [HistoryItem]) -> Double {
        switch metric {
        case "TRANSCRIPTIONS":
            return Double(group.count)
        case "TRANSLATIONS":
            return Double(group.filter { $0.translatedTo != nil }.count)
        case "WPM":
            let totalWords = group.reduce(0) { $0 + $1.wordCount }
            let totalMinutes = group.reduce(0.0) { $0 + $1.audioDuration } / 60.0
            return totalMinutes > 0 ? Double(totalWords) / totalMinutes : 0
        case "SAVED TIME":
            let words = group.reduce(0) { $0 + $1.wordCount }
            let typingTime = Double(words) / 30.0 * 60.0
            let actualTime = group.reduce(0.0) { $0 + $1.audioDuration } + group.reduce(0.0) { $0 + $1.processingTime }
            return max(0, typingTime - actualTime)
        case "RECORDED":
            return group.reduce(0.0) { $0 + $1.audioDuration }
        default: // WORDS
            return Double(group.reduce(0) { $0 + $1.wordCount })
        }
    }
}
