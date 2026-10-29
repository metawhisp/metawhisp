import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachHeaderTests: XCTestCase {
    func testNativeSelectOneHeaderRemainsVisibleAndCapsuleHasOnlyHideAndStop() async throws {
        let state = armedState()
        let controller = makeController(state)
        defer { controller.hide() }
        try await settle()
        let answer = try XCTUnwrap(controller.answerPanel)
        let root = try XCTUnwrap(answer.contentView)
        let tabs = try XCTUnwrap(find(NSSegmentedControl.self, in: root))
        XCTAssertEqual(tabs.segmentCount, 2)
        XCTAssertEqual(tabs.label(forSegment: 0), "Answers")
        XCTAssertEqual(tabs.label(forSegment: 1), "Transcript")
        XCTAssertEqual(tabs.trackingMode, .selectOne)
        XCTAssertEqual(tabs.selectedSegment, 0)
        XCTAssertFalse(tabs.acceptsFirstResponder)
        XCTAssertFalse(tabs.needsPanelToBecomeKey)
        XCTAssertFalse(tabs.isDescendant(of: try XCTUnwrap(controller.answerScrollView)))
        XCTAssertTrue(controller.isAnswerPresented)
        XCTAssertFalse(controller.presentation.isExpanded)

        controller.pointerEntered(.capsule)
        try await settle()
        let capsule = try XCTUnwrap(controller.capsulePanel)
        XCTAssertEqual(capsule.frame.width, 208)
        XCTAssertEqual(buttonTitles(in: try XCTUnwrap(capsule.contentView)).sorted(), ["Hide", "Stop"])
        XCTAssertFalse(answer.isVisible)
        XCTAssertFalse(capsule.isVisible)
    }

    func testHeaderSelectionClosesAskAndPreservesShowAndHoverSemantics() async throws {
        let state = armedState()
        let controller = makeController(state)
        defer { controller.hide() }
        controller.pointerEntered(.capsule)
        state.openAsk()
        state.beginQuestionEditing()
        state.updateQuestionText("An unsent question")
        try await settle()
        let tabs = try XCTUnwrap(find(NSSegmentedControl.self, in: try XCTUnwrap(controller.answerPanel?.contentView)))
        press(1, in: tabs)
        XCTAssertEqual(state.selectedTab, .transcript)
        XCTAssertFalse(state.isAskOpen)
        XCTAssertFalse(state.isQuestionEditing)
        XCTAssertEqual(state.questionText, "An unsent question")
        try await settle()
        XCTAssertEqual(tabs.selectedSegment, 1)

        controller.pointerExited(.capsule)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(state.selectedTab, .answers)
        XCTAssertEqual(tabs.selectedSegment, 0)
        press(1, in: tabs)
        try await settle()
        state.hidePanel()
        state.showPanel()
        try await settle()
        XCTAssertEqual(state.selectedTab, .answers)
        let shownTabs = try XCTUnwrap(find(NSSegmentedControl.self,
            in: try XCTUnwrap(controller.answerPanel?.contentView)))
        XCTAssertEqual(shownTabs.selectedSegment, 0)
    }

    func testHaltedHeaderIsDisabledAndCannotSelectTranscript() async throws {
        let state = armedState()
        let controller = makeController(state)
        defer { controller.hide() }
        controller.pointerEntered(.capsule)
        state.selectTab(.transcript)
        state.haltForBalance()
        try await settle()
        let tabs = try XCTUnwrap(find(NSSegmentedControl.self, in: try XCTUnwrap(controller.answerPanel?.contentView)))
        XCTAssertTrue(controller.isAnswerPresented)
        XCTAssertFalse(tabs.isEnabled)
        XCTAssertEqual(tabs.selectedSegment, 0)
        let selection = state.selectedTab
        press(1, in: tabs)
        XCTAssertEqual(state.selectedTab, selection)
    }

    func testPinnedHeaderCountsInCapAndDoesNotScrollWithLongRecap() async throws {
        let state = armedState()
        let controller = makeController(state)
        defer { controller.hide() }
        try await settle()
        let answer = try XCTUnwrap(controller.answerPanel)
        let root = try XCTUnwrap(answer.contentView)
        let scroll = try XCTUnwrap(controller.answerScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let tabs = try XCTUnwrap(find(NSSegmentedControl.self, in: root))
        let headerHeight = answer.frame.height - scroll.frame.height
        XCTAssertGreaterThan(headerHeight, 0)
        XCTAssertEqual(answer.frame.height, document.frame.height + headerHeight, accuracy: 1)

        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .action, provenance: .transcript,
            action: .recap, blocks: Array(repeating: .paragraph("A recap point remains readable."), count: 100),
            createdAt: Date()))
        try await settle()
        XCTAssertEqual(answer.frame.height, controller.availableAnswerHeight)
        XCTAssertEqual(scroll.frame.height, answer.frame.height - headerHeight, accuracy: 1)
        XCTAssertTrue(scroll.hasVerticalScroller)
        let before = tabs.convert(tabs.bounds, to: root)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, before.minY)
        var header: NSView = tabs
        while let parent = header.superview, parent !== root { header = parent }
        XCTAssertEqual(header.frame.minY, scroll.frame.maxY)
        XCTAssertEqual(header.frame.maxY, root.bounds.maxY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 1)
        XCTAssertEqual(tabs.convert(tabs.bounds, to: root), before)
        XCTAssertTrue(root.bounds.contains(before))
        XCTAssertFalse(answer.isVisible)
    }

    private func armedState() -> MeetingCoachState {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline("The current answer.")], createdAt: Date()))
        return state
    }

    private func makeController(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        return controller
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }

    private func press(_ segment: Int, in control: NSSegmentedControl) {
        control.selectedSegment = segment
        _ = control.sendAction(control.action, to: control.target)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func buttonTitles(in view: NSView) -> [String] {
        if let button = view as? MeetingCoachNativeButton { return [button.title] }
        return view.subviews.flatMap(buttonTitles)
    }
}
