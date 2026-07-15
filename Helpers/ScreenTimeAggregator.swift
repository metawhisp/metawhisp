import Foundation

/// ITER-053.1 — the ONE place that turns screen-capture timelines into
/// «top apps by time». Two data sources exist historically:
///   • raw `ScreenContext` rows (Dashboard, live 24h) — consecutive-timestamp
///     gaps, capped so idle pauses don't count;
///   • distilled `ScreenObservation` rows (DailySummary) — explicit
///     startedAt/endedAt visit windows.
/// Both funnel through this helper so the math (gap cap, sorting, percent)
/// can't silently diverge again.
enum ScreenTimeAggregator {

    struct AppTime: Equatable {
        let appName: String
        let seconds: Double
        let percent: Int
    }

    /// From RAW capture rows: время = gap до следующего снимка, capped at
    /// `maxGap` (default 300s — a longer pause means the user walked away).
    /// `samples` must be (appName, timestamp) sorted ascending by timestamp.
    static func topApps(
        samples: [(appName: String, timestamp: Date)],
        maxGap: TimeInterval = 300,
        limit: Int = 5
    ) -> [AppTime] {
        guard samples.count >= 2 else { return [] }
        var byApp: [String: Double] = [:]
        for i in 0..<(samples.count - 1) {
            let gap = min(samples[i + 1].timestamp.timeIntervalSince(samples[i].timestamp), maxGap)
            guard gap > 0 else { continue }
            byApp[samples[i].appName, default: 0] += gap
        }
        return rank(byApp, limit: limit)
    }

    /// From distilled visit windows (startedAt/endedAt).
    static func topApps(
        visits: [(appName: String, startedAt: Date, endedAt: Date)],
        limit: Int = 5
    ) -> [AppTime] {
        var byApp: [String: Double] = [:]
        for v in visits {
            let dur = v.endedAt.timeIntervalSince(v.startedAt)
            guard dur > 0 else { continue }
            byApp[v.appName, default: 0] += dur
        }
        return rank(byApp, limit: limit)
    }

    private static func rank(_ byApp: [String: Double], limit: Int) -> [AppTime] {
        let total = byApp.values.reduce(0, +)
        guard total > 0 else { return [] }
        return byApp.map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { AppTime(appName: $0.0, seconds: $0.1, percent: Int(($0.1 / total * 100).rounded())) }
    }
}
