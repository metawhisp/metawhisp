import Charts
import SwiftData
import SwiftUI

/// Statistics dashboard — BLOCKS monochromatic style with real data from SwiftData.
/// Matches the DashboardPrototype layout: STREAK, WORDS, TRANSCRIPTIONS, TRANSLATIONS,
/// WPM, SAVED TIME, RECORDED, HOURS USAGE chart, AUTO-CORRECTIONS, etc.
struct StatisticsView: View {
    @Query(sort: \HistoryItem.createdAt) private var allItems: [HistoryItem]
    @State private var selectedPeriod: StatPeriod = .allTime
    @State private var selectedMetric: String = "WORDS"
    @State private var chartScale: String = "DAYS"

    private var current: [HistoryItem] { selectedPeriod.filter(allItems) }
    private var previous: [HistoryItem] { selectedPeriod.previousFilter(allItems) }

    private let gap: CGFloat = 2

    var body: some View {
        if allItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: gap) {
                    periodSwitcher

                    // Row 1: STREAK | WORDS | TRANSCRIPTIONS | TRANSLATIONS  +  RECORDS column
                    HStack(alignment: .top, spacing: gap) {
                        VStack(spacing: gap) {
                            HStack(spacing: gap) {
                                BigMetricTile(
                                    label: "STREAK", value: "\(streakDays)",
                                    unit: "days"
                                )

                                BigMetricTile(
                                    label: "WORDS", value: fmtNum(stats.words),
                                    unit: "total", isSelected: selectedMetric == "WORDS"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "WORDS" } }

                                BigMetricTile(
                                    label: "TRANSCRIPTIONS", value: fmtNum(current.count),
                                    unit: "total", isSelected: selectedMetric == "TRANSCRIPTIONS"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "TRANSCRIPTIONS" } }

                                BigMetricTile(
                                    label: "TRANSLATIONS", value: fmtNum(translationsCount),
                                    unit: "total", isSelected: selectedMetric == "TRANSLATIONS"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "TRANSLATIONS" } }
                            }

                            // Row 2: WPM | SAVED TIME | RECORDED
                            HStack(spacing: gap) {
                                BigMetricTile(
                                    label: "WORDS PER MINUTE", value: "\(wpm)",
                                    unit: "avg", isSelected: selectedMetric == "WPM"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "WPM" } }

                                BigMetricTile(
                                    label: "SAVED TIME", value: fmtDuration(stats.saved),
                                    isSelected: selectedMetric == "SAVED TIME"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "SAVED TIME" } }

                                BigMetricTile(
                                    label: "RECORDED", value: fmtDuration(stats.audio),
                                    unit: "audio", isSelected: selectedMetric == "RECORDED"
                                )
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "RECORDED" } }
                            }

                            // Metric chart
                            activityChart
                        }

                        // Records column on the right
                        recordsSection.frame(width: 260)
                    }

                    // Hours Usage chart
                    hoursChart

                    // Bottom sections: POPULAR WORDS + FILLER WORDS + AUTO-CORRECTIONS
                    HStack(alignment: .top, spacing: gap) {
                        topWordsSection
                        VStack(spacing: gap) {
                            fillerSection
                            correctionsSection
                        }
                    }
                }
                .padding(gap)
                .frame(minWidth: 700)
            }
            // Share via context menu instead of toolbar button
        }
    }

    private var stats: PeriodStats { PeriodStats(current) }

    // MARK: - Computed Stats

    /// Days streak — consecutive days with at least one transcription
    private var streakDays: Int {
        let cal = Calendar.current
        let days = Set(allItems.map { cal.startOfDay(for: $0.createdAt) }).sorted(by: >)
        guard let latest = days.first else { return 0 }

        // Check if today or yesterday has activity (streak must be current)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        guard latest >= yesterday else { return 0 }

        var streak = 1
        for i in 1..<days.count {
            let expected = cal.date(byAdding: .day, value: -1, to: days[i - 1])!
            if cal.isDate(days[i], inSameDayAs: expected) {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    /// Count of translations in current period
    private var translationsCount: Int {
        current.filter { $0.translatedTo != nil }.count
    }

    /// Words per minute average
    private var wpm: Int {
        let totalWords = stats.words
        let totalMinutes = stats.audio / 60.0
        guard totalMinutes > 0 else { return 0 }
        return Int(Double(totalWords) / totalMinutes)
    }

    /// Popular hour (0-23) for transcriptions
    private var popularHour: Int {
        let cal = Calendar.current
        var counts = [Int: Int]()
        for item in current {
            let hour = cal.component(.hour, from: item.createdAt)
            counts[hour, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0
    }

    /// Best day stats
    private var bestDay: (count: Int, date: String) {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        var days = [Date: Int]()
        for item in current {
            let day = cal.startOfDay(for: item.createdAt)
            days[day, default: 0] += 1
        }
        guard let best = days.max(by: { $0.value < $1.value }) else { return (0, "—") }
        return (best.value, fmt.string(from: best.key))
    }

    /// Longest streak ever (not just current)
    private var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(allItems.map { cal.startOfDay(for: $0.createdAt) }).sorted()
        guard !days.isEmpty else { return 0 }

        var maxStreak = 1
        var currentStreak = 1
        for i in 1..<days.count {
            let expected = cal.date(byAdding: .day, value: 1, to: days[i - 1])!
            if cal.isDate(days[i], inSameDayAs: expected) {
                currentStreak += 1
                maxStreak = max(maxStreak, currentStreak)
            } else {
                currentStreak = 1
            }
        }
        return maxStreak
    }

    /// Peak words date
    private var peakWordsDay: String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        var days = [Date: Int]()
        for item in current {
            let day = cal.startOfDay(for: item.createdAt)
            days[day, default: 0] += item.wordCount
        }
        guard let best = days.max(by: { $0.value < $1.value }) else { return "—" }
        return fmt.string(from: best.key)
    }

    // MARK: - Period Switcher

    private var periodSwitcher: some View {
        HStack(spacing: 0) {
            periodTab("ALL TIME", period: .allTime)
            periodTab("TODAY", period: .today)
            periodTab("THIS WEEK", period: .week)
            ForEach(availableMonths, id: \.self) { period in
                periodTab(period.label.uppercased(), period: period)
            }
        }
    }

    private func periodTab(_ label: String, period: StatPeriod) -> some View {
        Text(label)
            .font(MW.label).tracking(1.2)
            .foregroundStyle(selectedPeriod == period ? .black : MW.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MW.sp8)
            .background(selectedPeriod == period ? Color.white : MW.surface)
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { selectedPeriod = period }
            }
    }

    private var availableMonths: [StatPeriod] {
        let cal = Calendar.current
        let months = Set(allItems.compactMap { cal.dateInterval(of: .month, for: $0.createdAt)?.start })
        return Array(months.sorted(by: >).prefix(6).map { .month($0) })
    }

    // MARK: - Activity Chart

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            HStack(spacing: MW.sp8) {
                Text(selectedMetric).mwBadge()
                Spacer()
                ForEach(["DAYS", "WEEKS", "MONTHS"], id: \.self) { s in
                    Text(s)
                        .font(MW.label).tracking(1.0)
                        .foregroundStyle(chartScale == s ? .black : MW.textSecondary)
                        .padding(.horizontal, MW.sp8).padding(.vertical, 3)
                        .background(chartScale == s ? Color.white : .clear)
                        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) { chartScale = s }
                        }
                }
            }

            ActivityChartView(items: allItems, scale: chartScale, metric: selectedMetric)
                .frame(height: 120)

            Spacer(minLength: 0)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    // MARK: - Hours Usage Chart

    private var hoursChart: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("HOURS USAGE").mwBadge()

            Chart(hourlyData, id: \.hour) { item in
                BarMark(
                    x: .value("Hour", "\(item.hour)"),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(
                    item.hour == popularHour
                        ? MW.textPrimary.opacity(0.9) : MW.textPrimary.opacity(0.35)
                )
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
                AxisMarks(values: [0, 4, 8, 12, 16, 20].map { "\($0)" }) { _ in
                    AxisValueLabel().foregroundStyle(MW.textMuted).font(MW.monoSm)
                }
            }
            .frame(height: 80)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    private var hourlyData: [(hour: Int, count: Int)] {
        let cal = Calendar.current
        var counts = [Int: Int]()
        for item in current {
            let hour = cal.component(.hour, from: item.createdAt)
            counts[hour, default: 0] += 1
        }
        return (0..<24).map { (hour: $0, count: counts[$0, default: 0]) }
    }

    // MARK: - Top Words

    private var topWordsSection: some View {
        let text = current.map(\.text).joined(separator: " ")
        let top = TextAnalyzer.wordFrequency(in: text, top: 10)
        return VStack(alignment: .leading, spacing: MW.sp8) {
            Text("POPULAR WORDS").mwBadge()

            if top.isEmpty {
                Text("Not enough data").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                ForEach(top, id: \.word) { item in
                    HStack(spacing: MW.sp8) {
                        Text(item.word).font(MW.mono).foregroundStyle(MW.textPrimary)
                            .frame(width: 70, alignment: .leading)
                        GeometryReader { geo in
                            let maxC = top.first?.count ?? 1
                            let w = geo.size.width * CGFloat(item.count) / CGFloat(maxC)
                            Rectangle().fill(MW.textSecondary.opacity(0.3)).frame(width: w)
                        }.frame(height: 10)
                        Text("\(item.count)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    // MARK: - Filler Words

    private var fillerSection: some View {
        let text = current.map(\.text).joined(separator: " ")
        let fillers = TextAnalyzer.fillerWords(in: text)
        return VStack(alignment: .leading, spacing: MW.sp8) {
            Text("FILLER WORDS").mwBadge()

            if fillers.isEmpty {
                Text("No fillers detected").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(fillers.prefix(15), id: \.word) { item in
                        HStack(spacing: 4) {
                            Text(item.word).font(MW.monoSm).foregroundStyle(MW.textPrimary)
                            Text("\(item.count)").font(MW.monoSm).foregroundStyle(MW.textMuted)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().stroke(MW.border, lineWidth: MW.hairline))
                    }
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    // MARK: - Auto-Corrections

    private var correctionsSection: some View {
        let corrections = CorrectionDictionary.shared.corrections
        let sorted = corrections.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: MW.sp8) {
            Text("AUTO-CORRECTIONS").mwBadge()

            if sorted.isEmpty {
                Text("No corrections yet").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                ForEach(sorted.prefix(8), id: \.key) { original, replacement in
                    HStack(spacing: 6) {
                        Text(original)
                            .font(MW.monoSm).foregroundStyle(MW.textMuted)
                            .strikethrough(color: MW.textMuted)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(MW.border)
                        Text(replacement.isEmpty ? "—" : replacement)
                            .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                        Spacer()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    // MARK: - Records

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            Text("RECORDS").mwBadge()

            if let longest = current.max(by: { $0.wordCount < $1.wordCount }) {
                recordItem("Max Words in One", "\(longest.wordCount)")
            }
            if let fastest = current.min(by: { $0.processingTime < $1.processingTime }),
               fastest.processingTime > 0 {
                recordItem("Fastest Processing", String(format: "%.2fs", fastest.processingTime))
            }
            if let maxAudio = current.max(by: { $0.audioDuration < $1.audioDuration }) {
                recordItem("Longest Recording", StatFormatters.duration(maxAudio.audioDuration))
            }

            let best = bestDay
            if best.count > 0 {
                recordItem("Best Day", "\(best.count) recs · \(best.date)")
            }

            recordItem("Peak Words Date", peakWordsDay)
            recordItem("Popular Time", {
                let h = popularHour % 12
                let suffix = popularHour >= 12 ? "PM" : "AM"
                return "\(h == 0 ? 12 : h) \(suffix)"
            }())
            recordItem("Best Streak", "\(longestStreak) days")

            Spacer(minLength: 0)
        }
        .padding(MW.sp24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    private func recordItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(MW.monoLg).foregroundStyle(MW.textPrimary)
            Text(label.uppercased()).font(MW.monoSm).foregroundStyle(MW.textMuted).tracking(0.5)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MW.sp12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(MW.textMuted)
            Text("NO DATA YET")
                .font(MW.label).tracking(2).foregroundStyle(MW.textMuted)
            Text("Press Right \u{2318} to start recording")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MW.bg)
    }

    // MARK: - Helpers

    private func fmtNum(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return "\(n)"
    }

    private func fmtDuration(_ seconds: Double) -> String {
        StatFormatters.duration(seconds)
    }

    private func sharePeriodStats() {
        let s = PeriodStats(current)
        let period = selectedPeriod == .allTime ? "All Time" : selectedPeriod.label
        let text = """
        MetaWhisp Stats (\(period))
        Transcriptions: \(s.count) | Translations: \(translationsCount)
        Words: \(s.words) | Avg: \(s.avgWords)/transcription | WPM: \(wpm)
        Audio: \(StatFormatters.duration(s.audio)) | Saved: \(StatFormatters.duration(s.saved))
        Filler words: \(String(format: "%.1f%%", s.fillerPct)) of speech
        Streak: \(streakDays) days | Best streak: \(longestStreak) days
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Big Metric Tile

private struct BigMetricTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            Text(value).font(MW.monoTitle).foregroundStyle(MW.textPrimary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(label).mwBadge().lineLimit(1)
                if let unit {
                    Text(unit.uppercased()).font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(1)
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 80)
        .contentShape(Rectangle())
        .background(isSelected ? MW.elevated : MW.surface)
        .overlay(
            HStack(spacing: 0) {
                if isSelected {
                    Rectangle().fill(MW.textPrimary).frame(width: 2)
                }
                Spacer(minLength: 0)
            }
        )
        .overlay(Rectangle().stroke(isSelected ? MW.borderLight : MW.border, lineWidth: MW.hairline))
    }
}
