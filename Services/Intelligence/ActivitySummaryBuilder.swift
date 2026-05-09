import Foundation

/// Pure-function aggregator for the "ACTIVITY SUMMARY" block in the
/// proactive insight prompt (ITER-027.3).
///
/// Reference layout (`InsightAssistant.swift:842-857`):
///
///     ACTIVITY SUMMARY (last N min, K frames):
///     Time range: HH:MM:SS – HH:MM:SS
///
///     App | Window | Frames | Est. Duration
///     ------------------------------------------------------------
///     Terminal | ssh prod-db | 12 | 0.2 min
///     Slack    | #deploys    |  8 | 0.1 min
///
/// The `Row` input is decoupled from the SwiftData `ScreenContext` model
/// so the function stays unit-testable. The caller (in production:
/// `InsightAssistantService` via a SwiftData fetch) maps `ScreenContext`
/// → `Row` before passing in.
enum ActivitySummaryBuilder {

    /// Decoupled view of a `ScreenContext` row needed for aggregation.
    /// `Equatable` for clean test setup; otherwise opaque.
    struct Row: Equatable {
        let appName: String
        let windowTitle: String
        let timestamp: Date
    }

    /// Max characters kept from the window title in the output. Long
    /// browser titles ("Some Long Document Title - Google Docs - …")
    /// would otherwise dominate the prompt. Reference: 50 chars.
    private static let maxWindowChars = 50

    /// Hard cap on lines in the output. Even if the user touched 60
    /// distinct windows in the last hour, we ship the top 30.
    private static let maxRows = 30

    /// Aggregates `rows` whose `timestamp` falls in `(lookbackStart, now]`
    /// into the activity summary string. Returns empty string when no
    /// in-window rows exist; caller skips the prompt block entirely
    /// in that case.
    static func build(rows: [Row], lookbackStart: Date, now: Date) -> String {
        // Filter to the time window — defensive against future-dated rows.
        let inWindow = rows.filter { $0.timestamp > lookbackStart && $0.timestamp <= now }
        guard !inWindow.isEmpty else { return "" }

        // Aggregate by (appName, windowTitle). Use a stable key so
        // identical pairs collapse and frames get summed.
        struct Key: Hashable { let app: String; let win: String }
        var counts: [Key: Int] = [:]
        for r in inWindow {
            let k = Key(app: r.appName, win: r.windowTitle)
            counts[k, default: 0] += 1
        }

        // Sort by frame count desc, ties broken by app name (alphabetical
        // is fine — ties are rare and the LLM doesn't care about the
        // tiebreaker; deterministic order keeps tests stable).
        let sorted = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.app < rhs.key.app
            }
            .prefix(maxRows)

        let elapsedMin = Int(now.timeIntervalSince(lookbackStart) / 60.0)
        let totalFrames = inWindow.count
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        lines.append("ACTIVITY SUMMARY (last \(elapsedMin) min, \(totalFrames) frames):")
        lines.append("Time range: \(timeFmt.string(from: lookbackStart)) – \(timeFmt.string(from: now))")
        lines.append("")
        lines.append("App | Window | Frames | Est. Duration")
        lines.append(String(repeating: "-", count: 60))

        for (key, count) in sorted {
            let win: String
            if key.win.isEmpty {
                win = "(no title)"
            } else {
                win = String(key.win.prefix(maxWindowChars))
            }
            // Estimate: assume one frame ≈ one second (caller sets the
            // capture cadence; this is a coarse hint to the LLM, not
            // billing data).
            let estMin = String(format: "%.1f", Double(count) / 60.0)
            lines.append("\(key.app) | \(win) | \(count) | \(estMin) min")
        }

        return lines.joined(separator: "\n")
    }
}
