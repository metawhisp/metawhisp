import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// The real hotkey controls drawn to PNG without ordering a window.
@MainActor
final class MainSettingsHotkeyRenderTests: XCTestCase {
    func testRenderHotkeyControls() throws {
        guard let folder = ProcessInfo.processInfo.environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the hotkey control renders.")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try render("hotkeys-all-on", in: directory, transcribe: true, translate: true, mode: "toggle")
        try render("hotkeys-two-off", in: directory, transcribe: false, translate: false, mode: "toggle")
        try render("hotkeys-push-to-talk", in: directory, transcribe: true, translate: true, mode: "pushToTalk")
    }

    private func render(_ name: String, in directory: URL, transcribe: Bool, translate: Bool, mode: String) throws {
        let look = try XCTUnwrap(NSAppearance(named: .darkAqua))
        // The design tokens read the app's appearance; restore it after the render.
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = look
        defer { app.appearance = previous }
        let view = MainSettingsView.hotkeyControls(
            transcribe: .constant(transcribe), translate: .constant(translate),
            voiceQuestion: .constant(true), autoTranslate: .constant(true), mode: .constant(mode))
            .padding(24)
            .frame(width: 640)
            .background(MW.bg)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = look
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        defer { window.close() }
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible, name)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
