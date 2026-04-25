import Foundation
import SwiftData

/// Cross-conversation pattern recap (ITER-022 G5 — WeeklyPatternDetector).
///
/// Generated weekly (or on-demand) by `WeeklyPatternDetector` from the user's
/// past N days of `Conversation` + `UserMemory` + `TaskItem` activity. Surfaces
/// what the user can't see in any single meeting / dictation:
/// - **Recurring themes** — topics that came up in ≥3 conversations
/// - **Recurring people** — names that appeared across multiple contexts
/// - **Stuck loops** — themes discussed multiple times with no decision extracted
/// - **Insights** — cross-context observations the LLM can synthesize
///
/// Stored persistently so the user can scroll back through "what happened in
/// the past N weeks". Lightweight JSON arrays (no ScreenContext-style heavy fields).
///
/// spec://iterations/ITER-022-G5-weekly-patterns
@Model
final class PatternDigest {
    var id: UUID
    /// Start of the analysed window (Calendar.startOfDay). Window length is in
    /// `windowDays` so future versions can do "last 30 days" digests too.
    var weekStartDate: Date
    var windowDays: Int
    /// JSON-encoded `[String]` — recurring themes, ≤5 items, ≤14 words each.
    var themesJSON: String?
    /// JSON-encoded `[String]` — recurring people / projects, ≤5 items.
    var peopleJSON: String?
    /// JSON-encoded `[String]` — stuck loops (themes ≥3× with no decision found).
    var stuckLoopsJSON: String?
    /// JSON-encoded `[String]` — cross-context insights (one-line each).
    var insightsJSON: String?
    /// Number of conversations sampled (for UI footer "based on N conversations").
    var conversationsAnalyzed: Int
    var createdAt: Date

    init(weekStartDate: Date, windowDays: Int, conversationsAnalyzed: Int) {
        self.id = UUID()
        self.weekStartDate = weekStartDate
        self.windowDays = windowDays
        self.conversationsAnalyzed = conversationsAnalyzed
        self.createdAt = Date()
    }

    var themes: [String]    { Self.decodeStringArray(themesJSON) }
    var people: [String]    { Self.decodeStringArray(peopleJSON) }
    var stuckLoops: [String] { Self.decodeStringArray(stuckLoopsJSON) }
    var insights: [String]  { Self.decodeStringArray(insightsJSON) }

    /// True when all 4 sections are empty — used by UI to render "Quiet week"
    /// state instead of empty card list.
    var isEmpty: Bool {
        themes.isEmpty && people.isEmpty && stuckLoops.isEmpty && insights.isEmpty
    }

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
