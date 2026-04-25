import SwiftData
import SwiftUI

/// Dashboard — BLOCKS-styled status strip + full statistics below.
struct DashboardView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator

    /// Min available width to keep the 2-column layout. Below this threshold the
    /// right-column cards stack vertically under DailySummaryCard. Picked based on
    /// (DailySummaryCard min usable ≈ 380) + (12 spacing) + (right col 280) +
    /// (24 outer padding) = ~696 → round up to 720 for breathing room.
    private static let twoColumnThreshold: CGFloat = 720

    var body: some View {
        // GeometryReader exposes the actual available width so layout adapts to the
        // window size. ScrollView previously clipped the right column when the user
        // resized the window narrower than the fixed 280pt right column needed.
        GeometryReader { geo in
            let isWide = geo.size.width >= Self.twoColumnThreshold
            ScrollView {
                VStack(spacing: MW.sp12) {
                    // Screen title + compact status strip. On wide layout the strip
                    // sits to the right of the title at fixed 280pt; on narrow it
                    // wraps under the title to avoid pushing the title off-screen.
                    if isWide {
                        HStack(alignment: .center, spacing: MW.sp12) {
                            Text("Dashboard")
                                .font(MW.monoTitle)
                                .foregroundStyle(MW.textPrimary)
                            Spacer()
                            statusStrip
                                .frame(width: 280)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: MW.sp8) {
                            Text("Dashboard")
                                .font(MW.monoTitle)
                                .foregroundStyle(MW.textPrimary)
                            statusStrip
                                .frame(maxWidth: .infinity)
                        }
                    }

                    // ITER-022 G_dashboard v2 — Square day-picker (h-scroll) + click-driven
                    // detail card. Picker is fixed height (84pt); detail grows by content.
                    DailySummaryCarousel()

                    // Stats row under the carousel — 2 split when wide, stacked when narrow.
                    if geo.size.width >= 480 {
                        HStack(alignment: .top, spacing: MW.sp12) {
                            TodayStatsCard()
                                .frame(maxWidth: .infinity)
                            ScreenActivityCard()
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        TodayStatsCard()
                        ScreenActivityCard()
                    }

                    StatisticsView()
                }
                .padding(.top, MW.sp4)
                .padding(MW.sp12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(spacing: MW.sp12) {
            Circle()
                .fill(MW.stateColor(coordinator.stage.rawValue))
                .frame(width: 6, height: 6)
                .shadow(color: MW.stateColor(coordinator.stage.rawValue).opacity(0.5), radius: 4)

            Text(statusLabel.uppercased())
                .font(MW.label).tracking(1.5)
                .foregroundStyle(coordinator.stage == .idle ? MW.textSecondary : MW.textPrimary)

            Spacer()

            Button {
                coordinator.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: coordinator.stage == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(coordinator.stage == .recording ? "STOP" : "RECORD")
                        .font(MW.label).tracking(0.5)
                }
                .foregroundStyle(coordinator.stage == .recording ? (MW.isDark ? .white : .white) : MW.textSecondary)
                .padding(.horizontal, MW.sp12).padding(.vertical, MW.sp8)
                .background {
                    if coordinator.stage == .recording {
                        RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .fill(Color.red.opacity(0.85))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)
        }
        .padding(.horizontal, MW.sp16).padding(.vertical, MW.sp12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    private var statusLabel: String {
        switch coordinator.stage {
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .postProcessing: coordinator.translateNext ? "Translating" : "Processing"
        case .idle: "Ready"
        }
    }
}

// MARK: - Screen Activity Card (last 24h top apps)

/// Groups `ScreenObservation` rows from the last 24h by app name, sums durations,
/// renders top-5 as a horizontal strip. Empty state prompts enabling Screen Context.
/// spec://iterations/ITER-003-screen-aware-intelligence#scope.4
private struct ScreenActivityCard: View {
    /// Filtered query — only last 24h. Without this predicate the @Query loaded
    /// EVERY ScreenContext row (30s polling × multiple days = thousands of rows)
    /// causing the Dashboard to lag for seconds on every render. With the
    /// predicate SwiftData fetches only the relevant slice (≈ 2880 max for
    /// 24h × 60 min × 2 samples/min), and re-evaluates only when timestamps
    /// inside the window change.
    @Query private var contexts: [ScreenContext]

    init() {
        let cutoff = Date().addingTimeInterval(-86400)
        _contexts = Query(
            filter: #Predicate<ScreenContext> { $0.timestamp >= cutoff },
            sort: [SortDescriptor(\.timestamp, order: .forward)]
        )
    }

    /// Top-5 apps by on-screen seconds in the last 24h, with percent share of top-5 total.
    /// Duration estimation: each ScreenContext owns the gap to the next sample, capped
    /// at 5 min so idle (sleep / locked) doesn't inflate totals.
    private var topApps: [(appName: String, seconds: Double, percent: Int)] {
        guard contexts.count >= 2 else { return [] }
        let maxGap: TimeInterval = 300
        var byApp: [String: Double] = [:]
        for i in 0..<(contexts.count - 1) {
            let c = contexts[i]
            let next = contexts[i + 1]
            let gap = min(next.timestamp.timeIntervalSince(c.timestamp), maxGap)
            guard gap > 0 else { continue }
            byApp[c.appName, default: 0] += gap
        }
        let sorted = byApp.map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        let total = sorted.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return sorted.map { item in
            (appName: item.0, seconds: item.1, percent: Int((item.1 / total * 100).rounded()))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            HStack {
                Text("LAST 24H ON SCREEN").mwBadge()
                Spacer()
                if !topApps.isEmpty {
                    Text("Top \(topApps.count)")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
            }

            if topApps.isEmpty {
                Text("No screen activity yet")
                    .font(MW.mono).foregroundStyle(MW.textMuted)
                    .padding(.vertical, MW.sp4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(topApps.enumerated()), id: \.offset) { idx, app in
                        appRow(app)
                        if idx < topApps.count - 1 { GlassDivider() }
                    }
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func appRow(_ app: (appName: String, seconds: Double, percent: Int)) -> some View {
        HStack(spacing: MW.sp10) {
            Text(app.appName)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(durationLabel(app.seconds))
                .font(MW.dataMedium)
                .foregroundStyle(MW.textPrimary)
                .frame(width: 56, alignment: .trailing)
            Text("\(app.percent)%")
                .font(MW.dataSmall)
                .foregroundStyle(MW.textMuted)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.vertical, MW.sp8)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }
}

/// Compact tile — a level lighter than `BigMetricTile` since this is secondary info
/// (top-5 strip, not a primary dashboard metric). Height 52 vs 80, `monoLg` vs `monoTitle`.
/// Percent sits inline on the same baseline as duration.
private struct ScreenAppTile: View {
    let appName: String
    let seconds: Double
    let percent: Int

    var body: some View {
        HStack(spacing: MW.sp8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(durationLabel)
                        .font(MW.monoLg).foregroundStyle(MW.textPrimary)
                        .lineLimit(1)
                    Text("\(percent)%")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                Text(appName.uppercased())
                    .font(MW.label).tracking(1.0)
                    .foregroundStyle(MW.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MW.sp12).padding(.vertical, MW.sp8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    /// "3h 12m" / "47m" / "42s".
    private var durationLabel: String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }
}

/// Blank slot that preserves grid alignment when fewer than 5 apps tracked.
/// Height matches `ScreenAppTile` (52pt — compact supplementary row, not BigMetricTile).
private struct EmptyTile: View {
    var body: some View {
        Rectangle()
            .fill(MW.surface.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
    }
}

// MARK: - Daily Summary Card (ITER-009)

/// Dashboard card — today's LLM recap (title + overview + bullets).
/// Numeric breakdown lives in `TodayStatsCard` (right column) for layout balance.
private struct DailySummaryCard: View {
    @Query(sort: \DailySummary.date, order: .reverse)
    private var summaries: [DailySummary]

    @ObservedObject private var settings = AppSettings.shared
    @State private var isGenerating = false

    private var todaysSummary: DailySummary? {
        guard let latest = summaries.first else { return nil }
        return Calendar.current.isDateInToday(latest.date) ? latest : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            header
            if let s = todaysSummary {
                summaryBody(for: s)
            } else {
                emptyPlaceholder
            }
        }
        .padding(MW.sp20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var header: some View {
        HStack {
            Text("TODAY'S SUMMARY").mwBadge()
            Spacer()
            if todaysSummary != nil {
                Text(scheduledTimeLabel)
                    .font(MW.dataSmall).foregroundStyle(MW.textMuted)
            }
            Button(action: generateNow) {
                HStack(spacing: 4) {
                    if isGenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 10))
                    }
                    Text(isGenerating ? "GENERATING…" : "GENERATE NOW")
                        .font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .glassChip(selected: false, radius: MW.rTiny)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
        }
    }

    @ViewBuilder
    private func summaryBody(for s: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: MW.sp20) {
            // Headline — theme of the day, 1 line.
            Text(s.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Four sections, each rendered only when LLM produced content.
            // Empty sections never render — empty space is intentional, not padding.
            section(label: "Learned", icon: "lightbulb", items: s.learned)
            section(label: "Decided", icon: "checkmark.circle", items: s.decided)
            section(label: "Shipped", icon: "shippingbox", items: s.shipped)

            // Energy — qualitative one-liner about day quality.
            let energy = (s.energy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !energy.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MW.textMuted)
                    Text(energy)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MW.textMuted)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, MW.sp4)
            }
        }
    }

    @ViewBuilder
    private func section(label: String, icon: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: MW.sp8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MW.textMuted)
                    Text(label.uppercased())
                        .font(MW.label).tracking(1.2)
                        .foregroundStyle(MW.textMuted)
                }
                VStack(alignment: .leading, spacing: MW.sp6) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(MW.textDim).frame(width: 4, height: 4).padding(.top, 8)
                            Text(item)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(MW.textSecondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        Text(settings.dailySummaryEnabled
             ? "Recap will generate at \(scheduledTimeLabel) (or click GENERATE NOW)."
             : "Daily summary is off. Enable in Settings → AI.")
            .font(MW.mono).foregroundStyle(MW.textMuted)
    }

    private var scheduledTimeLabel: String {
        String(format: "%02d:%02d", settings.dailySummaryHour, settings.dailySummaryMinute)
    }

    private func generateNow() {
        isGenerating = true
        Task { @MainActor in
            _ = await AppDelegate.shared?.dailySummaryService.generateNow()
            isGenerating = false
        }
    }
}

// MARK: - Daily Summary Day-Picker + Detail (ITER-022 G_dashboard v2)

/// Square day-picker row + click-driven detail card.
///
/// Replaces the swipe-carousel v1 (user feedback: «карточки должны быть
/// квадратные и переключаться по клику не по свайпу»).
///
/// Layout:
///   [Apr 14][Apr 15]...[Apr 24][TODAY][TOMORROW]   ← square 80×80 picker (h-scroll)
///   ┌─────────────────────────────────────────┐
///   │   Detail card for selectedDay           │
///   └─────────────────────────────────────────┘
///
/// State: `selectedDay` defaults to today, click on any picker tile updates.
/// Detail card re-renders via @State binding.
///
/// spec://iterations/ITER-022-G-dashboard
private struct DailySummaryCarousel: View {
    @Query(sort: \DailySummary.date, order: .reverse)
    private var allSummaries: [DailySummary]

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Days to render in the picker — 14 past + today + tomorrow.
    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-13...1).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private func summary(for date: Date) -> DailySummary? {
        let cal = Calendar.current
        return allSummaries.first { cal.isDate($0.date, inSameDayAs: date) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            // Picker row — square 80×80 mini-cards, h-scroll.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            MiniDayTile(
                                date: day,
                                summary: summary(for: day),
                                isSelected: Calendar.current.isDate(selectedDay, inSameDayAs: day),
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedDay = Calendar.current.startOfDay(for: day)
                                    }
                                }
                            )
                            .id(day)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 84)
                .onAppear {
                    // Center today on first appear.
                    proxy.scrollTo(Calendar.current.startOfDay(for: Date()), anchor: .center)
                }
            }

            // Detail card for selected day.
            DetailCard(date: selectedDay, summary: summary(for: selectedDay))
                .frame(maxWidth: .infinity)
        }
    }
}

/// Square 80×80 mini-tile shown in the day-picker row.
/// Visual: date text + status icon. Selected has filled bg + accent border.
private struct MiniDayTile: View {
    let date: Date
    let summary: DailySummary?
    let isSelected: Bool
    let onTap: () -> Void

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(date) }
    private var isFuture: Bool { date > cal.startOfDay(for: Date()) }
    private var hasSummary: Bool { summary != nil }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(dayLabel)
                    .font(MW.label).tracking(0.8)
                    .foregroundStyle(labelColor)
                Text(dateLabel)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(MW.textPrimary)
                Image(systemName: statusIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                    .fill(isSelected ? MW.elevated : MW.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                    .stroke(isSelected ? MW.textPrimary.opacity(0.5) : MW.border, lineWidth: isSelected ? 1.2 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var dayLabel: String {
        if isToday { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YEST" }
        if cal.isDateInTomorrow(date) { return "TMRW" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private var labelColor: Color {
        isToday ? MW.textPrimary : MW.textMuted
    }

    private var statusIcon: String {
        if isFuture { return "moon.zzz" }
        if hasSummary { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if isFuture { return MW.textMuted }
        if hasSummary { return MW.textSecondary }
        return MW.textMuted.opacity(0.5)
    }
}

/// Full-width detail card that renders the selected day's summary (or empty
/// state). Click GENERATE for retroactive generation on past empty days.
private struct DetailCard: View {
    let date: Date
    let summary: DailySummary?

    @ObservedObject private var settings = AppSettings.shared
    @State private var isGenerating = false
    @State private var localSummary: DailySummary?

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(date) }
    private var isFuture: Bool { date > cal.startOfDay(for: Date()) }
    private var effectiveSummary: DailySummary? { localSummary ?? summary }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            header
            content
        }
        .padding(MW.sp20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dayLabel)
                .font(MW.label).tracking(1.2)
                .foregroundStyle(isToday ? MW.textPrimary : MW.textMuted)
            Text(dateLabel)
                .font(MW.dataSmall).foregroundStyle(MW.textMuted)
            Spacer()
            if isFuture {
                Text("scheduled \(scheduledTimeLabel)")
                    .font(MW.dataSmall).foregroundStyle(MW.textMuted)
            } else {
                generateButton
            }
        }
    }

    private var generateButton: some View {
        Button(action: generate) {
            HStack(spacing: 4) {
                if isGenerating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: effectiveSummary == nil ? "sparkles" : "arrow.clockwise")
                        .font(.system(size: 10))
                }
                Text(isGenerating ? "GENERATING…"
                     : (effectiveSummary == nil ? "GENERATE" : "REGENERATE"))
                    .font(MW.label).tracking(0.6)
            }
            .foregroundStyle(MW.textSecondary)
            .glassChip(selected: false, radius: MW.rTiny)
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    @ViewBuilder
    private var content: some View {
        if isFuture {
            futurePlaceholder
        } else if let s = effectiveSummary {
            summaryRender(for: s)
        } else {
            emptyPlaceholder
        }
    }

    @ViewBuilder
    private func summaryRender(for s: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            Text(s.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            section(label: "Learned", icon: "lightbulb", items: s.learned)
            section(label: "Decided", icon: "checkmark.circle", items: s.decided)
            section(label: "Shipped", icon: "shippingbox", items: s.shipped)
            let energy = (s.energy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !energy.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MW.textMuted)
                    Text(energy)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MW.textMuted)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, MW.sp4)
            }
        }
    }

    @ViewBuilder
    private func section(label: String, icon: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: MW.sp6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MW.textMuted)
                    Text(label.uppercased())
                        .font(MW.label).tracking(1.2)
                        .foregroundStyle(MW.textMuted)
                }
                VStack(alignment: .leading, spacing: MW.sp4) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(MW.textDim).frame(width: 3, height: 3).padding(.top, 7)
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundStyle(MW.textSecondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isToday
                 ? (settings.dailySummaryEnabled
                    ? "Recap will generate at \(scheduledTimeLabel) — or tap GENERATE."
                    : "Daily summary is off. Enable in Settings → AI.")
                 : "No summary recorded for this day. Tap GENERATE to build one from saved data.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
    }

    private var futurePlaceholder: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 26))
                .foregroundStyle(MW.textMuted)
            Text("Tomorrow's recap will appear at \(scheduledTimeLabel)")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var dayLabel: String {
        if isToday { return "TODAY'S SUMMARY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        return "\(days) DAYS AGO"
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private var scheduledTimeLabel: String {
        String(format: "%02d:%02d", settings.dailySummaryHour, settings.dailySummaryMinute)
    }

    private func generate() {
        isGenerating = true
        Task { @MainActor in
            let result = await AppDelegate.shared?.dailySummaryService.generateForDate(date)
            localSummary = result
            isGenerating = false
        }
    }
}

// MARK: - Today Stats Card (right column)

/// Compact 2x2 grid of today's counts: Conversations / Memories / Done / New tasks.
/// Reads from latest `DailySummary`; if no summary today, shows zeros.
/// Splits the previously-cramped horizontal stat row out of `DailySummaryCard`.
private struct TodayStatsCard: View {
    @Query(sort: \DailySummary.date, order: .reverse)
    private var summaries: [DailySummary]

    private var todays: DailySummary? {
        guard let latest = summaries.first else { return nil }
        return Calendar.current.isDateInToday(latest.date) ? latest : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            Text("TODAY").mwBadge()
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: MW.sp8),
                          GridItem(.flexible(), spacing: MW.sp8)],
                spacing: MW.sp8
            ) {
                stat(value: todays?.conversationCount ?? 0, label: "Convos")
                stat(value: todays?.memoriesAdded ?? 0, label: "Memories")
                stat(value: todays?.tasksCompleted ?? 0, label: "Done")
                stat(value: todays?.tasksCreated ?? 0, label: "New tasks")
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func stat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(MW.dataLarge)
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(MW.label).tracking(0.8)
                .foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MW.sp10)
        .background {
            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous))
    }
}
