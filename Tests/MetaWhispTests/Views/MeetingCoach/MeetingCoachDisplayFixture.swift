import AppKit
import XCTest
@testable import MetaWhisp

/// Real controller and hosts; only native window ordering/focus are replaced.
@MainActor
final class MeetingCoachDisplayFixture {
    let state = MeetingCoachState()
    let ordering = MeetingCoachOrderingModel()
    let wave = MeetingCoachWaveModel()
    let startedAt = Date()
    private(set) var timerReads: [Date] = []
    private(set) var controller: MeetingCoachWindowController!

    init() {
        state.arm(generation: 1)
        controller = MeetingCoachWindowController(state: state,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 800) },
            recordingStartedAt: { [weak self] in
                self?.timerReads.append(Date())
                return self?.startedAt
            }, wave: wave, onStop: {}, reduceMotion: { false },
            panelOrdering: ordering.adapter,
            requestQuestionFocus: { [weak state] _, _ in state?.beginQuestionEditing() })
        controller.show()
    }

    func stop() {
        controller.onTargetStaged = nil
        controller.onTargetMeasured = nil
        controller.onTransitionCommitted = nil
        controller.hide()
        state.disarm()
    }

    func answer(_ name: String, extraLines: Int = 0) -> MeetingAnswer {
        let blocks: [MeetingAnswerBlock] = [.headline("\(name) ready."), .bullet("Use batch \(name).")]
            + (extraLines == 0 ? [] : [.paragraph(Array(repeating: "Another supporting line.", count: extraLines).joined(separator: "\n"))])
        return MeetingAnswer(id: UUID(), generation: 1, heard: nil, kind: .answer,
            provenance: .transcript, action: nil, blocks: blocks, createdAt: Date())
    }

    /// Read the scroll document actually attached to the answer panel, never a
    /// fresh state snapshot or the controller's private installedSnapshot cache.
    func installed(file: StaticString = #filePath, line: UInt = #line) throws -> MeetingCoachRenderSnapshot {
        let panel = try XCTUnwrap(controller.answerPanel, file: file, line: line)
        let scroll = try XCTUnwrap(controller.answerScrollView, file: file, line: line)
        let host = try XCTUnwrap(scroll.documentView as? SelfSizingHostingView<MeetingCoachView>, file: file, line: line)
        XCTAssertTrue(host.window === panel, file: file, line: line)
        XCTAssertTrue(scroll.superview === panel.contentView, file: file, line: line)
        for window in [controller.capsulePanel, controller.answerPanel,
                       controller.capsuleShadowPanel, controller.answerShadowPanel].compactMap({ $0 }) {
            XCTAssertFalse(window.isVisible, "The test must never order a native window.", file: file, line: line)
        }
        return try XCTUnwrap(host.rootView.snapshot, file: file, line: line)
    }

    func assertInstalled(_ answer: MeetingAnswer, presented: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try installed(file: file, line: line)
        XCTAssertEqual(snapshot.requestID, answer.id, file: file, line: line)
        XCTAssertEqual(snapshot.generation, answer.generation, file: file, line: line)
        XCTAssertEqual(snapshot.displayedBlocks, answer.blocks, file: file, line: line)
        XCTAssertEqual(snapshot.renderedBlocks.map { String($0.characters) }, answer.blocks.map(\.text), file: file, line: line)
        XCTAssertFalse(snapshot.isDraft, file: file, line: line)
        XCTAssertEqual(controller.isAnswerPresented, presented, file: file, line: line)
        let panel = try XCTUnwrap(controller.answerPanel, file: file, line: line)
        XCTAssertEqual(ordering.adapter(panel).visible, presented, file: file, line: line)
        XCTAssertEqual(panel.parent === controller.capsulePanel, presented, file: file, line: line)
    }

    func waitUntil(_ predicate: () throws -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(try predicate(), "Controller did not settle before the deadline.", file: file, line: line)
    }

    func publishAndWait(_ answer: MeetingAnswer,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        state.publish(answer)
        try await waitUntil({ try self.installed().requestID == answer.id }, file: file, line: line)
        try assertInstalled(answer, file: file, line: line)
    }
}
