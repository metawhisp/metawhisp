import Foundation

/// The pre-creation dedup decision for `ProjectAggregator.resolveCanonical`.
/// Returns `true` if `left` and `right` should be merged into ONE alias row,
/// `false` if they're distinct projects that must coexist.
///
/// **CONSERVATIVE: only canonical-equality is auto-merged.** Anything that
/// requires Levenshtein typo tolerance is left alone here — those cases go
/// through user-controlled merge approval (Layer 3 UI in ProjectDetailView).
///
/// History (2026-05-08 ITER-032.1): the original implementation also
/// auto-merged Lev ≤ 2 with length + digit-token guards. In production it
/// produced false positives like `HallucinatedName` (LLM hallucination from one
/// session) absorbing the real `ExampleProject.ai`/`Example Project` cluster because
/// HallucinatedName happened to have more accumulated variants. The fix prevents
/// such false positives by requiring exact canonical match, and surfaces the
/// borderline cases through user UI instead.
///
/// Decision tree:
/// 1. Either input empty → false.
/// 2. Canonical forms equal (case / translit / emoji / punctuation /
///    whitespace differences only) → true.
/// 3. Otherwise → false. Borderline (Lev ≤ 2) cases are NOT auto-merged.
///
/// Embedding-cosine merge is a SEPARATE path run by
/// `ProjectAggregator.mergeAliases()` Stage 2; it operates on conversation
/// content, not surface form, and stays unchanged.
enum ProjectClusterDecision {
    static func canMerge(_ left: String, _ right: String) -> Bool {
        let l = ProjectAliasNormalizer.canonicalize(left)
        let r = ProjectAliasNormalizer.canonicalize(right)

        // 1. Empty canonical → can't merge anything.
        if l.isEmpty || r.isEmpty { return false }

        // 2. Canonical forms identical → definite merge (translit / case /
        //    emoji / punctuation / whitespace differences only).
        return l == r
    }
}
