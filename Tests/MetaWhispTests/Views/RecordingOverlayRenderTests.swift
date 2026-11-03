import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

@MainActor
final class RecordingOverlayRenderTests: XCTestCase {
    private let styles = ["capsule", "dotglow", "island", "glow", "shrek"]

    func testRenderScenesUseRecordingVoiceAtPanelSizes() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        defer { app.appearance = previous }
        let voice = RecordingOverlayController.previewVoice(at: 0.4)
        let sizes = [CGSize(width: 360, height: 120), CGSize(width: 1200, height: 800),
                     CGSize(width: 720, height: 240), CGSize(width: 1440, height: 240),
                     CGSize(width: 220, height: 220)]

        for (style, size) in zip(styles, sizes) {
            let (window, host) = try makeSurface(style: style)
            defer { window.close() }
            let state = host.rootView.state
            XCTAssertEqual(state.style, style)
            XCTAssertEqual(state.stage, .recording, style)
            XCTAssertEqual(state.bars, voice.bars, style)
            XCTAssertEqual(state.audioLevel, voice.audioLevel, style)
            XCTAssertEqual(host.frame.size, size, style)
            XCTAssertEqual(window.frame.size, size, style)
            XCTAssertFalse(window.isVisible, style)
        }
    }

    func testRenderEveryStyle() async throws {
        guard let folder = ProcessInfo.processInfo.environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the recording overlay renders.")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        defer { app.appearance = previous }

        // Shrek's video is not in the test bundle, so nothing of it would draw here.
        for style in styles where style != "shrek" {
            let (window, host) = try makeSurface(style: style)
            defer { window.close() }
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            // Let the views' appearance animations settle without ordering the panel.
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible, style)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertGreaterThan(drawnFraction(rep), 0.005, "\(style) drew nothing")
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("overlay-\(style).png"))

            // The cached display skips layer filters such as blur, so the auras also go through SwiftUI's
            // renderer. Only the auras: that renderer runs no onAppear, and the capsule picks its stage there.
            guard style == "dotglow" || style == "island" else { continue }
            let renderer = ImageRenderer(content: host.rootView)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, style)
            let swiftUIRep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), style)
            XCTAssertGreaterThan(drawnFraction(swiftUIRep), 0.005, "\(style) drew nothing")
            let swiftUIPNG = try XCTUnwrap(swiftUIRep.representation(using: .png, properties: [:]), style)
            try swiftUIPNG.write(to: directory.appendingPathComponent("overlay-\(style)-swiftui.png"))
        }
    }

    /// Share of sampled pixels that clearly differ from the scene's background.
    private func drawnFraction(_ rep: NSBitmapImageRep) -> Double {
        var drawn = 0
        var sampled = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                sampled += 1
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(color.redComponent - 0.06) + abs(color.greenComponent - 0.06)
                    + abs(color.blueComponent - 0.07)
                if distance > 0.15 { drawn += 1 }
            }
        }
        return sampled == 0 ? 0 : Double(drawn) / Double(sampled)
    }

    private func makeSurface(style: String) throws -> (NSPanel, NSHostingView<OverlayRenderScene>) {
        _ = NSApplication.shared
        let look = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let state = PillState()
        state.style = style
        state.stage = .recording
        let voice = RecordingOverlayController.previewVoice(at: 0.4)
        state.bars = voice.bars
        state.audioLevel = voice.audioLevel
        let size = RecordingOverlayController.panelSize(for: style, screenWidth: 1440)
        let host = NSHostingView(rootView: OverlayRenderScene(state: state, size: size))
        host.appearance = look
        let window = RecordingOverlayController.makePanel(style: style, screen: nil)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        host.setFrameSize(size)
        return (window, host)
    }
}

private struct OverlayRenderScene: View {
    @ObservedObject var state: PillState
    let size: CGSize

    var body: some View {
        PillRouterView(state: state)
            .ignoresSafeArea()
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .environment(\.colorScheme, .dark)
    }
}
