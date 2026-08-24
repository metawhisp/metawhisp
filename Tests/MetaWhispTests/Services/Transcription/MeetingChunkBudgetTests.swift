import XCTest
@testable import MetaWhisp

/// The root cause of the 2026-08-24 losses was two constants that did not know
/// about each other: the finalize pass cut meetings into chunks of up to
/// `targetChunkSec` seconds, and every transcribe request got a flat 60-second
/// budget. Nothing in the code or the tests connected them, so the chunk size
/// could grow past what the budget could deliver and nobody found out until a
/// user's meeting came back with holes.
///
/// This is the missing link. It fails if either constant moves without the
/// other.
final class MeetingChunkBudgetTests: XCTestCase {

    /// Successful chunks that morning ran at roughly 0.9× realtime or better
    /// (66.8s of audio came back inside the 60s budget). Anything the chunker
    /// can emit must get at least 1.5× its own duration to come back in.
    func testEveryChunkTheSplitterCanEmitFitsItsBudget() {
        let longest = Double(AppDelegate.meetingTargetChunkSec)
        let budget = CloudWhisperEngine.requestTimeout(forAudioSeconds: longest)
        XCTAssertGreaterThanOrEqual(
            budget, longest * 1.5,
            "a \(longest)s chunk gets only \(budget)s — raise the budget or lower the chunk size")
    }

    /// The budget has a ceiling, so a chunk size above it silently loses the
    /// proportionality this whole fix depends on.
    func testChunkSizeStaysUnderTheBudgetCeiling() {
        let longest = Double(AppDelegate.meetingTargetChunkSec)
        XCTAssertLessThan(
            CloudWhisperEngine.requestTimeout(forAudioSeconds: longest), 600,
            "chunk size has grown into the timeout ceiling — the budget stops scaling here")
    }

    /// The chunk lengths that actually failed in production must now fit.
    func testTheProductionFailuresWouldNowFit() {
        for seconds in [104.8, 149.4, 167.9] {
            XCTAssertGreaterThanOrEqual(
                CloudWhisperEngine.requestTimeout(forAudioSeconds: seconds), seconds * 1.5)
        }
    }
}
