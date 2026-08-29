import XCTest
@testable import MetaWhisp

/// Capture fires when the window title moves. A new message arriving in an
/// already-open channel moves nothing — same app, same title, same frame — so
/// the agent has never seen one. `ScreenContentFingerprint` was written for
/// exactly this and has never been called from production.
///
/// This is the piece that was missing between them: how often to look, and what
/// counts as an answer.
final class SameWindowProbeTests: XCTestCase {

    private func fingerprint(_ value: UInt8) -> ScreenContentFingerprint {
        ScreenContentFingerprint(pixels: [UInt8](repeating: value, count: 64),
                                 width: 8, height: 8)
    }

    /// The first look establishes what the window looks like. Calling that a
    /// change would capture every window the moment it goes quiet — the exact
    /// storm this probe exists to avoid.
    func testTheFirstLookIsABaselineNotAChange() {
        var probe = SameWindowProbe()
        XCTAssertFalse(probe.contentMoved(to: fingerprint(10), at: Date()))
    }

    func testAnUnchangedWindowStaysQuiet() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.contentMoved(to: fingerprint(10), at: start)
        XCTAssertFalse(probe.contentMoved(to: fingerprint(10), at: start.addingTimeInterval(30)))
    }

    /// The whole point: something happened inside the window and nothing in the
    /// title said so.
    func testANewMessageInAnOpenChannelIsSeen() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.contentMoved(to: fingerprint(10), at: start)
        XCTAssertTrue(probe.contentMoved(to: fingerprint(200), at: start.addingTimeInterval(30)))
    }

    /// A screenshot costs something, so the cadence is checked before one is
    /// taken rather than after.
    func testLookingIsRateLimited() {
        var probe = SameWindowProbe()
        let start = Date()
        XCTAssertTrue(probe.shouldLook(at: start), "the first tick has nothing to wait for")
        _ = probe.contentMoved(to: fingerprint(10), at: start)
        XCTAssertFalse(probe.shouldLook(at: start.addingTimeInterval(1)))
        XCTAssertTrue(probe.shouldLook(
            at: start.addingTimeInterval(ScreenAgentTimingPolicy.sameWindowProbeSeconds + 0.1)))
    }

    /// Comparing one window's picture against another's would report a change
    /// every single time. The baseline belongs to the window it was taken from.
    func testChangingWindowDropsTheBaseline() {
        var probe = SameWindowProbe()
        let start = Date()
        _ = probe.contentMoved(to: fingerprint(10), at: start)
        probe.reset()
        XCTAssertFalse(probe.contentMoved(to: fingerprint(200), at: start.addingTimeInterval(30)),
                       "a fresh window starts with a baseline, not with a verdict")
    }
}
