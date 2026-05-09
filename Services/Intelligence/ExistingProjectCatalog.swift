import Foundation

/// Builds a short prompt hint listing the user's already-established
/// project canonicals so the LLM can REUSE them when classifying a new
/// conversation, instead of inventing case/typo/format variants.
///
/// ITER-032.1 (2026-05-08): introduced after observing `HallucinatedName`
/// (LLM hallucination from a single session) absorb the real
/// `Example Project`/`ExampleProject.ai` cluster. The LLM had no awareness of
/// existing canonicals → invented arbitrary variants. With this hint
/// in the system prompt, the LLM is instructed to use exact names from
/// the list when the conversation matches.
///
/// Pure function — no I/O. Caller (StructuredGenerator) supplies the
/// (canonical, convCount) tuples from `ProjectAggregator.listProjects`.
enum ExistingProjectCatalog {
    /// Default minimum conversation count for a project to be considered
    /// "established" enough to surface in the hint. Singletons (=1) are
    /// excluded — they're often the noise candidates we want the LLM to
    /// REPLACE with a real existing canonical, not reinforce.
    static let defaultMinConversations: Int = 2
    /// Default cap on rows to include — keeps prompt token cost bounded
    /// for users with many projects.
    static let defaultMaxRows: Int = 30

    /// Returns a hint block ready to append to a system prompt, or empty
    /// string if no qualifying projects.
    ///
    /// - Parameters:
    ///   - rows: `(canonical, convCount)` tuples — typically derived from
    ///     `ProjectAggregator.listProjects(includeSingletons: false)`.
    ///   - minCount: filter — convCount must be ≥ this. Default 2.
    ///   - maxRows: cap — at most this many rows in the output. Default 30.
    static func promptHint(
        from rows: [(canonical: String, convCount: Int)],
        minCount: Int = defaultMinConversations,
        maxRows: Int = defaultMaxRows
    ) -> String {
        let qualified = rows
            .filter { $0.convCount >= minCount }
            .sorted { $0.convCount > $1.convCount }
            .prefix(maxRows)

        guard !qualified.isEmpty else { return "" }

        var lines: [String] = [
            "EXISTING PROJECTS (use these EXACT names if the conversation matches one — do NOT invent variants like 'HallucinatedName' when 'Example Project' already exists):"
        ]
        for r in qualified {
            lines.append("- \(r.canonical) (\(r.convCount) conversations)")
        }
        lines.append(
            "Only invent a NEW project name when the conversation is genuinely about something NONE of these cover."
        )
        return lines.joined(separator: "\n")
    }
}
