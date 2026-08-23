import XCTest
@testable import MetaWhisp

/// ITER-064A.3 — the capture loop only works on a *changed* window, so the
/// "last seen" mark decides what gets a second chance.
///
/// The old code advanced that mark immediately after the change check and
/// before the capture await. A capture that then failed — permission blip,
/// ScreenCaptureKit error, the window vanishing — consumed the change anyway,
/// so the window was never retried until the user happened to switch away and
/// back. A long-lived window could lose its only capture attempt permanently.
///
/// These pin the rule: only an accepted frame advances the mark.
final class CaptureHighWaterMarkTests: XCTestCase {

    func testFirstSightIsAlwaysAChange() {
        let mark = CaptureHighWaterMark()
        XCTAssertTrue(mark.hasChanged(appName: "Slack", windowTitle: "#launch"))
    }

    func testAcceptedFrameConsumesTheChange() {
        var mark = CaptureHighWaterMark()
        mark.accept(appName: "Slack", windowTitle: "#launch")
        XCTAssertFalse(mark.hasChanged(appName: "Slack", windowTitle: "#launch"))
    }

    /// The defect this iteration fixes: a failed capture must leave the change
    /// pending so the very next poll tries the same window again.
    func testFailedCaptureLeavesTheChangePending() {
        var mark = CaptureHighWaterMark()
        XCTAssertTrue(mark.hasChanged(appName: "Slack", windowTitle: "#launch"))
        // capture failed → `accept` is never called
        XCTAssertTrue(mark.hasChanged(appName: "Slack", windowTitle: "#launch"),
                      "a failed capture must not consume the window change")
        mark.accept(appName: "Slack", windowTitle: "#launch")
        XCTAssertFalse(mark.hasChanged(appName: "Slack", windowTitle: "#launch"))
    }

    func testEitherAppOrTitleChangeCounts() {
        var mark = CaptureHighWaterMark()
        mark.accept(appName: "Slack", windowTitle: "#launch")
        XCTAssertTrue(mark.hasChanged(appName: "Slack", windowTitle: "#random"))
        XCTAssertTrue(mark.hasChanged(appName: "Safari", windowTitle: "#launch"))
    }

    /// The frame that actually came back is the truth, not what was seen
    /// before the await — the user can switch apps mid-capture.
    func testAcceptRecordsTheCapturedWindowNotTheRequestedOne() {
        var mark = CaptureHighWaterMark()
        // asked about Slack, the frame that came back was Safari
        mark.accept(appName: "Safari", windowTitle: "Docs")
        XCTAssertFalse(mark.hasChanged(appName: "Safari", windowTitle: "Docs"))
        XCTAssertTrue(mark.hasChanged(appName: "Slack", windowTitle: "#launch"),
                      "Slack was never captured, so it is still a pending change")
    }
}
