import Foundation
import SwiftData

/// LLM-generated recap of a single day. Produced by `DailySummaryService` at the
/// user-scheduled time (default 22:00) from that day's conversations / memories /
/// tasks / screen observations.
///
/// One row per calendar day (unique `date` normalized to midnight local). Generator
/// skips days that already have a row.
/// spec://iterations/ITER-009-daily-summary
@Model
final class DailySummary {
    var id: UUID
    /// Calendar day normalized to 00:00 local. Unique key.
    var date: Date
    /// Short LLM title, e.g. "Heavy MetaWhisp dev day · Overchat SEO push".
    var title: String
    /// 3–5 sentence narrative of what the user did / learned / decided.
    var overview: String
    /// JSON-encoded `[String]` — 3–5 bullet highlights.
    var keyEventsJSON: String
    var conversationCount: Int
    var tasksCompleted: Int
    var tasksCreated: Int
    var memoriesAdded: Int
    /// JSON-encoded `[TopApp]` — top apps by on-screen time that day.
    var topAppsJSON: String
    var createdAt: Date
    /// False until the user opens the Dashboard summary card after generation.
    var isRead: Bool

    // Section content — new 4-section format (LEARNED · DECIDED · SHIPPED · ENERGY).
    // Optional so SwiftData lightweight migration adds them without a versioning plan
    // and legacy rows fall back to the old `title` / `overview` / `keyEventsJSON`.
    var learnedJSON: String?
    var decidedJSON: String?
    var shippedJSON: String?
    var energy: String?

    init(
        date: Date,
        title: String,
        overview: String,
        keyEventsJSON: String = "[]",
        conversationCount: Int = 0,
        tasksCompleted: Int = 0,
        tasksCreated: Int = 0,
        memoriesAdded: Int = 0,
        topAppsJSON: String = "[]"
    ) {
        self.id = UUID()
        self.date = date
        self.title = title
        self.overview = overview
        self.keyEventsJSON = keyEventsJSON
        self.conversationCount = conversationCount
        self.tasksCompleted = tasksCompleted
        self.tasksCreated = tasksCreated
        self.memoriesAdded = memoriesAdded
        self.topAppsJSON = topAppsJSON
        self.createdAt = Date()
        self.isRead = false
    }

    struct TopApp: Codable {
        let app: String
        let minutes: Int
    }

    var keyEvents: [String] {
        guard let data = keyEventsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var topApps: [TopApp] {
        guard let data = topAppsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TopApp].self, from: data)) ?? []
    }

    var learned: [String] { decodeStringArray(learnedJSON) }
    var decided: [String] { decodeStringArray(decidedJSON) }
    var shipped: [String] { decodeStringArray(shippedJSON) }

    private func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodeStringArray(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
