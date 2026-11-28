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

    // Cached expensive text analyses — recomputed off-main-thread via .task(id:).
    // Previously `topWordsSection` / `fillerSection` joined ALL history text (3k+
    // items = multi-MB string) and scanned it on every render, which froze the
    // Dashboard. Now the heavy work runs once per period change + data update.
    @State private var topWordsCache: [(word: String, count: Int)] = []
    @State private var fillersCache: [(word: String, count: Int)] = []
    @State private var textStatsReady = false

    /// Cached non-text derived stats. Each property below previously did a full
    /// O(N) scan of `current` or `allItems` (Calendar.startOfDay inside a tight
    /// loop on 3500+ rows = many thousand date ops PER RENDER FRAME). Sample
    /// profiler caught `bestDay`/`peakWordsDay` accounting for the bulk of
    /// main-thread CPU after the fillerCount fix landed.
    /// Now they're computed once per (allItems.count, selectedPeriod) change in
    /// `recomputeDerivedStats()` and read from this struct.
    @State private var derivedCache: DerivedStats = .empty
    @State private var currentCache: [HistoryItem] = []
    @State private var previousCache: [HistoryItem] = []

    /// Pure-data bundle of derived non-text stats. Populated off the main path.
    struct DerivedStats {
        let streakDays: Int
        let translationsCount: Int
        let wpm: Int
        let popularHour: Int
        let bestDay: (count: Int, date: String)
        let peakWordsDay: String
        let longestStreak: Int
        static let empty = DerivedStats(
            streakDays: 0, translationsCount: 0, wpm: 0, popularHour: 0,
            bestDay: (0, "—"), peakWordsDay: "—", longestStreak: 0
        )
    }

    /// Read access — UI reads these instead of the heavy computed getters below.
    private var current: [HistoryItem] { currentCache }
    private var previous: [HistoryItem] { previousCache }

    /// Spacing between glass tiles. BLOCKS used 2pt so tiles touched edge-to-edge
    /// with hairline strokes — for glass we need breathing room or the materials
    /// blur into one another.
    private let gap: CGFloat = 12

    var body: some View {
        content
            .task(id: "\(selectedPeriod.label)-\(allItems.count)") {
                // Run BOTH the text-analysis cache AND the date/calendar derived
                // cache off the render path. Order matters minimally; just don't
                // serialize them needlessly — `async let` would be nice but text
                // stats already use Task internally; keep simple sequence here.
                recomputeFilteredItems()
                await recomputeTextStats()
                await recomputeDerivedStats()
            }
    }

    /// Pre-filter `current`/`previous` once per period change so the body
    /// doesn't re-run `selectedPeriod.filter(allItems)` on every render frame.
    private func recomputeFilteredItems() {
        currentCache = selectedPeriod.filter(allItems)
        previousCache = selectedPeriod.previousFilter(allItems)
    }

    /// Compute every Calendar-heavy derived stat in one sweep, off the render path.
    /// Uses Task.detached so the calendar work doesn't block main even if SwiftUI
    /// is mid-render. Capture-by-value of `allItems` is OK — copies are cheap (just
    /// pointers under the hood) and we read read-only.
    private func recomputeDerivedStats() async {
        let items = allItems
        let curr = currentCache
        let computed = await Task.detached(priority: .utility) { () -> DerivedStats in
            let cal = Calendar.current
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"

            // --- streakDays ---
            let allDays = Set(items.map { cal.startOfDay(for: $0.createdAt) }).sorted(by: >)
            var streakDays = 0
            // AUD — never force-unwrap Calendar arithmetic: cal.date(byAdding:) is
            // legitimately Optional (returns nil on edge-case/corrupt dates) and
            // force-unwrapping it traps the whole app. Skip gracefully instead.
            if let latest = allDays.first,
               let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) {
                if latest >= yesterday {
                    streakDays = 1
                    // stride (not 1..<count) so an empty/one-element array can't form
                    // an invalid `1..<0` Range and trap.
                    for i in stride(from: 1, to: allDays.count, by: 1) {
                        guard let expected = cal.date(byAdding: .day, value: -1, to: allDays[i - 1]) else { break }
                        if cal.isDate(allDays[i], inSameDayAs: expected) { streakDays += 1 }
                        else { break }
                    }
                }
            }

            // --- longestStreak (over all-time) ---
            let asc = allDays.reversed().map { $0 }
            var maxStreak = asc.isEmpty ? 0 : 1
            var run = 1
            // stride so an empty `asc` (e.g. @Query not yet loaded) can't form an
            // invalid `1..<0` Range and trap the whole app.
            for i in stride(from: 1, to: asc.count, by: 1) {
                guard let expected = cal.date(byAdding: .day, value: 1, to: asc[i - 1]) else { run = 1; continue }
                if cal.isDate(asc[i], inSameDayAs: expected) {
                    run += 1; if run > maxStreak { maxStreak = run }
                } else { run = 1 }
            }

            // --- translationsCount on current ---
            let translationsCount = curr.filter { $0.translatedTo != nil }.count

            // --- wpm on current ---
            let words = curr.reduce(0) { $0 + $1.wordCount }
            let audio = curr.reduce(0) { $0 + $1.audioDuration }
            let mins = audio / 60.0
            // Guard the Double->Int conversion: Int(non-finite or out-of-range) traps.
            let rawWpm = mins > 0 ? Double(words) / mins : 0
            let wpm = (rawWpm.isFinite && rawWpm >= 0 && rawWpm < Double(Int.max)) ? Int(rawWpm) : 0

            // --- popularHour on current ---
            var hourCounts = [Int: Int]()
            for item in curr {
                hourCounts[cal.component(.hour, from: item.createdAt), default: 0] += 1
            }
            let popularHour = hourCounts.max(by: { $0.value < $1.value })?.key ?? 0

            // --- bestDay (count) on current ---
            var dayCounts = [Date: Int]()
            for item in curr { dayCounts[cal.startOfDay(for: item.createdAt), default: 0] += 1 }
            let best = dayCounts.max(by: { $0.value < $1.value })
            let bestDay: (Int, String) = best.map { ($0.value, fmt.string(from: $0.key)) } ?? (0, "—")

            // --- peakWordsDay on current ---
            var dayWords = [Date: Int]()
            for item in curr { dayWords[cal.startOfDay(for: item.createdAt), default: 0] += item.wordCount }
            let peak = dayWords.max(by: { $0.value < $1.value })
            let peakWordsDay = peak.map { fmt.string(from: $0.key) } ?? "—"

            return DerivedStats(
                streakDays: streakDays,
                translationsCount: translationsCount,
                wpm: wpm,
                popularHour: popularHour,
                bestDay: bestDay,
                peakWordsDay: peakWordsDay,
                longestStreak: maxStreak
            )
        }.value
        derivedCache = computed
    }

    @ViewBuilder
    private var content: some View {
        if allItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: gap) {
                    periodSwitcher

                    // Row 1: the tiles and the chart, with RECORDS beside them while there is room, under them below.
                    let topLayout = statsWidth >= Self.recordsBesideFrom
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: gap))
                        : AnyLayout(VStackLayout(spacing: gap))
                    topLayout {
                        VStack(spacing: gap) {
                            if statsWidth >= Self.tileRowsFrom {
                                HStack(spacing: gap) { firstTiles }
                                // Row 2: WPM | SAVED TIME | RECORDED
                                HStack(spacing: gap) { secondTiles }
                            } else {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)],
                                          spacing: gap) {
                                    firstTiles
                                    secondTiles
                                }
                            }

                            // Metric chart
                            activityChart
                        }

                        // Records column on the right
                        if statsWidth >= Self.recordsBesideFrom {
                            recordsSection.frame(width: 260)
                        } else {
                            recordsSection
                        }
                    }

                    // Hours Usage chart
                    hoursChart

                    // Bottom sections: POPULAR WORDS + FILLER WORDS + AUTO-CORRECTIONS, stacked when narrow.
                    let bottomLayout = statsWidth >= Self.bottomBesideFrom
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: gap))
                        : AnyLayout(VStackLayout(spacing: gap))
                    bottomLayout {
                        topWordsSection
                        VStack(spacing: gap) {
                            fillerSection
                            correctionsSection
                        }
                    }
                }
                .padding(gap)
            }
            // Flips the layouts only when the width crosses a line, not on every pixel of a resize.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width >= Self.recordsBesideFrom ? Self.recordsBesideFrom
                    : proxy.size.width >= Self.bottomBesideFrom ? Self.bottomBesideFrom
                    : proxy.size.width >= Self.tileRowsFrom ? Self.tileRowsFrom : 0
            } action: { band in
                if band != statsWidth { statsWidth = band }
            }
            // Share via context menu instead of toolbar button
        }
    }

    /// The width band the statistics are laid out for (one of the lines below, or 0 under the narrowest).
    @State private var statsWidth: CGFloat = 720
    /// RECORDS beside the tiles from this width; under them below it.
    private static let recordsBesideFrom: CGFloat = 720
    /// POPULAR WORDS beside FILLER WORDS from this width.
    private static let bottomBesideFrom: CGFloat = 560
    /// The tiles in their two rows (four, then three) from this width; two to a row below it.
    private static let tileRowsFrom: CGFloat = 520

    @ViewBuilder private var firstTiles: some View {
        BigMetricTile(
            label: "Streak", value: "\(streakDays)",
            unit: "days"
        )

        BigMetricTile(
            label: "Words", value: fmtNum(stats.words),
            unit: "total", isSelected: selectedMetric == "WORDS"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "WORDS" } }

        BigMetricTile(
            label: "Transcriptions", value: fmtNum(current.count),
            unit: "total", isSelected: selectedMetric == "TRANSCRIPTIONS"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "TRANSCRIPTIONS" } }

        BigMetricTile(
            label: "Translations", value: fmtNum(translationsCount),
            unit: "total", isSelected: selectedMetric == "TRANSLATIONS"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "TRANSLATIONS" } }
    }

    @ViewBuilder private var secondTiles: some View {
        BigMetricTile(
            label: "Words per minute", value: "\(wpm)",
            unit: "avg", isSelected: selectedMetric == "WPM"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "WPM" } }

        BigMetricTile(
            label: "Saved time", value: fmtDuration(stats.saved),
            isSelected: selectedMetric == "SAVED TIME"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "SAVED TIME" } }

        BigMetricTile(
            label: "Recorded", value: fmtDuration(stats.audio),
            unit: "audio", isSelected: selectedMetric == "RECORDED"
        )
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selectedMetric = "RECORDED" } }
    }

    private var stats: PeriodStats { PeriodStats(current) }

    // MARK: - Computed Stats

    // ── Derived stats — read from `derivedCache` (computed off-main in
    //    `recomputeDerivedStats()`). The body must NOT do per-render Calendar
    //    scans; doing so on 3500+ history items froze the Dashboard. The cache
    //    refreshes whenever (allItems.count, selectedPeriod) changes.
    private var streakDays: Int { derivedCache.streakDays }
    private var translationsCount: Int { derivedCache.translationsCount }
    private var wpm: Int { derivedCache.wpm }
    private var popularHour: Int { derivedCache.popularHour }

    private var bestDay: (count: Int, date: String) { derivedCache.bestDay }
    private var longestStreak: Int { derivedCache.longestStreak }
    private var peakWordsDay: String { derivedCache.peakWordsDay }

    // MARK: - Period Switcher

    private var periodSwitcher: some View {
        HStack(spacing: 2) {
            periodTab("All time", period: .allTime)
            periodTab("Today", period: .today)
            periodTab("This week", period: .week)
            ForEach(availableMonths, id: \.self) { period in
                periodTab(period.label, period: period)
            }
        }
        .mwSegmentTrack()
    }

    private func periodTab(_ label: String, period: StatPeriod) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(selectedPeriod == period ? MW.textPrimary : MW.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MW.sp8)
            .mwSelectable(selectedPeriod == period, radius: 999, resting: .none)
            .contentShape(Rectangle())
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
                HStack(spacing: 2) {
                    ForEach(["DAYS", "WEEKS", "MONTHS"], id: \.self) { s in
                        Text(s.capitalized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(chartScale == s ? MW.textPrimary : MW.textSecondary)
                            .padding(.horizontal, MW.sp8).padding(.vertical, 3)
                            .mwSelectable(chartScale == s, radius: 999, resting: .none)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) { chartScale = s }
                            }
                    }
                }
                .mwSegmentTrack()
            }

            ActivityChartView(items: allItems, scale: chartScale, metric: selectedMetric)
                .frame(height: 120)

            Spacer(minLength: 0)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rSmall, elevation: .flat)
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
                .foregroundStyle(item.hour == popularHour ? MW.accent : MW.accent.opacity(0.35))
                .cornerRadius(2)
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
        .mwCard(radius: MW.rSmall, elevation: .flat)
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

    // MARK: - Top Words (cache-backed, recomputed off-main)

    private var topWordsSection: some View {
        let top = topWordsCache
        return VStack(alignment: .leading, spacing: MW.sp8) {
            Text("POPULAR WORDS").mwBadge()

            if !textStatsReady {
                Text("Computing…").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else if top.isEmpty {
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
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    // MARK: - Filler Words (cache-backed)

    private var fillerSection: some View {
        let fillers = fillersCache
        return VStack(alignment: .leading, spacing: MW.sp8) {
            Text("FILLER WORDS").mwBadge()

            if !textStatsReady {
                Text("Computing…").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else if fillers.isEmpty {
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
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    /// Recompute text analyses off the main thread. Runs on first appear, and
    /// whenever the period or dataset size changes. The heavy string-join +
    /// word-counting (multi-MB on 3k+ items) no longer blocks the render path.
    private func recomputeTextStats() async {
        let period = selectedPeriod
        let items = allItems
        let task = Task.detached(priority: .utility) { () -> ([Ref], [Ref]) in
            let filtered = period.filter(items)
            let text = filtered.map(\.text).joined(separator: " ")
            let top = TextAnalyzer.wordFrequency(in: text, top: 10)
                .map { Ref(word: $0.word, count: $0.count) }
            let fill = TextAnalyzer.fillerWords(in: text)
                .map { Ref(word: $0.word, count: $0.count) }
            return (top, fill)
        }
        let (top, fill) = await task.value
        await MainActor.run {
            self.topWordsCache = top.map { ($0.word, $0.count) }
            self.fillersCache = fill.map { ($0.word, $0.count) }
            self.textStatsReady = true
        }
    }

    /// Sendable tuple for cross-actor transfer.
    private struct Ref: Sendable { let word: String; let count: Int }

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
        .mwCard(radius: MW.rSmall, elevation: .flat)
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
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    private func recordItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(MW.monoLg).foregroundStyle(MW.textPrimary)
            Text(label).mwBadge()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MW.sp12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(MW.textMuted)
            Text("No data yet")
                .font(MW.mono).foregroundStyle(MW.textMuted)
            Text("Press Right \u{2318} to start recording")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func fmtNum(_ n: Int) -> String {
        StatFormatters.count(n)
    }

    private func fmtDuration(_ seconds: Double) -> String {
        StatFormatters.duration(seconds)
    }

    private func sharePeriodStats() {
        let s = PeriodStats(current)
        let period = selectedPeriod == .allTime ? "All time" : selectedPeriod.label
        // Filler % computed on-demand from the async-cached fillersCache so we
        // don't trigger a fresh O(N) text scan on the share path either.
        let fillerCount = fillersCache.reduce(0) { $0 + $1.count }
        let fillerPct: Double = s.words > 0 ? Double(fillerCount) / Double(s.words) * 100 : 0
        let text = """
        MetaWhisp Stats (\(period))
        Transcriptions: \(s.count) | Translations: \(translationsCount)
        Words: \(s.words) | Avg: \(s.avgWords)/transcription | WPM: \(wpm)
        Audio: \(StatFormatters.duration(s.audio)) | Saved: \(StatFormatters.duration(s.saved))
        Filler words: \(String(format: "%.1f%%", fillerPct)) of speech
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
        VStack(alignment: .leading, spacing: MW.sp6) {
            Text(label).mwBadge()
            // Numbers — digits of one width for alignment across a row of stats.
            Text(value)
                .font(MW.dataLarge)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let unit {
                Text(unit)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .contentShape(Rectangle())
        .mwSelectable(isSelected, radius: MW.rSmall, resting: .panel)
    }
}
