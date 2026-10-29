import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachScrollTests: XCTestCase {
    func testNewDisplayedRequestResetsToTopEvenAtTheSameHeight() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let controller = makeController(state)
        defer { controller.hide() }
        state.publish(answer(id: UUID()))
        try await settle(controller)
        let scroll = try XCTUnwrap(controller.answerScrollView)
        setDistanceFromTop(150, in: scroll)
        XCTAssertEqual(distanceFromTop(scroll), 150, accuracy: 1)

        state.publish(answer(id: UUID()))
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 0, accuracy: 1)
    }

    func testSameDraftGrowthAndPublicationKeepPositionButGenerationChangeResets() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let controller = makeController(state)
        defer { controller.hide() }
        let id = UUID()
        state.showDraft(draft(id: id, generation: 1, count: 60))
        try await settle(controller)
        let scroll = try XCTUnwrap(controller.answerScrollView)
        setDistanceFromTop(120, in: scroll)

        state.showDraft(draft(id: id, generation: 1, count: 90))
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 120, accuracy: 1)
        state.publish(answer(id: id, count: 90))
        state.clearDraft(requestID: id, generation: 1)
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 120, accuracy: 1)

        state.showDraft(draft(id: id, generation: 2, count: 90))
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 0, accuracy: 1)
    }

    func testChangingTabsResetsBothDirections() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.transcriptTailProvider = {
            (0..<4).map { index in
                LiveMeetingTranscript.Line(speaker: .them,
                    text: String(repeating: "A long transcript sentence. ", count: 50),
                    startSample: index * 16_000, endSample: (index + 1) * 16_000)
            }
        }
        let controller = makeController(state)
        defer { controller.hide() }
        state.publish(answer(id: UUID()))
        try await settle(controller)
        let scroll = try XCTUnwrap(controller.answerScrollView)
        setDistanceFromTop(140, in: scroll)
        state.selectTab(.transcript)
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 0, accuracy: 1)
        setDistanceFromTop(140, in: scroll)
        XCTAssertEqual(distanceFromTop(scroll), 140, accuracy: 1)
        state.selectTab(.answers)
        try await settle(controller)
        XCTAssertEqual(distanceFromTop(scroll), 0, accuracy: 1)
    }

    private func makeController(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        return controller
    }

    private func blocks(_ count: Int) -> [MeetingAnswerBlock] {
        [.headline("A new recap")] + Array(repeating: .bullet("A point that remains readable."), count: count)
    }

    private func answer(id: UUID, count: Int = 60) -> MeetingAnswer {
        MeetingAnswer(id: id, generation: 1, heard: nil, kind: .action, provenance: .transcript,
            action: .recap, blocks: blocks(count), createdAt: Date())
    }

    private func draft(id: UUID, generation: Int, count: Int) -> MeetingAnswerDraft {
        MeetingAnswerDraft(requestID: id, generation: generation, kind: .answer, heard: nil, blocks: blocks(count))
    }

    private func settle(_ controller: MeetingCoachWindowController) async throws {
        try await Task.sleep(for: .milliseconds(150))
        controller.answerScrollView?.documentView?.layoutSubtreeIfNeeded()
    }

    private func distanceFromTop(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return -1 }
        return document.isFlipped ? scroll.documentVisibleRect.minY - document.bounds.minY
            : document.bounds.maxY - scroll.documentVisibleRect.maxY
    }

    private func setDistanceFromTop(_ distance: CGFloat, in scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let y = document.isFlipped ? document.bounds.minY + distance
            : document.bounds.maxY - scroll.contentView.bounds.height - distance
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
