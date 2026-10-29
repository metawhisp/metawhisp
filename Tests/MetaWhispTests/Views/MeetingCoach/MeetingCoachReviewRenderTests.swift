import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

extension MeetingCoachRenderTests {
    func testEmptyTranscriptRendersNoLinesYet() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.transcriptTailProvider = { [] }
        state.selectTab(.transcript)
        let actual = ReviewRenderSurface(MeetingCoachView(state: state, drawsSurface: false),
                                         size: NSSize(width: 392, height: 100))
        let expected = ReviewRenderSurface(
            VStack(alignment: .leading, spacing: 0) {
                MeetingCoachHeaderView(state: state)
                Text("No lines yet")
                    .font(.system(size: 12)).foregroundStyle(MW.textMuted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .frame(width: 392, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true),
            size: NSSize(width: 392, height: 100))
        defer { actual.window.close(); expected.window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let rendered = try actual.bitmap()
        let status = try expected.bitmap()
        XCTAssertEqual(rendered.representation(using: .png, properties: [:]),
                       status.representation(using: .png, properties: [:]),
                       "Empty Transcript must render the header and 'No lines yet', with no transcript rows.")
        XCTAssertGreaterThan(try reviewInkComponents(rendered, in: NSRect(x: 16, y: 44, width: 100, height: 24)).count, 0,
                             "The reference comparison must contain visible status text.")
        XCTAssertFalse(actual.window.isVisible)
        XCTAssertFalse(expected.window.isVisible)
    }

    func testHiddenUnseenRenderContainsUnseenDot() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.setSpeaker(.quiet)
        state.hidePanel()
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline("The next step is ready.")], createdAt: Date(timeIntervalSince1970: 0)))
        let wave = MeetingCoachWaveModel()
        wave.receive(me: 0.2, them: 0.8, speaker: .quiet, at: 0)
        let startedAt = Date().addingTimeInterval(-758)
        let surface = ReviewRenderSurface(MeetingCoachCapsuleView(
            presentation: MeetingCoachPresentation(), state: state, wave: wave,
            recordingStartedAt: { startedAt }), size: NSSize(width: 168, height: 34))
        defer { surface.window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let bitmap = try surface.bitmap()
        // At 2x, the four-point dot is an isolated 6–9 pixel neutral-ink component.
        // This timer-side region excludes the recording indicator and waveform;
        // timer glyphs and the separator are too tall to pass as the dot.
        let components = try reviewInkComponents(bitmap, in: NSRect(x: 58, y: 6, width: 30, height: 22))
        let dots = components.filter {
            (6...9).contains(Int($0.width)) && (6...9).contains(Int($0.height))
                && abs($0.midY - 34) <= 2
        }
        XCTAssertEqual(dots.count, 1, "A hidden unseen answer must draw its four-point dot beside the timer.")
        XCTAssertTrue(state.panelHidden)
        XCTAssertTrue(state.hasUnseenAnswer)
        XCTAssertFalse(surface.window.isVisible)
    }
}

@MainActor
private final class ReviewRenderSurface {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init<Content: View>(_ content: Content, size: NSSize) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .aqua)
        host = NSHostingView(rootView: AnyView(content
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height, alignment: .top)))
        host.sizingOptions = []
        window.contentView = host
    }

    func bitmap() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        try XCTUnwrap(window.appearance).performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return bitmap
    }
}

/// Connected neutral-ink pixels distinguish the dot from text and the separator.
private func reviewInkComponents(_ bitmap: NSBitmapImageRep, in rect: NSRect) throws -> [NSRect] {
    let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
    let minX = Int(rect.minX * scale), maxX = Int(rect.maxX * scale)
    let minY = Int(rect.minY * scale), maxY = Int(rect.maxY * scale)
    var ink = Set<Int>()
    for y in minY..<maxY {
        for x in minX..<maxX {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let darkest = min(color.redComponent, color.greenComponent, color.blueComponent)
            let lightest = max(color.redComponent, color.greenComponent, color.blueComponent)
            if color.alphaComponent > 0.05, lightest < 0.7, lightest - darkest < 0.08 {
                ink.insert(y * bitmap.pixelsWide + x)
            }
        }
    }
    var components: [NSRect] = []
    while let first = ink.first {
        ink.remove(first)
        var pending = [first]
        var left = first % bitmap.pixelsWide, right = left
        var top = first / bitmap.pixelsWide, bottom = top
        while let pixel = pending.popLast() {
            let x = pixel % bitmap.pixelsWide, y = pixel / bitmap.pixelsWide
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
            for neighbor in [pixel - 1, pixel + 1, pixel - bitmap.pixelsWide, pixel + bitmap.pixelsWide] {
                if ink.remove(neighbor) != nil { pending.append(neighbor) }
            }
        }
        components.append(NSRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
    }
    return components
}
