import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachPanelTests: XCTestCase {
    func testDraftReplacesPublishedCardAndRejectionRestoresNewestOnly() {
        let state = MeetingCoachState()
        state.arm(generation: 4)
        state.publish(answer("Older"))
        state.publish(answer("Newest"))
        let request = UUID()
        state.showDraft(MeetingAnswerDraft(requestID: request, generation: 4, kind: .answer,
            heard: "A new question?", blocks: [.headline("Draft")]))
        XCTAssertEqual(state.displayedBlocks, [.headline("Draft")])
        XCTAssertEqual(state.displayedHeard, "A new question?")
        XCTAssertFalse(state.canExpandLatest)
        state.clearDraft(requestID: UUID(), generation: 4)
        XCTAssertEqual(state.displayedBlocks, [.headline("Draft")])
        state.clearDraft(requestID: request, generation: 4)
        XCTAssertEqual(state.displayedBlocks, [.headline("Newest")])
        XCTAssertTrue(state.canExpandLatest)
        XCTAssertEqual(state.answers.count, 2)
    }

    func testEmptyPanelOnlyAppearsOnHoverAndThinkingCanOpenIt() {
        let state = MeetingCoachState()
        state.arm()
        XCTAssertFalse(state.shouldShowPanel(isExpanded: false))
        XCTAssertTrue(state.shouldShowPanel(isExpanded: true))
        state.setThinking(true)
        XCTAssertTrue(state.shouldShowPanel(isExpanded: false))
        XCTAssertTrue(state.showsThinkingPlaceholder)
        state.publish(answer("Ready"))
        XCTAssertFalse(state.showsThinkingPlaceholder)
        state.setThinking(false)
        XCTAssertTrue(state.shouldShowPanel(isExpanded: false))
    }

    func testBalanceHaltShowsOnlyStatusOnHover() {
        let state = MeetingCoachState()
        state.arm()
        state.publish(answer("Previous answer"))
        state.haltForBalance()
        XCTAssertFalse(state.shouldShowPanel(isExpanded: false))
        XCTAssertTrue(state.shouldShowPanel(isExpanded: true))
        XCTAssertTrue(state.displayedBlocks.isEmpty)
        XCTAssertFalse(state.canRequestAnswers)
        XCTAssertNotNil(state.status)
    }

    func testControllerShowsEmptyChipPanelOnlyWhileExpanded() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = controller(state)
        controller.show()
        XCTAssertFalse(controller.isAnswerPresented)
        controller.pointerEntered(.capsule)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.isAnswerPresented)
        controller.pointerExited(.capsule)
        try await Task.sleep(for: .milliseconds(370))
        XCTAssertFalse(controller.isAnswerPresented)
        XCTAssertNil(controller.answerPanel?.parent)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
    }

    func testLongRecapUsesRealHostingCapAndItsBottomCanBeReached() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = controller(state)
        controller.show()
        let capsule = try XCTUnwrap(controller.capsulePanel).frame
        var heights: [CGFloat] = []
        for count in [1, 100, 2] {
            state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .action, provenance: .transcript,
                action: .recap, blocks: Array(repeating: .paragraph("The recap preserves every point in order."), count: count),
                createdAt: Date()))
            try await Task.sleep(for: .milliseconds(120))
            let scroll = try XCTUnwrap(controller.answerScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            heights.append(try XCTUnwrap(controller.answerPanel?.frame.height))
            XCTAssertEqual(controller.capsulePanel?.frame, capsule)
            if count == 100 {
                XCTAssertTrue(scroll.hasVerticalScroller)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(heights[1], heights[0])
        XCTAssertEqual(heights[1], controller.availableAnswerHeight)
        XCTAssertLessThan(heights[2], heights[1])
    }

    func testLongStatusRemainsOneLineThroughRealHosting() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = controller(state)
        controller.show()
        var heights: [CGFloat] = []
        for text in ["Nothing heard yet", String(repeating: "A long status message ", count: 30)] {
            state.setStatus(text)
            try await Task.sleep(for: .milliseconds(120))
            heights.append(try XCTUnwrap(controller.answerPanel?.frame.height))
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 1)
    }

    private func answer(_ text: String) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline(text)], createdAt: Date())
    }

    private func controller(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
    }
}
