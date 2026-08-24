import XCTest
@testable import MetaWhisp

/// Whether what is on screen actually changed.
///
/// Capture fires on the window title moving, so a new message in an open Slack
/// channel — same app, same title — is never captured at all. The other half of
/// that problem is the opposite: a caret blinking, a clock in a toolbar or a
/// spinner would make every tick look like new content and re-run OCR and a
/// model call forever.
///
/// The spec is explicit about which way to err: prefer missing a change to
/// re-running continuously.
final class ScreenContentFingerprintTests: XCTestCase {

    private let side = 64

    /// A flat field with a block of "text" drawn into it.
    private func frame(fill: UInt8 = 200,
                       marks: [(x: Int, y: Int, w: Int, h: Int, v: UInt8)] = []) -> [UInt8] {
        var px = [UInt8](repeating: fill, count: side * side)
        for m in marks {
            for y in m.y..<min(m.y + m.h, side) {
                for x in m.x..<min(m.x + m.w, side) {
                    px[y * side + x] = m.v
                }
            }
        }
        return px
    }

    private func fp(_ pixels: [UInt8]) -> ScreenContentFingerprint {
        ScreenContentFingerprint(pixels: pixels, width: side, height: side)
    }

    func testTheSameFrameIsNotAChange() {
        let a = fp(frame(marks: [(4, 4, 20, 8, 20)]))
        XCTAssertFalse(a.differs(from: a))
    }

    /// A caret blinking on and off is the single most common way a static
    /// screen looks different from one tick to the next.
    func testABlinkingCaretIsNotAChange() {
        let base = frame(marks: [(4, 4, 20, 8, 20)])
        let withCaret = frame(marks: [(4, 4, 20, 8, 20), (26, 5, 1, 6, 20)])
        XCTAssertFalse(fp(base).differs(from: fp(withCaret)),
                       "a one-pixel-wide caret must not re-run OCR and a model call")
    }

    /// A new message arriving in an open channel: same app, same title, and
    /// today nothing notices it at all.
    func testANewBlockOfTextIsAChange() {
        let before = frame(marks: [(4, 4, 40, 8, 20)])
        let after = frame(marks: [(4, 4, 40, 8, 20), (4, 20, 40, 8, 20)])
        XCTAssertTrue(fp(before).differs(from: fp(after)),
                      "a new message in the same window has to be noticed")
    }

    func testAnEntirelyDifferentScreenIsAChange() {
        XCTAssertTrue(fp(frame(fill: 20)).differs(from: fp(frame(fill: 230))))
    }

    /// Scrolling moves everything — unmistakably new content.
    func testScrollingIsAChange() {
        let before = frame(marks: [(4, 4, 40, 10, 20), (4, 20, 40, 10, 20)])
        let after = frame(marks: [(4, 14, 40, 10, 20), (4, 30, 40, 10, 20)])
        XCTAssertTrue(fp(before).differs(from: fp(after)))
    }

    /// A window resize changes the sample geometry. There is nothing to compare,
    /// and guessing "unchanged" would strand a window that really did change.
    func testADifferentSizeIsAlwaysAChange() {
        let small = ScreenContentFingerprint(pixels: [UInt8](repeating: 100, count: 16), width: 4, height: 4)
        XCTAssertTrue(fp(frame()).differs(from: small))
    }

    /// Equal fingerprints must be usable as the coordinator's content hash.
    func testEqualFramesShareAHash() {
        let a = fp(frame(marks: [(4, 4, 20, 8, 20)]))
        let b = fp(frame(marks: [(4, 4, 20, 8, 20)]))
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(a, b)
    }

    /// An empty or malformed buffer must not crash or read as a change against
    /// itself.
    func testDegenerateInputIsHandled() {
        let empty = ScreenContentFingerprint(pixels: [], width: 0, height: 0)
        XCTAssertFalse(empty.differs(from: empty))
        let truncated = ScreenContentFingerprint(pixels: [1, 2, 3], width: 64, height: 64)
        XCTAssertFalse(truncated.differs(from: truncated))
    }
}
