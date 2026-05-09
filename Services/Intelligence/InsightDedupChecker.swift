import Foundation

/// Pure-function dedup gate. Compares a candidate insight against recent
/// ones and rejects if too similar.
///
/// v1 strategy (ITER-027.1, 2026-05-09): normalized-edit-distance similarity
/// ratio. Cheap and runs without any model. Catches wording variations of
/// the same insight (typical model variance). Misses semantic-only dups
/// (different words, same idea) — those require embedding cosine, planned
/// for v2 once we wire `EmbeddingService` into this gate.
///
/// Reference: Omi's `InsightAssistant.handleResultWithScreenshot` keeps a
/// rolling `previousInsights` array and runs a similar check before saving
/// + notifying. Default threshold 0.75 — loose enough to catch rephrasings,
/// strict enough to allow genuinely different insights through.
enum InsightDedupChecker {
    /// Default similarity threshold above which two insight bodies count as
    /// duplicates. Calibrated to catch rephrasings of the same idea.
    static let defaultSimilarityThreshold: Double = 0.75

    /// Returns `true` iff `candidate` is similar enough to ANY entry in
    /// `recent` to count as a duplicate. Caller suppresses the surface.
    ///
    /// - Parameters:
    ///   - candidate: the freshly-extracted insight under consideration.
    ///   - recent: rolling window of last N issued insights (Omi default 50).
    ///   - similarityThreshold: 0.0–1.0; higher = stricter (fewer dups caught).
    static func isDuplicate(
        candidate: ExtractedInsight,
        recent: [ExtractedInsight],
        similarityThreshold: Double = defaultSimilarityThreshold
    ) -> Bool {
        let candKey = candidate.body.lowercased()
        for prior in recent {
            let priorKey = prior.body.lowercased()
            if candKey == priorKey { return true }
            if similarityRatio(candKey, priorKey) >= similarityThreshold { return true }
        }
        return false
    }

    /// Normalized similarity in [0, 1] where 1.0 = identical.
    /// Computed as `1 - editDistance / maxLength`.
    private static func similarityRatio(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 && n == 0 { return 1.0 }
        if m == 0 || n == 0 { return 0.0 }

        // Wagner-Fischer single-row DP — same algorithm as Levenshtein.swift,
        // inlined to avoid circular module references and keep this gate
        // self-contained.
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        let dist = Double(prev[n])
        let maxLen = Double(max(m, n))
        return 1.0 - (dist / maxLen)
    }
}
