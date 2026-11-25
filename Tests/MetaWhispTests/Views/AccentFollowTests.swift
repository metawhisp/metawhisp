import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// ITER-087, owner on the test build (2026-11-25): "when I switch to Violet, everything must take the violet hue,
/// not just part of it; in Violet there must be no green". The switches turned violet, but the selections and
/// the wall's glow stayed mint: they read the accent from a static token, so SwiftUI never knew to draw them again.
/// These draw the shared primitives off screen, change the accent, and read a pixel back.
@MainActor
final class AccentFollowTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: "accentColor")
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: "accentColor") } else {
            UserDefaults.standard.removeObject(forKey: "accentColor")
        }
        super.tearDown()
    }

    func testASelectionTakesTheNewAccentWhenItChanges() throws {
        let view = Color.clear.frame(width: 120, height: 60)
            .mwSelectable(true, radius: 8, resting: .none)
            .padding(10)
            .background(Color.black)
        try assertFollowsTheAccent(view, size: NSSize(width: 140, height: 80), at: CGPoint(x: 70, y: 40))
    }

    func testTheWallsGlowTakesTheNewAccentWhenItChanges() throws {
        try assertFollowsTheAccent(PageWash(), size: NSSize(width: 400, height: 300), at: CGPoint(x: 392, y: 4))
    }

    /// Owner, 2026-11-25: the meeting-minutes bar stayed violet after he chose Orange. Any view that draws with a
    /// colour token — here a plain view with no inputs that change — must draw again when the accent changes.
    func testAnyViewDrawnWithATokenFollowsTheAccent() throws {
        try assertFollowsTheAccent(StatusLeaf().padding(10).background(Color.black),
                                   size: NSSize(width: 140, height: 80), at: CGPoint(x: 70, y: 40))
    }

    /// The same for the look: a view that draws with a palette token must follow a change of the appearance.
    func testAnyViewDrawnWithATokenFollowsTheTheme() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua)), light = try XCTUnwrap(NSAppearance(named: .aqua))
        app.appearance = dark
        let size = NSSize(width: 140, height: 80)
        let host = NSHostingView(rootView: FillLeaf().padding(10).background(Color.black))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.setFrameSize(size)
        let inDark = try pixel(of: host, at: CGPoint(x: 70, y: 40))
        XCTAssertLessThan(inDark.green, 0.3, "a raised fill in the dark look is a faint white: \(inDark)")
        app.appearance = light
        let inLight = try pixel(of: host, at: CGPoint(x: 70, y: 40))
        XCTAssertGreaterThan(inLight.green, 0.9, "the same view in the light look is white: \(inLight)")
    }

    /// Mint first, then Violet, in the same live view: the pixel must lean green, then lean violet.
    private func assertFollowsTheAccent(_ view: some View, size: NSSize, at point: CGPoint,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        AppSettings.shared.accentColor = "mint"
        let look = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = look
        defer { app.appearance = previous }
        let host = NSHostingView(rootView: view)
        host.appearance = look
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        defer { window.close() }
        host.setFrameSize(size)

        let mint = try pixel(of: host, at: point)
        XCTAssertGreaterThan(mint.green, mint.blue, "mint first: \(mint)", file: file, line: line)

        AppSettings.shared.accentColor = "violet"
        let violet = try pixel(of: host, at: point)
        XCTAssertGreaterThan(violet.blue, violet.green, "the same view after the change must be violet: \(violet)",
                             file: file, line: line)
    }

    private func pixel(of host: NSHostingView<some View>, at point: CGPoint) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let colour = try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        return (colour.redComponent, colour.greenComponent, colour.blueComponent)
    }
}

/// A plain view with no inputs, drawn with the status colour — like the meeting-minutes bar.
private struct StatusLeaf: View {
    var body: some View { Rectangle().fill(MW.ok).frame(width: 120, height: 60) }
}

/// A plain view with no inputs, drawn with a palette fill.
private struct FillLeaf: View {
    var body: some View { Rectangle().fill(MW.elevated).frame(width: 120, height: 60) }
}
