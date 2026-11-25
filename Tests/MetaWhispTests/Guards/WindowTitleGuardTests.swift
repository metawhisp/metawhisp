import XCTest
@testable import MetaWhisp

/// ITER-087, owner 2026-11-25 ("I don't like that the name is written twice at the top"; variant A): the app's name is
/// shown once, in the sidebar's header. The main window hides its title text, its title bar is transparent and the
/// wall runs under it; the window buttons sit on the wall just above the sidebar (inside it, the sidebar's rounded
/// corner ran through them). The title itself stays set: Mission Control, the Window menu and VoiceOver still call it
/// MetaWhisp.
final class WindowTitleGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheMainWindowShowsItsNameOnceInTheSidebar() throws {
        let controller = try source("Views/Windows/MainWindowController.swift")
        XCTAssertTrue(controller.contains("window.titleVisibility = .hidden"), "no title text over the sidebar's name")
        XCTAssertTrue(controller.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(controller.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertTrue(controller.contains("window.title = \"MetaWhisp\""), "the window keeps its name for the system")
        let view = try source("Views/Windows/MainWindowView.swift")
        XCTAssertTrue(view.contains("Text(\"MetaWhisp\")"), "the sidebar's header keeps the name")
    }
}
