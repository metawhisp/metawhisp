import SwiftUI

/// Metric card — BLOCKS monochromatic style.
struct MetricCardView: View {
    let icon: String
    let title: String
    let value: String
    var delta: Double? = nil
    var invertDelta: Bool = false

    var body: some View {
        VStack(spacing: MW.sp4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .thin))
                .foregroundStyle(MW.textSecondary)
            Text(value)
                .font(MW.monoLg).foregroundStyle(MW.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let d = delta, d != 0 {
                HStack(spacing: MW.spaceXs) {
                    Image(systemName: d > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(String(format: "%+.0f%%", d))
                        .font(MW.monoSm)
                }
                .foregroundStyle(deltaColor(d))
            }
            Text(title.uppercased()).font(MW.monoSm).foregroundStyle(MW.textMuted).tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(MW.sp16)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    private func deltaColor(_ d: Double) -> Color {
        let isPositive = invertDelta ? d < 0 : d > 0
        return isPositive ? Color(red: 0.2, green: 0.8, blue: 0.4) : Color.red
    }
}

/// Flow layout for wrapping tags horizontally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        calc(in: proposal.width ?? 300, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in calc(in: bounds.width, subviews: subviews).items {
            item.view.place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y), proposal: .unspecified)
        }
    }
    private struct Item { let view: LayoutSubview; let x: CGFloat; let y: CGFloat }
    private struct Res { let items: [Item]; let size: CGSize }
    private func calc(in width: CGFloat, subviews: Subviews) -> Res {
        var items: [Item] = []; var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            items.append(Item(view: v, x: x, y: y)); x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return Res(items: items, size: CGSize(width: width, height: y + rowH))
    }
}

/// Aggregated stats for a set of history items. Pure O(N) sums — NO text analysis.
///
/// PERFORMANCE NOTE (root cause of Dashboard freeze, 2026-04-25):
/// This init is called by `StatisticsView.stats` AND by every computed property
/// that derives from it (`wpm`, `words`, `audio`, etc.). SwiftUI re-evaluates
/// these on every render frame. Previously the init also computed
/// `TextAnalyzer.fillerCount(...)` on the joined text of ALL items (3500+ rows
/// × avg 50 chars = ~177KB string scanned through the filler word list with
/// `String.range(of:)` for each word — multi-million Unicode comparisons per render).
/// Sample profiling caught it: 1187/1567 main-thread samples sat in `_stringCompareInternal`
/// inside `TextAnalyzer.fillerWords` triggered from `wpm.getter`.
///
/// Fix: drop fillerPct from this struct. The single place that needs it
/// (`StatisticsView` share text, line 541) computes it on-demand from the
/// already-cached `fillersCache: [(word, count)]` populated asynchronously.
struct PeriodStats {
    let count: Int, words: Int, audio: Double, saved: Double, avgWords: Int
    init(_ items: [HistoryItem]) {
        count = items.count; words = items.reduce(0) { $0 + $1.wordCount }
        audio = items.reduce(0) { $0 + $1.audioDuration }
        let typingTime = Double(words) / 30.0 * 60.0 // 40 WPM typing speed → seconds
        let actualTime = audio + items.reduce(0) { $0 + $1.processingTime }
        saved = max(0, typingTime - actualTime)
        avgWords = count > 0 ? words / count : 0
    }
}

/// Period filter for statistics.
enum StatPeriod: Hashable {
    case today, week, allTime, month(Date)

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .allTime: "All Time"
        case .month(let d): { let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f.string(from: d) }()
        }
    }

    func filter(_ items: [HistoryItem]) -> [HistoryItem] {
        let cal = Calendar.current
        switch self {
        case .today:
            let start = cal.startOfDay(for: Date())
            return items.filter { $0.createdAt >= start }
        case .week:
            guard let interval = cal.dateInterval(of: .weekOfYear, for: Date()) else { return items }
            return items.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end }
        case .allTime:
            return items
        case .month(let s):
            let e = cal.date(byAdding: .month, value: 1, to: s)!
            return items.filter { $0.createdAt >= s && $0.createdAt < e }
        }
    }

    func previousFilter(_ items: [HistoryItem]) -> [HistoryItem] {
        let cal = Calendar.current
        switch self {
        case .today:
            let todayStart = cal.startOfDay(for: Date())
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return items.filter { $0.createdAt >= yesterdayStart && $0.createdAt < todayStart }
        case .week:
            guard let interval = cal.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
            let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: interval.start)!
            return items.filter { $0.createdAt >= prevStart && $0.createdAt < interval.start }
        case .allTime:
            return []
        case .month(let s):
            let ps = cal.date(byAdding: .month, value: -1, to: s)!
            return items.filter { $0.createdAt >= ps && $0.createdAt < s }
        }
    }
}

/// Helpers shared across statistics views.
enum StatFormatters {
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s" }
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return "\(h)h \(m)m"
    }

    static func pctChange(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return current > 0 ? 100 : nil }
        return ((current - previous) / previous) * 100
    }
}
