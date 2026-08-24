import XCTest
@testable import MetaWhisp

/// OCR moved off the main thread, and kept its output identical while doing it.
///
/// `VNImageRequestHandler.perform` is synchronous and was being called from a
/// `@MainActor` service, so accurate recognition over a full screen stalled
/// whatever the user was doing — a background feature making the foreground
/// stutter.
///
/// Recognition itself needs a real image and a real Vision stack, so what is
/// pinned here is the part that must not drift: the flat text every existing
/// consumer and every stored row already depends on.
final class ScreenOCRTests: XCTestCase {

    private func block(_ text: String, x: Double = 0, y: Double = 0) -> ScreenOCR.Block {
        .init(text: text, x: x, y: y, width: 0.2, height: 0.02, confidence: 0.9)
    }

    /// One line per block, in the order Vision returned them. Changing this
    /// would silently rewrite every screen row already in the user's history.
    func testFlatTextIsUnchangedFromTheOldJoin() {
        let blocks = [block("Hello"), block("world"), block("again")]
        XCTAssertEqual(ScreenOCR.assemble(blocks), "Hello\nworld\nagain")
    }

    func testNoBlocksIsEmptyText() {
        XCTAssertEqual(ScreenOCR.assemble([]), "")
        XCTAssertEqual(ScreenOCR.Reading.empty.text, "")
        XCTAssertTrue(ScreenOCR.Reading.empty.blocks.isEmpty)
    }

    /// Geometry survives. The prompts already ask which chat bubble is on the
    /// right and which field is above the button; until now that was asked of a
    /// model whose input had every coordinate stripped out of it.
    func testBoundsAreCarriedAlongsideTheText() {
        let b = block("Send", x: 0.8, y: 0.1)
        XCTAssertEqual(b.x, 0.8)
        XCTAssertEqual(b.y, 0.1)
        XCTAssertEqual(b.confidence, 0.9)
    }

    /// Blocks are Codable so they can be stored and replayed without a Vision
    /// stack in the test target.
    func testBlocksRoundTripThroughJSON() throws {
        let original = [block("Hello", x: 0.1, y: 0.9), block("world", x: 0.1, y: 0.8)]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([ScreenOCR.Block].self, from: data), original)
    }
}
