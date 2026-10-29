import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachHideRegressionTests: XCTestCase {
    func testRealHideButtonStaysHiddenThenShowsIncludingFocusedAsk() async throws {
        for focused in [false, true] {
            let state = MeetingCoachState()
            state.arm(generation: 9)
            state.setStatus("Ready")
            let order = MeetingCoachOrderingModel()
            let controller = MeetingCoachWindowController(state: state,
                visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 700) },
                panelOrdering: order.adapter,
                requestQuestionFocus: { _, _ in state.beginQuestionEditing() })
            defer { controller.hide() }
            controller.show()
            controller.pointerEntered(.capsule)
            try await Task.sleep(for: .milliseconds(80))
            let capsule = try XCTUnwrap(controller.capsulePanel)
            let answer = try XCTUnwrap(controller.answerPanel)
            let shadow = try XCTUnwrap(controller.answerShadowPanel)
            if focused {
                state.openAsk()
                try await Task.sleep(for: .milliseconds(180))
                XCTAssertTrue(state.isQuestionEditing)
            }
            let root = try XCTUnwrap(capsule.contentView)
            try XCTUnwrap(button("Hide", in: root)).pressed()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(state.panelHidden)
            XCTAssertFalse(state.isQuestionEditing)
            XCTAssertFalse(controller.isAnswerPresented)
            XCTAssertTrue(effectivelyVisible(capsule, order: order))
            XCTAssertFalse(effectivelyVisible(answer, order: order))
            XCTAssertFalse(effectivelyVisible(shadow, order: order))
            XCTAssertNil(answer.parent)
            XCTAssertNil(shadow.parent)
            controller.dragEnded()
            controller.screenChanged()
            XCTAssertNil(answer.parent)
            XCTAssertNil(shadow.parent)
            try XCTUnwrap(button("Show", in: root)).pressed()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(state.panelHidden)
            XCTAssertTrue(effectivelyVisible(answer, order: order))
            XCTAssertTrue(effectivelyVisible(shadow, order: order))
            XCTAssertTrue(answer.parent === capsule)
            XCTAssertTrue(shadow.parent === answer)
            XCTAssertEqual(answer.frame.maxY, capsule.frame.minY - 8)
            XCTAssertFalse(capsule.isVisible)
            XCTAssertFalse(answer.isVisible)
            XCTAssertFalse(shadow.isVisible)
        }
    }

    private func button(_ title: String, in view: NSView) -> MeetingCoachNativeButton? {
        if let button = view as? MeetingCoachNativeButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    /// Models AppKit's implicit ordering when a child is attached to a shown parent.
    private func effectivelyVisible(_ panel: NSPanel, order: MeetingCoachOrderingModel) -> Bool {
        if order.adapter(panel).visible { return true }
        guard let parent = panel.parent as? NSPanel else { return false }
        return effectivelyVisible(parent, order: order)
    }
}
