import XCTest
@testable import MetaWhisp

/// Telling "the screen was blank" apart from "we could not read the screen".
///
/// Today they are the same thing. A failed ScreenCaptureKit grab returns a
/// snapshot carrying the app name, the window title and an empty OCR string —
/// indistinguishable from a genuinely empty window. That row is persisted, the
/// capture mark advances so the window is never retried, and the agent is woken
/// up for a frame nobody ever managed to read.
///
/// Persistence has the same shape: `try? ctx.save()` and then the callback
/// fires whether or not anything was written, so the agent can be reasoning
/// about a row that does not exist.
final class ScreenCaptureOutcomeTests: XCTestCase {

    // MARK: what may reach the agent

    func testOnlyACapturedFrameReachesTheAgent() {
        XCTAssertTrue(ScreenCaptureOutcome.captured(ocrCharacters: 120).deliversToAgent)
    }

    /// An empty screen is a real, readable answer — the agent should see it and
    /// decide there is nothing to say. It is not a failure.
    func testAnEmptyScreenIsAnAnswerNotAFailure() {
        let empty = ScreenCaptureOutcome.captured(ocrCharacters: 0)
        XCTAssertTrue(empty.deliversToAgent)
        XCTAssertFalse(empty.isFailure)
    }

    func testNoFailureModeReachesTheAgent() {
        for outcome: ScreenCaptureOutcome in [
            .permissionDenied, .ambiguousWindow, .captureFailed, .persistenceFailed
        ] {
            XCTAssertFalse(outcome.deliversToAgent, "\(outcome) must not wake the agent")
            XCTAssertTrue(outcome.isFailure, "\(outcome) is not a successful read")
        }
    }

    /// An excluded app is the user's policy working, not something going wrong.
    /// It must not wake the agent and must not be counted as a failure either —
    /// health reporting that calls a working exclusion an error teaches people
    /// to ignore it.
    func testAnExcludedAppIsNotAFailure() {
        XCTAssertFalse(ScreenCaptureOutcome.excluded.deliversToAgent)
        XCTAssertFalse(ScreenCaptureOutcome.excluded.isFailure)
    }

    // MARK: what may consume the window's turn

    /// The retry rule. A window the app could not read has to stay eligible for
    /// the next poll — otherwise a single failure silences that window until
    /// the user happens to switch away and back.
    func testAFailedReadDoesNotConsumeTheWindow() {
        for outcome: ScreenCaptureOutcome in [.permissionDenied, .ambiguousWindow,
                                              .captureFailed, .persistenceFailed] {
            XCTAssertFalse(outcome.consumesWindowTurn,
                           "\(outcome) must leave the window eligible to retry")
        }
    }

    func testASuccessfulReadConsumesTheWindow() {
        XCTAssertTrue(ScreenCaptureOutcome.captured(ocrCharacters: 0).consumesWindowTurn)
    }

    /// An excluded app is a settled decision, not a failure to retry — polling
    /// it every tick would just burn work to reach the same answer.
    func testAnExcludedAppIsSettled() {
        XCTAssertTrue(ScreenCaptureOutcome.excluded.consumesWindowTurn)
    }

    // MARK: diagnosis

    /// Each outcome reports a stable reason code, so the log says why a window
    /// produced nothing without carrying any of its content.
    func testEveryOutcomeHasADistinctReasonCode() {
        let all: [ScreenCaptureOutcome] = [
            .captured(ocrCharacters: 1), .excluded, .permissionDenied,
            .ambiguousWindow, .captureFailed, .persistenceFailed
        ]
        let codes = all.map(\.reasonCode)
        XCTAssertEqual(Set(codes).count, all.count, "reason codes must be distinguishable")
        XCTAssertFalse(codes.contains { $0.isEmpty })
    }
}
