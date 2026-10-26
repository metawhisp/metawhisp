import AppKit
import XCTest

/// PRD P1 15 — the DMG opens as one window: MetaWhisp on the left, Applications on the right, an arrow from one to
/// the other on the background. make-dmg-manual.sh puts the background in the image's hidden .background folder and
/// has Finder lay the window out (scripts/dmg-layout.applescript), on the writable image before it is compressed.
/// Read from the files: building a DMG mounts images, which a test never does.
final class DMGLayoutTests: XCTestCase {

    /// Where the background puts its arrow, and the layout its icons: Finder positions are icon centres.
    private let appIcon = CGPoint(x: 160, y: 170)
    private let applicationsIcon = CGPoint(x: 500, y: 170)

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Scripts/DMGLayoutTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The mean brightness (0 black … 255 white) of a square around a point, top-left origin.
    private func brightness(around point: CGPoint, radius: Int, in image: CGImage) throws -> Double {
        let side = radius * 2 + 1
        var pixels = [UInt8](repeating: 0, count: side * side)
        // CoreGraphics draws bottom-up: place the image so the square lands on the context.
        let originX = -(Int(point.x) - radius)
        let originY = -(image.height - (Int(point.y) + radius + 1))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: originX, y: originY, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "the square was read")
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// The background is the window's size and carries a dark arrow between the two icons, leaving the icons' own
    /// places clear.
    func testTheBackgroundHasTheArrowBetweenTheIcons() throws {
        let url = repoRoot.appendingPathComponent("Resources/dmg-background.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 660)
        XCTAssertEqual(image.height, 400)
        for x in stride(from: 250, through: 400, by: 30) {
            XCTAssertLessThan(try brightness(around: CGPoint(x: x, y: 170), radius: 2, in: image), 80,
                              "the arrow's shaft at x=\(x)")
        }
        XCTAssertLessThan(try brightness(around: CGPoint(x: 412, y: 170), radius: 3, in: image), 80, "its head")
        for icon in [appIcon, applicationsIcon] {
            XCTAssertGreaterThan(try brightness(around: icon, radius: 40, in: image), 150, "the icon at \(icon) sits on clear ground")
        }
    }

    /// The layout puts the icons where the background expects them, names the volume by its mount point — another
    /// volume called MetaWhisp is never touched — and compiles.
    func testTheLayoutPutsTheIconsAtTheArrowsEnds() throws {
        let layout = try text("scripts/dmg-layout.applescript")
        XCTAssertTrue(layout.contains("set position of item \"MetaWhisp.app\" of dmg to {\(Int(appIcon.x)), \(Int(appIcon.y))}"))
        XCTAssertTrue(layout.contains("set position of item \"Applications\" of dmg to {\(Int(applicationsIcon.x)), \(Int(applicationsIcon.y))}"))
        XCTAssertTrue(layout.contains("set background picture of viewOptions"))
        XCTAssertTrue(layout.contains("/.background/background.png"))
        XCTAssertTrue(layout.contains("(POSIX file mountPath) as alias"), "the volume by its mount point")
        XCTAssertFalse(layout.contains("disk \"MetaWhisp\""), "never by its name")

        let compiled = FileManager.default.temporaryDirectory.appendingPathComponent("mw-dmg-layout-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: compiled) }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compile.arguments = ["-o", compiled.path, repoRoot.appendingPathComponent("scripts/dmg-layout.applescript").path]
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, "the layout compiles")
    }

    /// The image script stages the background in the hidden .background folder, lets Finder see the writable image
    /// (the layout is written by Finder), lays it out before the image is compressed, and only warns when Finder
    /// can't — the image still installs by drag.
    func testTheImageScriptLaysOutTheWindowBeforeCompressing() throws {
        let script = try text("make-dmg-manual.sh")
        let lines = script.components(separatedBy: "\n")
        XCTAssertTrue(script.contains("Resources/dmg-background.png"), "the background")
        XCTAssertTrue(script.contains(".background/background.png"), "in the hidden folder")
        let attach = try XCTUnwrap(lines.first { $0.contains("hdiutil attach") && $0.contains(".tmp.dmg") })
        XCTAssertFalse(attach.contains("-nobrowse"), "Finder must see the writable image to lay it out")
        XCTAssertTrue(script.contains("LAYOUT=\"$SCRIPT_DIR/scripts/dmg-layout.applescript\""), "the layout script")
        let layout = try XCTUnwrap(lines.firstIndex { $0.contains("osascript \"$LAYOUT\"") })
        XCTAssertTrue(lines[layout].contains("||") || lines[layout + 1].contains("WARNING"), "a layout Finder can't make only warns")
        let convert = try XCTUnwrap(lines.firstIndex { $0.contains("hdiutil convert") })
        let detach = try XCTUnwrap(lines.lastIndex { $0.contains("hdiutil detach") && !$0.contains("2>/dev/null") })
        XCTAssertLessThan(layout, detach, "laid out while attached")
        XCTAssertLessThan(detach, convert, "and kept by the compressed image")
    }
}
