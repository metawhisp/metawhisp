import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachAcknowledgementTests: XCTestCase {
    func testRealStopButtonDrawsAcknowledgementBeforeSynchronousStop() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 4)
        var calls = 0
        var controller: MeetingCoachWindowController!
        controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) }, onStop: {
                calls += 1
                XCTAssertTrue(state.isStopping)
                XCTAssertFalse(state.isAskOpen)
                XCTAssertFalse(state.isQuestionEditing)
                guard let root = controller.capsulePanel?.contentView,
                      let label = self.button("Stopping…", in: root) else {
                    XCTFail("Stopping must be in the drawn native tree before finalization")
                    return
                }
                XCTAssertFalse(label.isEnabled)
                XCTAssertTrue(root.bounds.contains(label.convert(label.bounds, to: root)))
                XCTAssertGreaterThanOrEqual(label.bounds.width, label.intrinsicContentSize.width - 1)
                let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)
                XCTAssertNotNil(bitmap)
                if let bitmap { root.cacheDisplay(in: root.bounds, to: bitmap) }
                XCTAssertFalse(controller.capsulePanel?.isVisible ?? true)
            })
        controller.show()
        controller.pointerEntered(.capsule)
        state.openAsk()
        state.beginQuestionEditing()
        try await Task.sleep(for: .milliseconds(180))
        defer { controller.hide() }
        let stop = try XCTUnwrap(button("Stop", in: try XCTUnwrap(controller.capsulePanel?.contentView)))
        stop.pressed()
        XCTAssertEqual(calls, 1)
        stop.pressed()
        XCTAssertEqual(calls, 1)
    }

    func testIdleStopDoesNothingAndNewGenerationResetsAcknowledgement() {
        let state = MeetingCoachState()
        XCTAssertFalse(state.beginStopping())
        XCTAssertFalse(state.isStopping)
        state.arm(generation: 1)
        XCTAssertTrue(state.beginStopping())
        XCTAssertFalse(state.beginStopping())
        state.arm(generation: 2)
        XCTAssertFalse(state.isStopping)
        XCTAssertTrue(state.beginStopping())
    }

    func testRepeatedChipPulseFlashesOnceWithoutTakingFocus() {
        let button = MeetingCoachButton.makeButton(title: "Questions", action: {})
        button.applyRepeatPulse(1)
        XCTAssertEqual(button.repeatFlashCount, 1)
        button.applyRepeatPulse(1)
        XCTAssertEqual(button.repeatFlashCount, 1)
        button.applyRepeatPulse(2)
        XCTAssertEqual(button.repeatFlashCount, 2)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.needsPanelToBecomeKey)
    }

    func testRecreatedChipDoesNotReplayAnOldRepeatPulse() {
        let button = MeetingCoachButton.makeButton(title: "Questions", action: {}, initialRepeatPulse: 2)
        button.applyRepeatPulse(2)
        XCTAssertEqual(button.repeatFlashCount, 0)
        button.applyRepeatPulse(3)
        XCTAssertEqual(button.repeatFlashCount, 1)
    }

    func testBusyShimmerStaysInFixedHeaderBesideRetainedContentAndTranscript() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer,
            provenance: .transcript, action: nil, blocks: [.headline("The retained answer.")], createdAt: Date()))
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(160))
        let answer = try XCTUnwrap(controller.answerPanel)
        let oldHeight = answer.frame.height
        let owner = UUID()
        state.showBusy(requestID: owner, generation: 1)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(answer.frame.height, oldHeight)
        XCTAssertEqual(state.displayedBlocks, [.headline("The retained answer.")])
        for tab in [MeetingCoachState.Tab.answers, .transcript] {
            state.selectTab(tab)
            try await Task.sleep(for: .milliseconds(100))
            let root = try XCTUnwrap(answer.contentView)
            let indicator = try XCTUnwrap(findProgress(in: root))
            XCTAssertFalse(indicator.isDescendant(of: try XCTUnwrap(controller.answerScrollView)))
            XCTAssertEqual(indicator.bounds.height, 3)
            XCTAssertFalse(answer.isVisible)
        }
        state.clearBusy(requestID: owner, generation: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(findProgress(in: try XCTUnwrap(answer.contentView)))
    }

    func testReducedMotionBusyIndicatorHasNoMovingShimmer() {
        let indicator = MeetingCoachProgressView()
        indicator.setReducedMotion(false)
        XCTAssertNotNil(indicator.layer?.sublayers?.first?.animation(forKey: "busy-shimmer"))
        indicator.setReducedMotion(true)
        XCTAssertNil(indicator.layer?.sublayers?.first?.animation(forKey: "busy-shimmer"))
        XCTAssertFalse(indicator.acceptsFirstResponder)
    }

    func testBusyIndicatorProducesVisibleOffscreenPixels() throws {
        _ = NSApplication.shared
        let indicator = MeetingCoachProgressView()
        indicator.frame = NSRect(x: 0, y: 0, width: 80, height: 3)
        indicator.setReducedMotion(true)
        indicator.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(indicator.bitmapImageRepForCachingDisplay(in: indicator.bounds))
        indicator.cacheDisplay(in: indicator.bounds, to: bitmap)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertGreaterThan(center.alphaComponent, 0.1)
    }

    private func findProgress(in view: NSView) -> MeetingCoachProgressView? {
        if let progress = view as? MeetingCoachProgressView { return progress }
        return view.subviews.lazy.compactMap { self.findProgress(in: $0) }.first
    }

    private func button(_ title: String, in view: NSView) -> MeetingCoachNativeButton? {
        if let button = view as? MeetingCoachNativeButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }
}
