import Foundation

/// Picks the "best" variant from an alias's `aliases` list to be its
/// `canonicalName` — the name displayed in Library / Obsidian / Projects view.
///
/// Old heuristic (ITER-032 morning): canonical = whichever variant the
/// alias accumulated FIRST. Auto-merge winner-pick used `aliases.count`
/// (number of variant strings collected). Result: garbage variants like
/// `HallucinatedName` (LLM hallucination from a single session) ended up as the
/// canonical because they happened to be the surviving root of an over-
/// aggressive Lev merge — even with 0 conversations referencing them.
///
/// New heuristic (ITER-032.2, 2026-05-08): canonical = variant with the
/// most CONVERSATION references. "Example Project" with 24 conversations beats
/// "HallucinatedName" with 0. Tie-broken alphabetically for determinism.
///
/// Pure function — caller (ProjectAggregator) supplies the conversation
/// counts gathered from the DB.
enum AliasCanonicalPicker {
    /// - Parameters:
    ///   - variants: every variant currently stored in `ProjectAlias.aliases`.
    ///   - counts: conversation count per variant (case-insensitive lookup).
    ///     Variants missing from this dict are treated as having 0 references.
    /// - Returns: the variant with highest count, alphabetical tie-break.
    ///   Empty string when `variants` is empty (caller must guard).
    static func pickByConversationCount(
        variants: [String],
        counts: [String: Int]
    ) -> String {
        guard !variants.isEmpty else { return "" }
        // Case-insensitive count map — accept either-cased keys from caller.
        var lower: [String: Int] = [:]
        for (k, v) in counts { lower[k.lowercased()] = v }
        return variants.sorted { a, b in
            let ca = lower[a.lowercased()] ?? 0
            let cb = lower[b.lowercased()] ?? 0
            if ca != cb { return ca > cb }
            // Alphabetical tie-break for determinism.
            return a < b
        }.first ?? variants[0]
    }
}
