import Foundation

/// ITER-056 — GitHub star promo lifecycle (founder spec 2026-07-15).
/// The block lives at the bottom of Settings → Account:
///   stage 0 — never clicked: visible, NO close button (the only way past it
///             is actually starring);
///   stage 1 — Star was clicked: still visible (this session and every next
///             launch) but now WITH ✕ so it can be dismissed without clicking;
///   stage 2 — ✕ clicked: hidden forever.
/// Persisted via `AppSettings.githubStarStage`.
enum GitHubStarPromo {
    static func isVisible(stage: Int) -> Bool { stage < 2 }
    static func showsClose(stage: Int) -> Bool { stage == 1 }
    /// Star clicked → advance to stage 1 (never regresses a dismissed state).
    static func afterStarClick(stage: Int) -> Int { max(stage, 1) }
    /// ✕ clicked → hidden forever.
    static func afterCloseClick(stage: Int) -> Int { 2 }
}
