import AppKit
import XCTest
@testable import MetaWhisp

/// The main window's lifetime (2026-10-19): a closed window is released, never kept hidden — a hidden window keeps
/// the Space it was last on, and a show there switches the user to it — and the next open makes a new window around
/// the same content, so the tab, the scroll positions and a draft stay where the user left them.
@MainActor
final class MainWindowControllerTests: XCTestCase {
    private func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Open, close, open: the second window is another object; the content is the same view, kept across the close;
    /// between the two there is no window at all.
    func testAClosedWindowIsReleasedAndItsContentReturnsInANewOne() throws {
        let controller = MainWindowController()
        let content = NSView()
        var made = 0
        controller.open(tab: nil) { made += 1; return content }
        let first = try XCTUnwrap(controller.window)
        XCTAssertTrue(first.isVisible)
        XCTAssertTrue(first.contentView === content)
        XCTAssertEqual(made, 1)

        controller.close()
        settle()
        XCTAssertNil(controller.window, "a closed window is released, not kept hidden")
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(first.contentView === content, "the content left the closed window")
        XCTAssertTrue(controller.content === content, "the content is kept for the next window")

        controller.open(tab: nil) { made += 1; return NSView() }
        let second = try XCTUnwrap(controller.window)
        XCTAssertFalse(second === first, "a new window")
        XCTAssertTrue(second.contentView === content, "around the same content")
        XCTAssertEqual(made, 1, "the content is made once")
        XCTAssertTrue(second.isVisible)
        controller.close()
        settle()
        XCTAssertNil(controller.window)
    }

    /// A window left visible on another Space is closed, not ordered out: nothing of the app stays on that Space.
    func testAWindowLeftOnAnotherSpaceIsClosed() throws {
        XCTAssertEqual(WindowSpaceResidency.decide(isVisible: true, isOnActiveSpace: false, appIsActive: false), .unbind)
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // Windows, Views, MetaWhispTests, Tests, the root
        url.appendPathComponent("Views/Windows/MainWindowController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let unbind = try XCTUnwrap(source.range(of: "func unbindIfLeftBehind()"))
        let body = source[unbind.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("window.close()"), "closed for real: \(body)")
        XCTAssertFalse(body.contains("orderOut"), "never hidden: \(body)")
    }
}
