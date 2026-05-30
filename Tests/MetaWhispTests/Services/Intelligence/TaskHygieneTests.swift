import XCTest
@testable import MetaWhisp

/// Tests for `TaskHygiene` — auto-hiding stale unreviewed task candidates.
///
/// User decision 2026-05-29: auto-extraction stays ON, but staged candidates
/// (auto-extracted, awaiting review) that sit unreviewed for >7 days are
/// hidden from the REVIEW list so the pile stops overwhelming the user
/// (had 286 staged / 625 total, only 8 ever completed).
///
/// Non-destructive: hidden ≠ deleted. Rows stay in SwiftData (recoverable);
/// only the candidates VIEW excludes them.
final class TaskHygieneTests: XCTestCase {

    private func daysAgo(_ d: Double, from now: Date = Date()) -> Date {
        now.addingTimeInterval(-d * 86_400)
    }

    // MARK: - Only staged candidates auto-hide

    func test_freshStaged_notHidden() {
        let now = Date()
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: daysAgo(3, from: now), now: now))
    }

    func test_oldStaged_hidden() {
        let now = Date()
        XCTAssertTrue(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: daysAgo(8, from: now), now: now))
    }

    /// Boundary: exactly 7 days = still visible (cutoff is strict `<`).
    func test_exactlySevenDays_notHidden() {
        let now = Date()
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: daysAgo(7, from: now), now: now))
    }

    /// Just past 7 days → hidden.
    func test_sevenDaysPlusEpsilon_hidden() {
        let now = Date()
        let justOver = now.addingTimeInterval(-(7 * 86_400 + 60))  // 7d + 1min
        XCTAssertTrue(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: justOver, now: now))
    }

    // MARK: - Non-staged statuses are NEVER auto-hidden

    func test_committedOld_neverHidden() {
        let now = Date()
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "committed", createdAt: daysAgo(90, from: now), now: now))
    }

    func test_dismissedOld_neverHidden() {
        let now = Date()
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "dismissed", createdAt: daysAgo(90, from: now), now: now))
    }

    func test_legacyNilStatusOld_neverHidden() {
        // Legacy rows treated as committed — must not be auto-hidden.
        let now = Date()
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "committed", createdAt: daysAgo(365, from: now), now: now))
    }

    // MARK: - Configurable window

    func test_customWindow() {
        let now = Date()
        // 5 days old, window 3 → hidden
        XCTAssertTrue(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: daysAgo(5, from: now), now: now, windowDays: 3))
        // 5 days old, window 14 → visible
        XCTAssertFalse(TaskHygiene.isStaleUnreviewedCandidate(
            status: "staged", createdAt: daysAgo(5, from: now), now: now, windowDays: 14))
    }

    // MARK: - Default window matches the user's "неделя"

    func test_defaultWindowIsSevenDays() {
        XCTAssertEqual(TaskHygiene.stagedReviewWindowDays, 7)
    }
}
