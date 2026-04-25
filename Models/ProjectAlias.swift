import Foundation
import SwiftData

/// Canonical project name + its observed aliases. Merging table for
/// `Conversation.primaryProject` strings so "Overchat", "Оверчат", "overchat"
/// all collapse to ONE Project in the Projects view.
///
/// Created lazily by `ProjectAggregator` — the first time a new project name
/// appears in a conversation, we insert a row with canonical = name and aliases = [name].
/// Subsequent variants get added to `aliasesJSON` either by exact-string match
/// (case-insensitive) or by embedding-similarity merge during the periodic
/// `mergeAliases()` pass.
///
/// We do NOT mutate `Conversation.primaryProject` itself — that stays as the
/// raw LLM output (audit trail). All grouping queries route raw → canonical
/// through `ProjectAggregator.resolveCanonical(_:)`.
///
/// spec://iterations/ITER-014-project-clustering
@Model
final class ProjectAlias {
    var id: UUID
    /// Display name — chosen from the FIRST observed variant (or user-edited later).
    var canonicalName: String
    /// JSON `[String]` of all observed aliases. Always includes `canonicalName`.
    /// Stored as JSON to keep schema flat (SwiftData doesn't love String arrays).
    var aliasesJSON: String
    var createdAt: Date
    var updatedAt: Date
    /// Average of all conversation embeddings tagged with this project (or any alias).
    /// Used by `mergeAliases()` to detect "Overchat" vs "Overchat AI" as the same thing
    /// without hardcoding rules. Nil while no conversation has been embedded yet.
    var centroidEmbedding: Data?

    init(canonicalName: String) {
        self.id = UUID()
        self.canonicalName = canonicalName
        // Initial aliases list always contains the canonical name itself.
        let arr = [canonicalName]
        self.aliasesJSON = (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[\"\(canonicalName)\"]"
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Decoded list of aliases. Always includes `canonicalName` if data is well-formed.
    var aliases: [String] {
        guard let data = aliasesJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return [canonicalName]
        }
        return arr
    }

    /// Append a new alias if not already present (case-insensitive). Updates `updatedAt`.
    /// Returns true if newly added.
    @discardableResult
    func addAlias(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var existing = aliases
        if existing.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return false
        }
        existing.append(trimmed)
        aliasesJSON = (try? String(data: JSONEncoder().encode(existing), encoding: .utf8)) ?? aliasesJSON
        updatedAt = Date()
        return true
    }
}
