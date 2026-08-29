import Foundation
import SwiftData

/// Persistence layer for proactive insights (ITER-027.4).
///
/// Insights are stored as `UserMemory` rows with:
///   - `category = "system"`           (excludes them from regular memory feeds)
///   - `tagsCSV` contains `"insight"`  (lets us re-fetch only insights, not
///                                       generic system facts)
///   - `tagsCSV` also contains the insight's domain category
///     (`productivity` / `communication` / `learning` / `other`) for
///     future filtering.
///
/// Why ride on `UserMemory` instead of a fresh `@Model`:
///   - Single migration story, single embedding pipeline, one fewer table
///   - MetaChat retrieval already excludes `category=system` from facts UI
///   - Reference does the same: `MemoryStorage` insertLocalMemory with
///     `category="system"` + `tags=["tips", category]`
///
/// Pure-function mappers `toUserMemory(_:)` and `fromUserMemory(_:)` are
/// covered by `InsightStorageTests`. The `save(...)` / `loadRecent(...)`
/// SwiftData glue is integration code (manual smoke).
@MainActor
final class InsightStorage {

    /// Required tag every insight memory carries. `fromUserMemory` uses
    /// it to disambiguate insights from regular system facts. `nonisolated`
    /// because the pure-func mappers below are `nonisolated` too.
    nonisolated static let insightTag = "insight"

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Pure mappers (TESTABLE)

    /// Convert an insight into the `UserMemory` shape it persists as.
    /// Pure function; safe to call without a SwiftData container.
    /// `nonisolated` so unit tests can drive it from any thread without
    /// hopping to MainActor (the function reads/writes only the passed
    /// struct + a fresh `UserMemory` — no shared state).
    /// `screenContextId` is what makes the row deletable.
    ///
    /// «Delete screen history» selects memories BY this field, and the Obsidian
    /// cleanup runs over the list that selection produces. Leaving it nil meant
    /// every fact the agent derived from the screen survived the wipe AND kept
    /// its exported copy in the user's vault — 1441 of them on the real store.
    nonisolated static func toUserMemory(_ insight: ExtractedInsight,
                                         screenContextId: UUID? = nil) -> UserMemory {
        let mem = UserMemory(
            content: insight.body,
            category: "system",
            sourceApp: insight.sourceApp,
            confidence: insight.confidence,
            screenContextId: screenContextId
        )
        mem.headline = insight.headline
        mem.reasoning = insight.reasoning
        // Tags: required `insight` marker + domain category.
        // Plain CSV — MetaWhisp's existing `tagsCSV` schema.
        mem.tagsCSV = "\(insightTag),\(insight.category)"
        return mem
    }

    /// Recover an insight from a `UserMemory` row, OR `nil` if the row
    /// isn't an insight (lacks the `insight` tag or has been dismissed).
    /// Pure function; `nonisolated` for the same reason as `toUserMemory`.
    nonisolated static func fromUserMemory(_ mem: UserMemory) -> ExtractedInsight? {
        guard !mem.isDismissed else { return nil }
        let tags = (mem.tagsCSV ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard tags.contains(insightTag) else { return nil }

        // Recover domain category from the non-`insight` tag, falling back
        // to "other" if no domain tag is present.
        let domain = tags.first { $0 != insightTag } ?? "other"

        return ExtractedInsight(
            body: mem.content,
            headline: mem.headline,
            reasoning: mem.reasoning,
            category: domain,
            sourceApp: mem.sourceApp,
            confidence: mem.confidence
        )
    }

    // MARK: - SwiftData glue (manual smoke)

    /// Persist an insight as a `UserMemory` row. Idempotent on `id`
    /// (each insight gets a fresh UUID inside the mapper).
    func save(_ insight: ExtractedInsight, screenContextId: UUID? = nil) async {
        let ctx = ModelContext(modelContainer)
        let mem = Self.toUserMemory(insight, screenContextId: screenContextId)
        ctx.insert(mem)
        do {
            try ctx.save()
            NSLog("[InsightStorage] saved: %@", String(insight.body.prefix(80)))
            // ITER-035 v2 — export the insight to Obsidian vault. tagsCSV
            // contains "insight" → exportMemory routes it to Insights/ folder.
            if let exporter = AppDelegate.shared?.obsidianExporter {
                let memID = mem.id
                Task { @MainActor in
                    await exporter.exportMemory(memID)
                }
            }
        } catch {
            NSLog("[InsightStorage] save failed (graceful): %@", error.localizedDescription)
        }
    }

    /// Fetch the last `limit` insights (newest-first) for dedup-window
    /// seeding at app launch. Filters at the SwiftData layer to
    /// `category=system` + non-dismissed; tag check happens in the
    /// pure-function mapper.
    func loadRecent(limit: Int) async -> [ExtractedInsight] {
        let ctx = ModelContext(modelContainer)
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { mem in
                mem.category == "system" && !mem.isDismissed && !mem.needsReview
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Fetch a bit more than `limit` because we'll filter out non-insight
        // system memories (preferences, workhabits, etc) in the mapper.
        desc.fetchLimit = limit * 4
        let rows = (try? ctx.fetch(desc)) ?? []
        return rows
            .compactMap { Self.fromUserMemory($0) }
            .prefix(limit)
            .map { $0 }
    }
}
