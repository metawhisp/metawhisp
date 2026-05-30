import Foundation

/// Keeps the task list usable by hiding stale auto-extracted candidates.
///
/// Background (2026-05-29): screen/voice auto-extraction is valuable and stays
/// ON, but it out-paces review — a real account had 286 `staged` candidates of
/// 625 total tasks, only 8 ever completed. Candidates that sit unreviewed past
/// a week are noise; we hide them from the REVIEW CANDIDATES list.
///
/// Non-destructive by design: "hide" ≠ "delete". The SwiftData row is
/// untouched (recoverable, still counts in exports/search); only the
/// candidates VIEW filters it out. A separate bulk-delete tool handles actual
/// removal when the user explicitly asks.
enum TaskHygiene {
    /// How long an auto-extracted candidate stays visible for review before
    /// it's auto-hidden. User's word: "неделя".
    static let stagedReviewWindowDays: Int = 7

    /// True when an auto-extracted candidate has sat unreviewed longer than the
    /// window and should drop out of the REVIEW CANDIDATES list.
    ///
    /// ONLY applies to `status == "staged"`. Committed tasks, dismissed tasks,
    /// and legacy nil-status rows (treated as committed) are NEVER auto-hidden
    /// — the user owns those; only unreviewed machine guesses expire.
    ///
    /// Pure function — `now` and `windowDays` are injectable for tests.
    static func isStaleUnreviewedCandidate(
        status: String,
        createdAt: Date,
        now: Date = Date(),
        windowDays: Int = stagedReviewWindowDays
    ) -> Bool {
        guard status == "staged" else { return false }
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return createdAt < cutoff
    }
}
