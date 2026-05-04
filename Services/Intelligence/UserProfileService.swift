import Foundation
import SwiftData

/// Builds the "About Me" view sections from `UserMemory` entries
/// (2026-04-29). Pattern adapted from a reference Mac assistant's
/// AI user-profile service.
///
/// The view lives in `Library → Conversations` (button replacing one of the
/// header counters). On open it calls `buildSections(...)` to produce a list
/// of titled sections (Projects / Preferences / Decisions / Facts) populated
/// from non-dismissed `UserMemory` rows excluding `kind == "person"` (those
/// are about OTHER people, not the user).
///
/// Pure-function logic in `buildSections` is unit-tested
/// (Tests/MetaWhispTests/.../UserProfileServiceTests.swift).
@MainActor
final class UserProfileService {
    /// One section in the About Me view (e.g. Projects, Preferences).
    struct Section: Identifiable {
        let id: String      // == kind, used as stable identifier in ForEach
        let kind: String    // "project" | "preference" | "decision" | "fact"
        let title: String   // Human-readable header ("Projects")
        let entries: [Entry]
    }

    /// One row inside a section. Mirrors the relevant subset of `UserMemory`
    /// so the view doesn't need to import the model directly.
    struct Entry: Identifiable {
        let id: UUID
        let subject: String?
        let characterization: String?
        let content: String
        let sourceApp: String
        let createdAt: Date
    }

    /// Display order for sections. Drives the order in the About Me view.
    /// Sections without entries are dropped.
    private static let sectionOrder: [(kind: String, title: String)] = [
        ("project",    "Projects"),
        ("preference", "Preferences"),
        ("decision",   "Decisions"),
        ("fact",       "Facts"),
    ]

    /// Pure-function: takes raw memories, returns sections ready for the view.
    /// - Excludes dismissed memories.
    /// - Excludes `kind == "person"` (those are about other people, not the user).
    /// - Legacy memories with `kind == nil` go into the Facts section.
    /// - Within each section, newest first.
    /// - Sections with zero entries are omitted from the output.
    static func buildSections(from memories: [UserMemory]) -> [Section] {
        let visible = memories.filter { mem in
            guard !mem.isDismissed else { return false }
            // Drop person-kind memories — they describe other humans, not the user.
            if let k = mem.kind, k == "person" { return false }
            return true
        }
        // Bucket by effective kind (nil → "fact").
        var buckets: [String: [UserMemory]] = [:]
        for mem in visible {
            let key = mem.kind ?? "fact"
            buckets[key, default: []].append(mem)
        }
        var out: [Section] = []
        for (kind, title) in sectionOrder {
            guard let rows = buckets[kind], !rows.isEmpty else { continue }
            let sorted = rows.sorted { $0.createdAt > $1.createdAt }
            let entries = sorted.map { mem in
                Entry(
                    id: mem.id,
                    subject: mem.subject,
                    characterization: mem.characterization,
                    content: mem.content,
                    sourceApp: mem.sourceApp,
                    createdAt: mem.createdAt
                )
            }
            out.append(Section(id: kind, kind: kind, title: title, entries: entries))
        }
        return out
    }

    /// Convenience runtime entry: pulls memories out of SwiftData and runs
    /// `buildSections` on the live data. View calls this on open + on
    /// `.refreshable`.
    static func currentSections(in container: ModelContainer) -> [Section] {
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 1000
        let all = (try? ctx.fetch(desc)) ?? []
        return buildSections(from: all)
    }
}
