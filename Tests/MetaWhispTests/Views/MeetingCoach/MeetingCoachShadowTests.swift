import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachShadowTests: XCTestCase {
    private let screen = NSRect(x: 100, y: 80, width: 1_000, height: 700)

    func testEachSurfaceUsesOnePassThroughShadowWindow() throws {
        let (controller, _, ordering) = makeController()
        controller.show()
        defer { controller.hide() }
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let answer = try XCTUnwrap(controller.answerPanel)
        let capsuleShadow = try XCTUnwrap(controller.capsuleShadowPanel)
        let answerShadow = try XCTUnwrap(controller.answerShadowPanel)
        XCTAssertEqual(ordering.panels.count, 4)
        XCTAssertEqual(capsule.frame.size, NSSize(width: 168, height: 34))
        XCTAssertEqual(answer.frame.width, 392)
        XCTAssertEqual(capsule.frame.minY - answer.frame.maxY, 8)
        XCTAssertEqual(capsule.childWindows?.filter { $0 === capsuleShadow }.count, 1)
        XCTAssertEqual(answer.childWindows?.filter { $0 === answerShadow }.count, 1)
        for (surface, shadow) in [(capsule, capsuleShadow), (answer, answerShadow)] {
            XCTAssertTrue(shadow.ignoresMouseEvents)
            XCTAssertFalse(surface.ignoresMouseEvents)
            XCTAssertTrue(shadow.contentView is CardShadowView)
            XCTAssertTrue(shadow.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(shadow.level, surface.level)
            XCTAssertEqual(shadow.collectionBehavior, MWWindowBehavior.overlay)
            XCTAssertFalse(shadow.isVisible)
            XCTAssertFalse(surface.isVisible)
        }
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        try assertGapAndSidesAreClickThrough(controller)
    }

    func testShadowsFollowMoveResizeHideShowAndFocusRelease() async throws {
        let (controller, state, ordering) = makeController()
        controller.show()
        defer { controller.hide() }
        // Drain initial Combine delivery before driving the transitions explicitly.
        try await Task.sleep(for: .milliseconds(80))
        controller.updateAnswerHeight(180)
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        controller.capsulePanel?.setFrameOrigin(NSPoint(x: 350, y: 450))
        controller.dragEnded()
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        controller.pointerEntered(.capsule)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.capsulePanel?.frame.width, 208)
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        try assertGapAndSidesAreClickThrough(controller)

        state.hidePanel()
        controller.syncPanelVisibility(force: true)
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: false)
        state.showPanel()
        controller.syncPanelVisibility(force: true)
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)

        let answer = try XCTUnwrap(controller.answerPanel)
        ordering.adapter(answer).calls.removeAll()
        controller.giveUpQuestionFocus()
        XCTAssertEqual(ordering.adapter(answer).calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        controller.hide()
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: false, answerVisible: false)
        controller.show()
        try assertShadowsMatchSurfaces(controller, ordering: ordering, capsuleVisible: true, answerVisible: true)
        XCTAssertEqual(ordering.panels.count, 4, "Show reused the surface shadow windows")
        try assertGapAndSidesAreClickThrough(controller)
    }

    private func assertShadowsMatchSurfaces(_ controller: MeetingCoachWindowController,
                                           ordering: MeetingCoachOrderingModel,
                                           capsuleVisible: Bool, answerVisible: Bool,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let capsule = try XCTUnwrap(controller.capsulePanel, file: file, line: line)
        let answer = try XCTUnwrap(controller.answerPanel, file: file, line: line)
        let capsuleShadow = try XCTUnwrap(controller.capsuleShadowPanel, file: file, line: line)
        let answerShadow = try XCTUnwrap(controller.answerShadowPanel, file: file, line: line)
        if answerVisible { XCTAssertTrue(answer.parent === capsule, file: file, line: line) }
        else { XCTAssertNil(answer.parent, file: file, line: line) }
        XCTAssertEqual(answer.frame.midX, capsule.frame.midX, file: file, line: line)
        XCTAssertEqual(capsule.frame.minY - answer.frame.maxY, 8, file: file, line: line)
        for (surface, shadow, visible) in [(capsule, capsuleShadow, capsuleVisible),
                                           (answer, answerShadow, answerVisible)] {
            if visible { XCTAssertTrue(shadow.parent === surface, file: file, line: line) }
            else { XCTAssertNil(shadow.parent, file: file, line: line) }
            XCTAssertEqual(shadow.frame, surface.frame.insetBy(dx: -70, dy: -70), file: file, line: line)
            XCTAssertEqual(shadow.contentView?.frame.size, shadow.frame.size, file: file, line: line)
            XCTAssertEqual(ordering.adapter(surface).visible, visible, file: file, line: line)
            XCTAssertEqual(ordering.adapter(shadow).visible, visible, file: file, line: line)
            XCTAssertFalse(surface.isVisible, file: file, line: line)
            XCTAssertFalse(shadow.isVisible, file: file, line: line)
        }
    }

    private func assertGapAndSidesAreClickThrough(_ controller: MeetingCoachWindowController,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let capsule = try XCTUnwrap(controller.capsulePanel, file: file, line: line)
        let answer = try XCTUnwrap(controller.answerPanel, file: file, line: line)
        let windows = try [capsule, answer, XCTUnwrap(controller.capsuleShadowPanel),
                           XCTUnwrap(controller.answerShadowPanel)]
        let interactive = windows.filter { !$0.ignoresMouseEvents }
        XCTAssertEqual(interactive.count, 2, file: file, line: line)
        let points = [NSPoint(x: capsule.frame.midX, y: capsule.frame.minY - 4),
                      NSPoint(x: capsule.frame.minX - 1, y: capsule.frame.midY),
                      NSPoint(x: capsule.frame.maxX + 1, y: capsule.frame.midY),
                      NSPoint(x: answer.frame.minX - 1, y: answer.frame.midY),
                      NSPoint(x: answer.frame.maxX + 1, y: answer.frame.midY)]
        for point in points {
            XCTAssertFalse(interactive.contains { $0.frame.contains(point) },
                           "An interactive window covers the gap or a surface side", file: file, line: line)
            XCTAssertTrue(windows.contains { $0.ignoresMouseEvents && $0.frame.contains(point) },
                          "Probe must exercise the pass-through shadow area", file: file, line: line)
        }
    }

    private func makeController() -> (MeetingCoachWindowController, MeetingCoachState, MeetingCoachOrderingModel) {
        let state = MeetingCoachState()
        state.arm()
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer,
            provenance: .transcript, action: nil,
            blocks: [.headline("A concise next step")], createdAt: Date()))
        let ordering = MeetingCoachOrderingModel()
        let controller = MeetingCoachWindowController(state: state, visibleFrame: { self.screen },
                                                       panelOrdering: ordering.adapter)
        return (controller, state, ordering)
    }
}
