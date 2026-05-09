import XCTest
@testable import MetaWhisp

/// Pure-function tests for `InsightDedupChecker.isDuplicate(...)`.
///
/// History (ITER-027.1, 2026-05-09): Omi's pattern keeps a rolling array of
/// the last N issued insights and rejects new ones whose body is too similar.
/// Without dedup, a long-running session would surface the same "stash from
/// 2h ago" tip every 10 minutes — instant water.
///
/// We don't pull in a full embedding service for v1 — instead we use a
/// cheap normalized-edit-distance ratio. Good enough to catch wording
/// variations of the same insight; misses semantic-only dups (those need
/// embedding cosine, deferred to v2).
final class InsightDedupCheckerTests: XCTestCase {

    private func mk(_ body: String) -> ExtractedInsight {
        ExtractedInsight(
            body: body, headline: nil, reasoning: nil,
            category: "other", sourceApp: "Test", confidence: 0.9
        )
    }

    /// Empty recent list → no duplicate possible.
    func test_emptyRecentList() {
        XCTAssertFalse(InsightDedupChecker.isDuplicate(
            candidate: mk("You stashed changes 2 hours ago"),
            recent: []
        ))
    }

    /// Exact same body → duplicate.
    func test_exactMatch() {
        let prior = mk("You stashed changes 2 hours ago")
        XCTAssertTrue(InsightDedupChecker.isDuplicate(
            candidate: mk("You stashed changes 2 hours ago"),
            recent: [prior]
        ))
    }

    /// Case-insensitive match → still duplicate.
    func test_caseInsensitive() {
        XCTAssertTrue(InsightDedupChecker.isDuplicate(
            candidate: mk("YOU STASHED CHANGES 2 HOURS AGO"),
            recent: [mk("you stashed changes 2 hours ago")]
        ))
    }

    /// Wording variations on the same idea — share canonical core → dup.
    /// Both about uncommitted git changes from a couple hours ago.
    func test_minorWordingVariation() {
        XCTAssertTrue(InsightDedupChecker.isDuplicate(
            candidate: mk("You stashed changes 2 hours ago — remember git stash pop"),
            recent: [mk("You stashed changes 2 hours ago — remember to git stash pop")]
        ))
    }

    /// Genuinely different insights stay separate.
    func test_differentInsightsNotDuplicate() {
        XCTAssertFalse(InsightDedupChecker.isDuplicate(
            candidate: mk("Sensitive credentials visible in terminal"),
            recent: [
                mk("You stashed changes 2 hours ago"),
                mk("npm tokens expiring tomorrow")
            ]
        ))
    }

    /// Tunable threshold: lower threshold catches more dups; higher
    /// threshold demands near-identical strings.
    func test_thresholdTuning() {
        // Loose (0.5) — catches anything moderately similar.
        XCTAssertTrue(InsightDedupChecker.isDuplicate(
            candidate: mk("You stashed changes 2 hours ago"),
            recent: [mk("You stashed changes 3 hours ago")],
            similarityThreshold: 0.5
        ))
        // Very strict (0.99) — even one-char differences fall below the
        // bar (this pair is ~0.97 similar by edit-distance ratio), so the
        // dedup check returns false and the surface is allowed.
        XCTAssertFalse(InsightDedupChecker.isDuplicate(
            candidate: mk("You stashed changes 2 hours ago"),
            recent: [mk("You stashed changes 3 hours ago")],
            similarityThreshold: 0.99
        ))
    }
}
