import AppKit
import EventKit
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
    /// Above this window width the inner cards split their CONTENT into a
    /// second column (TodayCard sections side-by-side, Stats grid + 7-day
    /// chart). Below — single column. ~1240 is roughly "fullscreen on
    /// MacBook Air 13"" — narrower windows keep the dense single-col layout.
    private static let fullscreenThreshold: CGFloat = 1240

    /// Cached responsive flags — flip ONLY when the window crosses a
    /// threshold. Previously a `GeometryReader` wrapping the entire body
    /// invalidated every child on every resize pixel, causing visible lag
    /// when dragging the window edge. `.onGeometryChange` fires on every
    /// size change but our `action` only mutates `@State` on threshold
    /// cross — so SwiftUI re-renders the body twice during a resize
    /// (entering/leaving), not on every frame.
    @State private var isWide: Bool = false
    @State private var isFullscreen: Bool = false

    var body: some View {
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

                // Today + Tomorrow split. Replaces the 14-day carousel — single
                // ‹/› arrows in TodayCard navigate past days while data exists.
                // Left col = TodayCard + (TodayStatsCard | ScreenActivityCard) sub-row;
                // right col = TomorrowCard (calendar events / due tasks; CONNECT button
                // when CalendarReader is off).
                TodayTomorrowSection(isWide: isWide, isFullscreen: isFullscreen)

                StatisticsView()
            }
            .padding(.top, MW.sp4)
            .padding(MW.sp12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            let newWide = width >= Self.twoColumnThreshold
            let newFullscreen = width >= Self.fullscreenThreshold
            if newWide != isWide { isWide = newWide }
            if newFullscreen != isFullscreen { isFullscreen = newFullscreen }
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

    /// Top-5 apps by on-screen seconds in the last 24h — ITER-053.1: the math
    /// lives in `ScreenTimeAggregator` (shared with DailySummary so the two
    /// surfaces can't diverge). Percent is now of TOTAL screen time, not of the
    /// top-5 subset (the old inline math overstated shares).
    private var topApps: [(appName: String, seconds: Double, percent: Int)] {
        ScreenTimeAggregator.topApps(
            samples: contexts.map { (appName: $0.appName, timestamp: $0.timestamp) }
        ).map { (appName: $0.appName, seconds: $0.seconds, percent: $0.percent) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            HStack {
                Text("LAST 24H ON SCREEN").mwBadge()
                Spacer()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// Mockup row: name + accent-tinted bar + duration + percent.
    /// Bar fills proportionally to `percent / topMax`. When `MW.accent` is `mono`
    /// (default) the bar reads as a strong-text bar; when user picks a colored
    /// accent, the strip becomes the accent color across all rows. Per design spec.
    private func appRow(_ app: (appName: String, seconds: Double, percent: Int)) -> some View {
        let topMax = max(topApps.first?.percent ?? 1, 1)
        return HStack(spacing: MW.sp10) {
            Text(app.appName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            // Accent bar — fills (percent / topMax) of the available width.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(MW.subtle)
                        .frame(height: 4)
                    Capsule(style: .continuous)
                        .fill(MW.accent)
                        .frame(width: max(0, geo.size.width * CGFloat(app.percent) / CGFloat(topMax)),
                               height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            Text(durationLabel(app.seconds))
                .font(MW.dataMedium)
                .foregroundStyle(MW.textPrimary)
                .frame(width: 56, alignment: .trailing)
            Text("\(app.percent)%")
                .font(MW.dataSmall)
                .foregroundStyle(MW.textMuted)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.vertical, MW.sp6)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

// MARK: - Today Stats Card (right column)

/// Compact 2x2 grid of today's counts: Conversations / Memories / Done / New tasks.
/// Reads from latest `DailySummary`; if no summary today, shows zeros.
/// Splits the previously-cramped horizontal stat row out of `DailySummaryCard`.
private struct TodayStatsCard: View {
    /// True → render 2x2 stats + 7-day chart side-by-side. False → stats only.
    var isFullscreen: Bool = false

    /// 7-day chart still pulls from `DailySummary` (pre-aggregated history).
    /// The 4 TODAY counters are now computed in real-time from the live
    /// tables — the previous design relied on `DailySummary.date == today`
    /// existing, but that record is only generated at the user's scheduled
    /// hour (default 22:00) or via manual GENERATE NOW. If neither
    /// happened, the dashboard showed all zeros despite the user having
    /// real conversations / memories / tasks today (2026-05-01 user
    /// report: "уже несколько дней по нулям"). Real-time fixes the
    /// disconnect.
    @Query(sort: \DailySummary.date, order: .reverse)
    private var summaries: [DailySummary]

    /// Live convos. We pre-filter on the SwiftData side via the broad
    /// `!discarded` predicate so the in-memory filter to "today" only walks
    /// non-discarded rows.
    @Query(filter: #Predicate<Conversation> { !$0.discarded })
    private var liveConvs: [Conversation]

    /// Live memories — non-dismissed only.
    @Query(filter: #Predicate<UserMemory> { !$0.isDismissed && !$0.needsReview })
    private var liveMemories: [UserMemory]

    /// Live completed tasks (any time). Filtered to "completed today" via
    /// `completedAt` in-memory.
    @Query(filter: #Predicate<TaskItem> { $0.completed })
    private var allCompletedTasks: [TaskItem]

    /// Live tasks (any status) — filtered to "created today" in-memory,
    /// excluding dismissed ones.
    @Query private var allTasks: [TaskItem]

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    private var convosTodayItems: [String] {
        liveConvs
            .filter { $0.createdAt >= todayStart }
            .sorted { $0.createdAt > $1.createdAt }
            .map { conv in
                if let cal = conv.calendarEventTitle?.trimmingCharacters(in: .whitespaces), !cal.isEmpty { return cal }
                return conv.title ?? "Untitled"
            }
    }
    private var memoriesTodayItems: [String] {
        liveMemories
            .filter { $0.createdAt >= todayStart }
            .sorted { $0.createdAt > $1.createdAt }
            .map { String($0.content.prefix(80)) }
    }
    private var doneTodayItems: [String] {
        allCompletedTasks
            .filter { ($0.completedAt ?? .distantPast) >= todayStart }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .map { $0.taskDescription }
    }
    private var newTasksTodayItems: [String] {
        allTasks
            .filter { $0.createdAt >= todayStart && ($0.status ?? "committed") != "dismissed" }
            .sorted { $0.createdAt > $1.createdAt }
            .map { $0.taskDescription }
    }

    private var convosToday: Int { convosTodayItems.count }
    private var memoriesToday: Int { memoriesTodayItems.count }
    private var doneToday: Int { doneTodayItems.count }
    private var newTasksToday: Int { newTasksTodayItems.count }

    /// Last 7 days of total daily activity (conv + mem + tasks done + tasks created).
    /// Computed in real-time from the live tables — same reasoning as the
    /// 4 TODAY counters above. The pre-aggregated `DailySummary` rows can't
    /// be trusted because the generation job is opt-in / scheduled, and
    /// missing days made the chart look like a flat zero strip.
    private var last7: [(date: Date, value: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            let c = liveConvs.filter { $0.createdAt >= day && $0.createdAt < next }.count
            let m = liveMemories.filter { $0.createdAt >= day && $0.createdAt < next }.count
            let d = allCompletedTasks.filter {
                let when = $0.completedAt ?? .distantPast
                return when >= day && when < next
            }.count
            let n = allTasks.filter {
                $0.createdAt >= day && $0.createdAt < next && ($0.status ?? "committed") != "dismissed"
            }.count
            return (day, c + m + d + n)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            HStack {
                Text("TODAY").mwBadge()
                Spacer()
                if isFullscreen {
                    Text("Last 7 days")
                        .font(MW.dataSmall)
                        .foregroundStyle(MW.textDim)
                }
            }
            // Fullscreen: stats LEFT + 7-day chart RIGHT. Compressed: stats
            // alone (chart hidden — saves vertical real estate without extra
            // sub-row). The Grid above keeps STATS|SCREEN heights synced
            // either way.
            if isFullscreen {
                HStack(alignment: .top, spacing: MW.sp16) {
                    statsGrid
                        .frame(maxWidth: .infinity, alignment: .leading)
                    last7Chart
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                statsGrid
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: MW.sp8),
                      GridItem(.flexible(), spacing: MW.sp8)],
            spacing: MW.sp8
        ) {
            // Real-time from live tables — does NOT depend on DailySummary
            // existing for today. Hover any cell with value > 0 → popover with
            // the actual items behind the count.
            stat(value: convosToday, label: "Convos", items: convosTodayItems)
            stat(value: memoriesToday, label: "Memories", items: memoriesTodayItems)
            stat(value: doneToday, label: "Done", items: doneTodayItems)
            stat(value: newTasksToday, label: "New tasks", items: newTasksTodayItems)
        }
    }

    /// 7 vertical bars. Today = accent, past days = muted. Height proportional
    /// to value vs the week's max. Empty week → flat baseline strip.
    private var last7Chart: some View {
        let series = last7
        let maxV = max(series.map(\.value).max() ?? 1, 1)
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(series, id: \.date) { day in
                    let isToday = cal.isDateInToday(day.date)
                    let h = max(3, CGFloat(day.value) / CGFloat(maxV) * 64)
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isToday ? AnyShapeStyle(MW.accent) : AnyShapeStyle(MW.textDim.opacity(0.55)))
                            .frame(height: h)
                        Text(weekdayLetter(day.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(isToday ? MW.textPrimary : MW.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func weekdayLetter(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return String(f.string(from: d).prefix(1))
    }

    /// Mockup pattern: no per-cell background — number + caption arranged on
    /// the parent card. Cleaner read than the previous material sub-tiles.
    /// Delegates to `StatCell` because hover-popover state needs `@State`,
    /// which can't live inside a `private func` body.
    private func stat(value: Int, label: String, items: [String]) -> some View {
        StatCell(value: value, label: label, items: items)
    }
}

/// One TODAY tile. Hover (on cells with value > 0) reveals a popover with
/// up to 10 lines from `items` — title for convos, content prefix for
/// memories, task description for done/new. Empty cells stay inert.
private struct StatCell: View {
    let value: Int
    let label: String
    let items: [String]

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(MW.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(MW.label).tracking(1.0)
                .foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MW.sp4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering && !items.isEmpty
        }
        .popover(isPresented: $isHovered, arrowEdge: .top) {
            StatPopover(label: label, items: items)
        }
    }
}

private struct StatPopover: View {
    let label: String
    let items: [String]

    private let maxRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY · \(label.uppercased())")
                .font(MW.label).tracking(1.0)
                .foregroundStyle(MW.textMuted)
            ForEach(Array(items.prefix(maxRows).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .foregroundStyle(MW.textMuted)
                    Text(line)
                        .font(MW.caption)
                        .foregroundStyle(MW.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            if items.count > maxRows {
                Text("and \(items.count - maxRows) more")
                    .font(MW.caption)
                    .foregroundStyle(MW.textMuted)
                    .padding(.top, 2)
            }
        }
        .padding(MW.sp12)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
    }
}

// MARK: - Today + Tomorrow Section (mockup v9)

/// Two-column dashboard top: LEFT = today's recap + Stats|Screen sub-row;
/// RIGHT = tomorrow's plans (calendar / due tasks). Replaces the 14-day
/// carousel — single ‹ / › arrows in `TodayCard` navigate past days while
/// data exists.
private struct TodayTomorrowSection: View {
    let isWide: Bool
    /// True when the WINDOW is fullscreen-wide enough to give each card
    /// generous internal width (~1240+ window). When false, inner cards
    /// keep single-column dense layout — no useless "second column" with
    /// nothing to put in it.
    let isFullscreen: Bool

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: MW.sp12, verticalSpacing: MW.sp12) {
            GridRow {
                TodayCard(isFullscreen: isFullscreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                TomorrowCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            GridRow {
                TodayStatsCard(isFullscreen: isFullscreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScreenActivityCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Today Card (left column, replaces DailySummaryCarousel)

/// Today's LLM recap with single ‹ / › arrows for past-day navigation.
/// Replaces the 14-day picker carousel — user navigates one day at a time
/// while a `DailySummary` row exists for the destination day. The forward
/// arrow is hidden at offset 0 (today) so the user can't slide into the
/// future. Body re-uses the same render shape DetailCard had: title +
/// LEARNED / DECIDED / SHIPPED / energy.
private struct TodayCard: View {
    /// True → split sections into 2 columns (LEARNED+SHIPPED | DECIDED).
    /// False → keep dense single-column layout. Driven by window width.
    var isFullscreen: Bool = false

    @Query(sort: \DailySummary.date, order: .reverse)
    private var summaries: [DailySummary]

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.modelContext) private var modelContext
    @State private var dayOffset: Int = 0
    @State private var isGenerating = false
    @State private var localSummary: DailySummary?
    @State private var calendarEvents: [TodayCalendarRow] = []

    private var cal: Calendar { Calendar.current }
    private var selectedDate: Date {
        cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var todaysSummary: DailySummary? {
        if let local = localSummary,
           cal.isDate(local.date, inSameDayAs: selectedDate) {
            return local
        }
        return summaries.first { cal.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// Allow ‹ as long as some day older than `selectedDate` has data.
    private var canGoBack: Bool {
        guard let oldest = summaries.last?.date else { return false }
        return cal.startOfDay(for: oldest) < selectedDate
    }

    private var canGoForward: Bool { dayOffset < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            header
            // Always render the calendar section when calendar is connected so
            // the user sees TODAY at a glance — even on quiet days. Empty days
            // get a placeholder line ("No events scheduled today.") instead of
            // the section silently disappearing.
            if settings.calendarReaderEnabled {
                calendarSection
            }
            content
        }
        .padding(MW.sp20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        .task { await loadCalendarEvents() }
        .onChange(of: dayOffset) { _, _ in
            Task { await loadCalendarEvents() }
        }
        .onChange(of: settings.calendarReaderEnabled) { _, _ in
            Task { await loadCalendarEvents() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadCalendarEvents() }
        }
    }

    /// Today's (or selected day's) calendar events. Always rendered when
    /// `calendarReaderEnabled` so the user can spot the section. Empty days
    /// fall back to a single placeholder row instead of hiding entirely.
    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: MW.sp6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                Text("CALENDAR")
                    .font(MW.label).tracking(1.2)
                    .foregroundStyle(MW.textMuted)
                Spacer()
                if !calendarEvents.isEmpty {
                    Text("\(calendarEvents.count) event\(calendarEvents.count == 1 ? "" : "s")")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textDim)
                }
            }
            if calendarEvents.isEmpty {
                Text(cal.isDateInToday(selectedDate)
                     ? "No events scheduled today."
                     : "No events on this day.")
                    .font(.system(size: 12))
                    .foregroundStyle(MW.textMuted)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(calendarEvents) { ev in
                        eventRow(ev)
                    }
                }
            }
        }
    }

    private func eventRow(_ ev: TodayCalendarRow) -> some View {
        let isClickable = ev.conversationId != nil
        return Button(action: { openEvent(ev) }) {
            HStack(spacing: 10) {
                Text(ev.timeLabel)
                    .font(MW.dataSmall).foregroundStyle(MW.textMuted)
                    .frame(width: 44, alignment: .leading)
                Text(ev.title)
                    .font(.system(size: 13))
                    .foregroundStyle(ev.isPast ? MW.textSecondary : MW.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isClickable {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MW.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isClickable)
        .help(isClickable ? "Open recorded conversation" : "Not yet recorded")
    }

    /// Click → switch to Library tab → open ConversationDetailView for the
    /// linked conversation. Posted in two phases so ConversationsView has time
    /// to mount under the Library tab before receiving openConversation.
    private func openEvent(_ ev: TodayCalendarRow) {
        guard let convId = ev.conversationId else { return }
        NotificationCenter.default.post(
            name: .switchMainTab,
            object: MainWindowView.SidebarTab.library
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .openConversation, object: convId)
        }
    }

    /// Loads EKEvents falling on `selectedDate` and pairs each with its
    /// linked `Conversation` (if any). No-op when calendar permission isn't
    /// granted or the toggle is off — section just stays hidden.
    private func loadCalendarEvents() async {
        guard settings.calendarReaderEnabled else {
            await MainActor.run { calendarEvents = [] }
            return
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        if #available(macOS 14, *) {
            granted = (status == .fullAccess || status == .authorized)
        } else {
            granted = (status == .authorized)
        }
        guard granted else {
            await MainActor.run { calendarEvents = [] }
            return
        }

        let store = EKEventStore()
        let dayStart = cal.startOfDay(for: selectedDate)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let fetched = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .filter { ev in
                if let me = ev.attendees?.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return false
                }
                return true
            }
            .sorted { $0.startDate < $1.startDate }

        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let now = Date()
        let mapped: [TodayCalendarRow] = fetched.map { ev in
            var convId: UUID? = nil
            if let eid = ev.eventIdentifier {
                let descriptor = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { $0.calendarEventId == eid }
                )
                if let conv = (try? modelContext.fetch(descriptor))?.first {
                    convId = conv.id
                }
            }
            return TodayCalendarRow(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "(untitled)",
                timeLabel: f.string(from: ev.startDate),
                conversationId: convId,
                isPast: ev.endDate < now
            )
        }

        await MainActor.run { calendarEvents = mapped }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            arrowButton(systemName: "chevron.left", enabled: canGoBack) {
                if canGoBack {
                    withAnimation(.easeInOut(duration: 0.15)) { dayOffset -= 1 }
                    localSummary = nil
                }
            }
            if canGoForward {
                arrowButton(systemName: "chevron.right", enabled: true) {
                    withAnimation(.easeInOut(duration: 0.15)) { dayOffset += 1 }
                    localSummary = nil
                }
            }
            Text(dayLabel).mwBadge()
            Text(dateLabel)
                .font(MW.dataSmall).foregroundStyle(MW.textMuted)
            Spacer()
            generateButton
        }
    }

    private func arrowButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? MW.textSecondary : MW.textDim)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(MW.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var generateButton: some View {
        Button(action: generate) {
            HStack(spacing: 4) {
                if isGenerating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: todaysSummary == nil ? "sparkles" : "arrow.clockwise")
                        .font(.system(size: 10))
                }
                Text(isGenerating ? "GENERATING…"
                     : (todaysSummary == nil ? "GENERATE" : "REGENERATE"))
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
        if let s = todaysSummary {
            summaryRender(for: s)
        } else {
            emptyPlaceholder
        }
    }

    /// Responsive layout. Fullscreen window → 2-col split (LEARNED+SHIPPED on
    /// the left, DECIDED on the right) — fills the empty real estate.
    /// Compressed window → dense single-column stack so bullets aren't
    /// squeezed. Headline + energy always full-width.
    @ViewBuilder
    private func summaryRender(for s: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            Text(s.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if isFullscreen {
                HStack(alignment: .top, spacing: MW.sp20) {
                    VStack(alignment: .leading, spacing: MW.sp16) {
                        section(label: "Learned", icon: "lightbulb", items: s.learned)
                        section(label: "Shipped", icon: "shippingbox", items: s.shipped)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: MW.sp16) {
                        section(label: "Decided", icon: "checkmark.circle", items: s.decided)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                section(label: "Learned", icon: "lightbulb", items: s.learned)
                section(label: "Decided", icon: "checkmark.circle", items: s.decided)
                section(label: "Shipped", icon: "shippingbox", items: s.shipped)
            }

            let energy = (s.energy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !energy.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MW.textMuted)
                    Text(energy)
                        .font(.system(size: 13))
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
        let isToday = cal.isDateInToday(selectedDate)
        return Text(isToday
             ? (settings.dailySummaryEnabled
                ? "Recap will generate at \(scheduledTimeLabel) — or tap GENERATE."
                : "Daily summary is off. Enable in Settings → AI.")
             : "No summary recorded for this day. Tap GENERATE to build one from saved data.")
            .font(MW.mono).foregroundStyle(MW.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 16)
    }

    private var dayLabel: String {
        if cal.isDateInToday(selectedDate) { return "TODAY" }
        if cal.isDateInYesterday(selectedDate) { return "YESTERDAY" }
        let days = cal.dateComponents([.day], from: selectedDate, to: Date()).day ?? 0
        return "\(days) DAYS AGO"
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: selectedDate)
    }

    private var scheduledTimeLabel: String {
        String(format: "%02d:%02d", settings.dailySummaryHour, settings.dailySummaryMinute)
    }

    private func generate() {
        isGenerating = true
        let target = selectedDate
        Task { @MainActor in
            let result = await AppDelegate.shared?.dailySummaryService.generateForDate(target)
            localSummary = result
            isGenerating = false
        }
    }
}

// MARK: - Tomorrow Card (right column)

/// Right-column card: tomorrow's calendar events + tasks due + pending tasks.
/// CONNECT button shows when calendar reader is off OR macOS-level permission
/// not granted (catches «toggle on but never approved system dialog» case).
/// PENDING section surfaces open tasks without a due-date — fills the card so
/// it doesn't read as empty hole when calendar is fresh / no tasks tomorrow.
private struct TomorrowCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @Query private var dueTomorrow: [TaskItem]
    @Query private var pendingNoDate: [TaskItem]
    @State private var events: [TomorrowEvent] = []
    @State private var loadingEvents = false
    /// Bumped after `connectCalendar()` / `loadEvents()` so `calendarPermissionGranted`
    /// gets re-evaluated — `EKEventStore.authorizationStatus` re-reads system state
    /// each call, but SwiftUI needs a state change to re-render.
    @State private var permissionTick: Int = 0
    /// Set to `true` when `requestFullAccessToEvents()` returns `false` even though
    /// system status was `.notDetermined`. This happens when TCC has a cached deny
    /// for the bundle — macOS skips the dialog and returns false synchronously.
    /// Once set, we treat the flow as `.denied` and route the button to System Settings.
    @State private var connectFailedOnce = false

    init() {
        let cal = Calendar.current
        let tomStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let tomEnd = cal.date(byAdding: .day, value: 1, to: tomStart) ?? tomStart
        _dueTomorrow = Query(
            filter: #Predicate<TaskItem> { task in
                task.dueAt != nil &&
                task.dueAt! >= tomStart &&
                task.dueAt! < tomEnd
            },
            sort: [SortDescriptor(\.dueAt, order: .forward)]
        )
        _pendingNoDate = Query(
            filter: #Predicate<TaskItem> { task in
                task.dueAt == nil && !task.completed && !task.isDismissed
            },
            sort: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    private var visibleDue: [TaskItem] {
        dueTomorrow.filter {
            !$0.completed && !$0.isDismissed &&
            ($0.status == "committed" || $0.status == nil)
        }
    }

    private var visibleSuggested: [TaskItem] {
        Array(pendingNoDate.filter {
            $0.status == "committed" || $0.status == nil
        }.prefix(5))
    }

    private var tomorrowDate: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
    }

    /// One of three states drives the calendar UI:
    ///   - `.granted` → events loaded (or "No events" empty state).
    ///   - `.notDetermined` → user has never been asked → CONNECT button surfaces the OS dialog.
    ///   - `.denied` → user previously refused; `requestFullAccessToEvents` will silently return false.
    ///                 Only path forward — open System Settings → Privacy → Calendars.
    private enum CalendarAuthState { case granted, notDetermined, denied }

    private var calendarAuth: CalendarAuthState {
        _ = permissionTick
        // If a previous CONNECT attempt failed silently (TCC cached deny while
        // status reports notDetermined) we treat it as denied so the button
        // routes to System Settings — the only remedy.
        if connectFailedOnce { return .denied }
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) {
            switch status {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted, .writeOnly: return .denied
            case .authorized: return .granted   // legacy alias
            @unknown default: return .denied
            }
        } else {
            switch status {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }
    }

    /// CONNECT prompt shows when either the toggle is off, or OS permission isn't granted yet.
    private var showsConnectPrompt: Bool {
        !settings.calendarReaderEnabled || calendarAuth != .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            header
            calendarSection
            if !visibleDue.isEmpty {
                dueSection
            }
            if !visibleSuggested.isEmpty {
                pendingSection
            }
        }
        .padding(MW.sp20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        .task { await loadEvents() }
        .onChange(of: settings.calendarReaderEnabled) { _, _ in
            Task { await loadEvents() }
        }
        // Reload when window comes back to foreground — covers the case where
        // user clicks OPEN SETTINGS, grants permission in System Settings,
        // then returns to MetaWhisp. Without this they'd need to relaunch.
        // Also clears the stale-deny flag when real OS status is no longer denied
        // (e.g. user ran `tccutil reset` externally), so the button unsticks.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let status = EKEventStore.authorizationStatus(for: .event)
            let realDenied: Bool = {
                if #available(macOS 14, *) {
                    return status == .denied || status == .restricted || status == .writeOnly
                }
                return status == .denied || status == .restricted
            }()
            if !realDenied && connectFailedOnce {
                connectFailedOnce = false
            }
            permissionTick += 1
            Task { await loadEvents() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("TOMORROW").mwBadge()
            Text(dateLabel)
                .font(MW.dataSmall).foregroundStyle(MW.textMuted)
            Spacer()
            chip
        }
    }

    @ViewBuilder
    private var chip: some View {
        if !events.isEmpty {
            Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textPrimary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(MW.border, lineWidth: 0.5)
                )
        } else if !visibleDue.isEmpty {
            Text("\(visibleDue.count) due")
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(MW.border, lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: MW.sp6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                Text("CALENDAR")
                    .font(MW.label).tracking(1.2)
                    .foregroundStyle(MW.textMuted)
                if showsConnectPrompt {
                    Text("· NOT CONNECTED")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textDim)
                }
            }

            if showsConnectPrompt {
                connectPrompt
            } else if events.isEmpty && !loadingEvents {
                Text("No events scheduled for tomorrow.")
                    .font(MW.mono).foregroundStyle(MW.textMuted)
                    .padding(.vertical, 4)
            } else if loadingEvents {
                Text("Loading events…")
                    .font(MW.mono).foregroundStyle(MW.textMuted)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(events) { ev in
                        HStack(spacing: 10) {
                            Text(ev.timeLabel)
                                .font(MW.dataSmall).foregroundStyle(MW.textMuted)
                                .frame(width: 44, alignment: .leading)
                            Text(ev.title)
                                .font(.system(size: 13))
                                .foregroundStyle(MW.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectPrompt: some View {
        let denied = calendarAuth == .denied
        VStack(alignment: .leading, spacing: 10) {
            Text(denied
                 ? "Calendar access is currently denied. Open System Settings → Privacy & Security → Calendars and enable MetaWhisp to see tomorrow's events here."
                 : "Link your calendar so MetaWhisp can show tomorrow's events here, match meetings to conversations, and surface what's coming next.")
                .font(.system(size: 13))
                .foregroundStyle(MW.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Always route through connectCalendar() — it inspects live TCC status
                // and decides whether to fire the request or jump to Settings.
                // This avoids the trap where a stale flag locks the button into
                // OPEN SETTINGS even after TCC has been reset.
            Button(action: connectCalendar) {
                HStack(spacing: 6) {
                    Image(systemName: denied ? "gear" : "calendar.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(denied ? "OPEN SETTINGS" : "CONNECT CALENDAR")
                        .font(MW.label).tracking(1.0)
                }
                .foregroundStyle(MW.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                        .stroke(MW.border, lineWidth: 0.5)
                )
                .contentShape(Rectangle())  // ensure hit-test covers full padded area
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var dueSection: some View {
        VStack(alignment: .leading, spacing: MW.sp6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                Text("DUE TOMORROW")
                    .font(MW.label).tracking(1.2)
                    .foregroundStyle(MW.textMuted)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleDue) { task in
                    HStack(spacing: 10) {
                        Text(timeLabel(for: task))
                            .font(MW.dataSmall).foregroundStyle(MW.textMuted)
                            .frame(width: 44, alignment: .leading)
                        Text(task.taskDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(MW.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    /// Top-5 open tasks without a due-date — fills the card with value
    /// when CALENDAR / DUE are empty. Primary anti-empty-space treatment.
    @ViewBuilder
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: MW.sp6) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                Text("PENDING")
                    .font(MW.label).tracking(1.2)
                    .foregroundStyle(MW.textMuted)
                Text("· no due date")
                    .font(MW.label).tracking(0.6)
                    .foregroundStyle(MW.textDim)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleSuggested) { task in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(MW.textDim).frame(width: 3, height: 3).padding(.top, 7)
                        Text(task.taskDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(MW.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func timeLabel(for task: TaskItem) -> String {
        guard let due = task.dueAt else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: due)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: tomorrowDate)
    }

    /// Live-status routing — single entry point for the button:
    ///   1. If OS-level status is already `.denied/.restricted` → open System
    ///      Settings directly (macOS won't re-prompt, Settings is the only path).
    ///   2. If status is already granted → toggle on + load events.
    ///   3. If status is `.notDetermined` → fire request. On success → load.
    ///      On silent fail (TCC cached deny) → mark flag + open Settings.
    /// Bypasses `scanNow()`'s `hasLLMAccess` gate; scanNow runs in background
    /// after grant for TaskItem mirrors + pattern memories.
    private func connectCalendar() {
        let preStatus = EKEventStore.authorizationStatus(for: .event)
        NSLog("[Dashboard] CONNECT tapped. status=%d enabled=%@ failedFlag=%@",
              preStatus.rawValue,
              AppSettings.shared.calendarReaderEnabled ? "true" : "false",
              connectFailedOnce ? "true" : "false")

        // 1. Already denied at OS level → only Settings can fix it.
        let isDenied: Bool = {
            if #available(macOS 14, *) {
                return preStatus == .denied || preStatus == .restricted || preStatus == .writeOnly
            }
            return preStatus == .denied || preStatus == .restricted
        }()
        if isDenied {
            connectFailedOnce = true
            permissionTick += 1
            openCalendarSettings()
            return
        }

        // 2. Already granted → just enable + load (covers tccutil-reset-then-grant flow).
        let isGranted: Bool = {
            if #available(macOS 14, *) {
                return preStatus == .fullAccess || preStatus == .authorized
            }
            return preStatus == .authorized
        }()
        if isGranted {
            AppSettings.shared.calendarReaderEnabled = true
            connectFailedOnce = false
            permissionTick += 1
            Task { @MainActor in
                await loadEvents()
                Task.detached { await AppDelegate.shared?.calendarReader.scanNow() }
            }
            return
        }

        // 3. notDetermined (or unknown) → request. NO NSApp.activate here:
        //    the aggressive (ignoringOtherApps:) form yanks the user to the
        //    main window's bound Space/display (see MainWindowController's
        //    documented rule). The TCC permission dialog is system-presented
        //    regardless of app activation.
        Task { @MainActor in
            let store = EKEventStore()
            let granted: Bool
            do {
                if #available(macOS 14, *) {
                    granted = try await store.requestFullAccessToEvents()
                } else {
                    granted = await withCheckedContinuation { cont in
                        store.requestAccess(to: .event) { ok, _ in
                            cont.resume(returning: ok)
                        }
                    }
                }
            } catch {
                NSLog("[Dashboard] requestFullAccessToEvents threw: %@", error.localizedDescription)
                granted = false
            }

            let postStatus = EKEventStore.authorizationStatus(for: .event)
            NSLog("[Dashboard] CONNECT result granted=%@ postStatus=%d",
                  granted ? "true" : "false", postStatus.rawValue)

            if granted {
                AppSettings.shared.calendarReaderEnabled = true
                connectFailedOnce = false
                permissionTick += 1
                await loadEvents()
                Task.detached { await AppDelegate.shared?.calendarReader.scanNow() }
            } else {
                // TCC silently denied. Open Privacy pane — only path forward.
                connectFailedOnce = true
                permissionTick += 1
                openCalendarSettings()
            }
        }
    }

    /// Deep-link to the Calendar privacy pane. Used when `calendarAuth == .denied`,
    /// because macOS does not re-show the permission dialog after deny — only Settings.
    private func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Loads tomorrow's EKEvents. Only checks current authorization — does NOT
    /// request. Requesting is owned by `connectCalendar()` so .task on view
    /// appear stays silent (no dialog popping up just from opening Dashboard).
    private func loadEvents() async {
        guard settings.calendarReaderEnabled else {
            await MainActor.run { events = [] }
            return
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        let isGranted: Bool
        if #available(macOS 14, *) {
            isGranted = (status == .fullAccess || status == .authorized)
        } else {
            isGranted = (status == .authorized)
        }
        guard isGranted else {
            await MainActor.run {
                events = []
                loadingEvents = false
                permissionTick += 1
            }
            return
        }

        // Permission is now genuinely granted — clear the stale-deny flag so
        // the UI flips back to the events list / "no events" state instead
        // of OPEN SETTINGS.
        await MainActor.run {
            connectFailedOnce = false
            loadingEvents = true
        }

        let store = EKEventStore()
        let cal = Calendar.current
        let tomStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let tomEnd = cal.date(byAdding: .day, value: 1, to: tomStart) ?? tomStart
        let predicate = store.predicateForEvents(withStart: tomStart, end: tomEnd, calendars: nil)
        let fetched = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .filter { ev in
                if let me = ev.attendees?.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return false
                }
                return true
            }
            .sorted { $0.startDate < $1.startDate }

        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let mapped = fetched.map { ev in
            TomorrowEvent(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "(untitled)",
                timeLabel: f.string(from: ev.startDate)
            )
        }

        await MainActor.run {
            events = mapped
            loadingEvents = false
            permissionTick += 1
        }
    }
}

private struct TomorrowEvent: Identifiable {
    let id: String
    let title: String
    let timeLabel: String
}

/// Today's calendar event row. `conversationId` is set when the event has
/// a linked `Conversation` (recorded by MetaWhisp). Click such a row to drill
/// into the conversation detail view (transcript + linked tasks/memories).
private struct TodayCalendarRow: Identifiable {
    let id: String
    let title: String
    let timeLabel: String
    let conversationId: UUID?
    let isPast: Bool
}
