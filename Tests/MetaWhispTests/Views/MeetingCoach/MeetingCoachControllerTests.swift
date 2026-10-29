import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachControllerTests: XCTestCase {
    private let screen = NSRect(x: 100, y: 80, width: 1000, height: 700)

    func testExpandedCapsuleStaysInsideVisibleFrameAtScreenEdges() async throws {
        for edge in [screen.minX, screen.maxX] {
            let state = MeetingCoachState()
            state.arm()
            let controller = makeController(state)
            controller.show()
            try await Task.sleep(for: .milliseconds(60))
            let capsule = try XCTUnwrap(controller.capsulePanel)
            XCTAssertEqual(capsule.frame.width, 168)
            let x = edge == screen.minX ? edge : edge - capsule.frame.width
            capsule.setFrameOrigin(NSPoint(x: x, y: capsule.frame.minY))
            controller.dragEnded()

            controller.pointerEntered(.capsule)
            try await Task.sleep(for: .milliseconds(60))

            XCTAssertEqual(capsule.frame.width, 208)
            XCTAssertGreaterThanOrEqual(capsule.frame.minX, screen.minX)
            XCTAssertLessThanOrEqual(capsule.frame.maxX, screen.maxX)
            assertAttached(controller)
            XCTAssertFalse(capsule.isVisible)
            XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
            controller.hide()
        }
    }

    func testTopCentreTwoSurfacesAndGapStayOffscreen() throws {
        let controller = makeController()
        controller.show()
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let answer = try XCTUnwrap(controller.answerPanel)
        XCTAssertEqual(capsule.frame.midX, screen.midX)
        XCTAssertEqual(capsule.frame.maxY, screen.maxY - 10)
        XCTAssertEqual(capsule.frame.height, 34)
        XCTAssertEqual(answer.frame.width, 392)
        assertAttached(controller)
        XCTAssertFalse(capsule.frame.intersects(answer.frame))
        XCTAssertEqual(capsule.frame.minY - answer.frame.maxY, 8)
        XCTAssertFalse(capsule.isVisible)
        XCTAssertFalse(answer.isVisible)
        XCTAssertEqual(capsule.collectionBehavior, MWWindowBehavior.overlay)
        XCTAssertEqual(answer.collectionBehavior, MWWindowBehavior.overlay)
    }

    func testGrowCapShrinkHoldsCapsuleAndPanelTop() throws {
        let controller = makeController()
        controller.show()
        let capsule = try XCTUnwrap(controller.capsulePanel).frame
        for natural in [100.0, 2000, 70] {
            controller.updateAnswerHeight(natural)
            XCTAssertEqual(controller.capsulePanel?.frame, capsule)
            XCTAssertEqual(controller.answerPanel?.frame.maxY, capsule.minY - 8)
            XCTAssertEqual(controller.answerPanel?.frame.height,
                           min(natural, capsule.minY - 8 - (screen.minY + 16)))
            XCTAssertEqual(controller.answerScrollView?.hasVerticalScroller, natural == 2000)
        }
    }

    func testAttachesOnlyWhilePresentedAfterOrderingAndGeometryTransitions() throws {
        let ordering = MeetingCoachOrderingModel()
        let state = MeetingCoachState()
        state.arm()
        state.setStatus("Ready")
        let controller = MeetingCoachWindowController(state: state,
            visibleFrame: { self.screen }, panelOrdering: ordering.adapter)
        controller.show()
        for transition in [controller.hide, controller.show, controller.giveUpQuestionFocus,
                           controller.dragEnded, controller.screenChanged] {
            if let child = controller.answerPanel { controller.capsulePanel?.removeChildWindow(child) }
            transition()
            assertAttached(controller)
            XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
        }
    }

    func testHideShowAndFocusReleaseUseProductionOrderingWithoutVisibleWindows() async throws {
        let state = MeetingCoachState()
        state.arm()
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer,
            provenance: .transcript, action: nil,
            blocks: [.headline("The next step is ready.")], createdAt: Date()))
        let ordering = MeetingCoachOrderingModel()
        let controller = MeetingCoachWindowController(state: state,
            visibleFrame: { self.screen }, panelOrdering: ordering.adapter,
            requestQuestionFocus: { _, _ in state.beginQuestionEditing() })
        controller.show()
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let answer = try XCTUnwrap(controller.answerPanel)
        let capsuleOrder = ordering.adapter(capsule)
        let answerOrder = ordering.adapter(answer)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(capsuleOrder.visible)
        XCTAssertTrue(answerOrder.visible)
        assertAttached(controller)

        state.openAsk()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(state.isQuestionEditing)
        answerOrder.calls.removeAll()
        state.hidePanel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(answerOrder.calls, ["endEditing", "orderOut", "orderFrontRegardless", "orderOut"])
        XCTAssertFalse(answerOrder.visible)
        XCTAssertTrue(capsuleOrder.visible)
        XCTAssertFalse(state.isQuestionEditing)
        assertAttached(controller)

        answerOrder.calls.removeAll()
        state.showPanel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(answerOrder.calls, ["orderFrontRegardless"])
        XCTAssertTrue(answerOrder.visible)
        assertAttached(controller)

        state.openAsk()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(state.isQuestionEditing)
        answerOrder.calls.removeAll()
        state.closeAsk()
        XCTAssertEqual(answerOrder.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        XCTAssertTrue(answerOrder.visible)
        assertAttached(controller)

        controller.hide()
        XCTAssertFalse(capsuleOrder.visible)
        XCTAssertFalse(answerOrder.visible)
        assertAttached(controller)
        controller.show()
        XCTAssertTrue(capsuleOrder.visible)
        XCTAssertTrue(answerOrder.visible)
        assertAttached(controller)
        XCTAssertFalse(capsule.isVisible)
        XCTAssertFalse(answer.isVisible)
        controller.hide()
    }

    func testDragConstrainsMinimumViewportAndShortScreenUsesRemainingHeight() throws {
        let controller = makeController()
        controller.show()
        controller.capsulePanel?.setFrameOrigin(NSPoint(x: 300, y: 10))
        controller.dragEnded()
        XCTAssertEqual(controller.availableAnswerHeight, 160)
        assertAttached(controller)
        let short = MeetingCoachWindowController(state: MeetingCoachState(), ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 800, height: 120) })
        short.show()
        short.dragEnded()
        XCTAssertEqual(short.capsulePanel?.frame.maxY, 110)
        XCTAssertEqual(short.availableAnswerHeight, 52)
    }

    func testSharedHoverGraceReentryEditingAndTeardown() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = makeController(state)
        controller.show()
        controller.pointerEntered(.capsule)
        XCTAssertTrue(controller.presentation.isExpanded)
        controller.pointerExited(.capsule)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.presentation.isExpanded)
        controller.pointerEntered(.answer)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(controller.presentation.isExpanded)
        state.beginQuestionEditing()
        controller.pointerExited(.answer)
        try await Task.sleep(for: .milliseconds(330))
        XCTAssertTrue(controller.presentation.isExpanded)
        state.questionEditingEnded()
        try await Task.sleep(for: .milliseconds(330))
        XCTAssertFalse(controller.presentation.isExpanded)
        controller.pointerEntered(.capsule)
        controller.hide()
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testTrackingAreasUseActiveAlwaysAndVisibleRect() throws {
        let controller = makeController()
        controller.show()
        for panel in [controller.capsulePanel, controller.answerPanel] {
            let view = try XCTUnwrap(panel?.contentView as? MeetingCoachTrackingView)
            view.updateTrackingAreas()
            XCTAssertEqual(view.trackingAreas.count, 1)
            let options = try XCTUnwrap(view.trackingAreas.first?.options)
            XCTAssertTrue(options.contains([.mouseEnteredAndExited, .activeAlways, .inVisibleRect]))
            XCTAssertFalse(view.acceptsFirstResponder)
            XCTAssertFalse(view.needsPanelToBecomeKey)
        }
    }

    func testRealHostingMeasuresAnswerGrowthCapAndShrink() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = makeController(state)
        controller.show()
        let capsule = try XCTUnwrap(controller.capsulePanel).frame
        var heights: [CGFloat] = []
        for count in [1, 90, 1] {
            state.clearAnswers()
            state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer,
                provenance: .transcript, action: nil,
                blocks: [.headline("A concise answer")] + Array(repeating: .bullet("A point that remains readable."), count: count),
                createdAt: Date()))
            try await Task.sleep(for: .milliseconds(120))
            controller.answerScrollView?.documentView?.layoutSubtreeIfNeeded()
            heights.append(try XCTUnwrap(controller.answerPanel?.frame.height))
            XCTAssertEqual(controller.capsulePanel?.frame, capsule)
            if count == 90 {
                let scroll = try XCTUnwrap(controller.answerScrollView)
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(heights[1], heights[0])
        XCTAssertEqual(heights[1], controller.availableAnswerHeight)
        XCTAssertEqual(heights[2], heights[0], accuracy: 1)
    }

    func testCardSourcesCannotAccessCaptureOrPersistence() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("Views/MeetingCoach")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file)
            for forbidden in [".capture", ".peekSamples", ".bufferSnapshot", "transcribeMeetingDualStream",
                              "persistMeetingTranscript", "HistoryService", "MeetingRecorder("] {
                XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent): \(forbidden)")
            }
        }
    }

    private func makeController(_ state: MeetingCoachState? = nil) -> MeetingCoachWindowController {
        MeetingCoachWindowController(state: state ?? MeetingCoachState(), ordersWindows: false, visibleFrame: { self.screen })
    }

    private func assertAttached(_ controller: MeetingCoachWindowController,
                                file: StaticString = #filePath, line: UInt = #line) {
        if controller.isAnswerPresented {
            XCTAssertTrue(controller.answerPanel?.parent === controller.capsulePanel, file: file, line: line)
        } else {
            XCTAssertNil(controller.answerPanel?.parent, file: file, line: line)
        }
        XCTAssertEqual(controller.answerPanel?.frame.midX, controller.capsulePanel?.frame.midX, file: file, line: line)
        XCTAssertEqual(controller.answerPanel?.frame.maxY,
                       controller.capsulePanel.map { $0.frame.minY - 8 }, file: file, line: line)
    }
}
