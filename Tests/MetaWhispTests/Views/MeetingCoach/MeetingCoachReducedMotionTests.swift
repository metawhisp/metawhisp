import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachReducedMotionTests: XCTestCase {
    func testReducedMotionPreservesSettledContentAndOffscreenHostingBounds() async throws {
        let normal = try await settledContent(reduceMotion: false)
        let reduced = try await settledContent(reduceMotion: true)
        XCTAssertEqual(normal, reduced)
    }

    private func settledContent(reduceMotion: Bool) async throws -> [Int] {
        var snapshots: [Int] = []
        let state = MeetingCoachState()
        state.arm()
        state.setSpeaker(.them)
        let presentation = MeetingCoachPresentation()
        let capsule = HostingSurface(MeetingCoachCapsuleView(presentation: presentation, state: state,
            reduceMotionOverride: reduceMotion))
        defer { capsule.window.close() }
        snapshots.append(try await verifySettledContent(capsule, reducedMotion: reduceMotion) {
            presentation.isExpanded = true
        })

        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline("The current answer.")], createdAt: Date()))
        state.transcriptTailProvider = {
            [.init(speaker: .me, text: "The accepted transcript line.", startSample: 0, endSample: 16_000)]
        }
        let panel = HostingSurface(MeetingCoachView(state: state, presentation: presentation,
            reduceMotionOverride: reduceMotion))
        defer { panel.window.close() }
        snapshots.append(try await verifySettledContent(panel, reducedMotion: reduceMotion) {
            state.selectTab(.transcript)
        })
        state.selectTab(.answers)
        try await Task.sleep(for: .milliseconds(250))
        snapshots.append(try await verifySettledContent(panel, reducedMotion: reduceMotion) { state.openAsk() })
        return snapshots
    }

    /// Unordered windows expose settled pixels, not intermediate compositor opacity.
    private func verifySettledContent<Content: View>(_ surface: HostingSurface<Content>, reducedMotion: Bool,
                                                    change: () -> Void) async throws -> Int {
        try await Task.sleep(for: .milliseconds(200))
        let initial = try surface.snapshot()
        let bounds = surface.host.bounds
        change()
        try await Task.sleep(for: .milliseconds(70))
        let midpoint = try surface.snapshot()
        try await Task.sleep(for: .milliseconds(250))
        let settled = try surface.snapshot()
        try await Task.sleep(for: .milliseconds(70))
        let stable = try surface.snapshot()
        XCTAssertNotEqual(initial, settled, "The changed content must be rendered.")
        if !reducedMotion {
            XCTAssertEqual(midpoint, settled, "Normal motion has no new transition.")
        }
        XCTAssertEqual(settled, stable, "The final offscreen image must be stable.")
        XCTAssertEqual(surface.host.bounds, bounds)
        XCTAssertFalse(surface.window.isVisible)
        return settled
    }

    private final class HostingSurface<Content: View> {
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(_ content: Content) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            host = NSHostingView(rootView: AnyView(content
                .environment(\.colorScheme, .light)
                .frame(width: 392, height: 260, alignment: .top)))
            host.sizingOptions = []
            window.contentView = host
        }

        func snapshot() throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).hashValue
        }

    }
}
