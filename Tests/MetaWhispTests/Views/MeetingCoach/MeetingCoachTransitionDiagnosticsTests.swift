import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachTransitionDiagnosticsTests: XCTestCase {
    func testHoverAnswerAndNativeTabEachCommitFramesOnceAfterFullSettling() async throws {
        for kind in [MeetingCoachTransitionDiagnostics.Kind.hover, .answer, .tab] {
            let h = Harness()
            h.controller.show()
            try await settle()
            h.clear()
            let before = h.controller.frameCommitCount
            switch kind {
            case .hover: h.controller.pointerEntered(.capsule)
            case .answer: h.state.publish(answer(String(repeating: "A longer answer needs room. ", count: 12)))
            case .tab: try pressTab(1, h)
            default: XCTFail("Unexpected fixture")
            }
            try await settle()
            XCTAssertEqual(h.controller.frameCommitCount - before, 1, kind.rawValue)
            assertOneInterval(h, kind: kind, commits: 1)
            let commits = h.controller.frameCommitCount
            let frames = h.controller.frameOperationCount
            try await flushDeferredAndNativeCallbacks(h)
            XCTAssertEqual(h.controller.frameCommitCount, commits, kind.rawValue)
            XCTAssertEqual(h.controller.frameOperationCount, frames, kind.rawValue)
            assertOneInterval(h, kind: kind, commits: 1)
            h.controller.hide()
        }
    }

    func testAllSevenIntervalsAndActualActionPriorities() async throws {
        let h = Harness()
        h.controller.show()
        try await settle()
        h.clear()
        h.controller.pointerEntered(.capsule)
        try await settle()
        h.state.publish(answer("An updated answer."))
        try await settle()
        h.state.showDraft(.init(requestID: UUID(), generation: 1, kind: .answer, heard: nil,
            blocks: [.headline("A draft answer.")]))
        try await settle()
        try XCTUnwrap(button("Ask…", in: try XCTUnwrap(h.controller.answerPanel?.contentView))).pressed()
        try await settle()
        XCTAssertTrue(h.state.isAskOpen)
        try pressTab(1, h)
        try await settle()
        XCTAssertFalse(h.state.isAskOpen)
        try XCTUnwrap(button("Hide", in: try XCTUnwrap(h.controller.capsulePanel?.contentView))).pressed()
        try await settle()
        try XCTUnwrap(button("Show", in: try XCTUnwrap(h.controller.capsulePanel?.contentView))).pressed()
        try await settle()
        XCTAssertEqual(h.events.filter { $0.phase == .begin }.map(\.kind),
                       [.hover, .answer, .delta, .ask, .tab, .hide, .show])
        assertBalanced(h)
        XCTAssertEqual(h.logs.count, 7)
        h.controller.hide()
    }

    func testInitialCollapsedAnswersDoNotQueueALaterTabReset() async throws {
        let h = Harness()
        h.controller.show()
        // The initial subscriptions have arrived, but their former 300 ms
        // no-op collapse timer would still be pending when the user clicks.
        try await Task.sleep(for: .milliseconds(150))
        h.clear()
        try pressTab(1, h)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(h.state.selectedTab, .transcript)
        assertOneInterval(h, kind: .tab, commits: 1)
        h.controller.hide()
    }

    func testHoverExitFromTranscriptAttributesTheAutomaticTabResetToHover() async throws {
        let h = Harness()
        h.controller.show()
        h.controller.pointerEntered(.capsule)
        try await settle()
        try pressTab(1, h)
        try await settle()
        h.clear()
        h.controller.pointerExited(.capsule)
        // Wait for the shared 300 ms collapse delay and its 180 ms transition.
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(h.controller.presentation.isExpanded)
        XCTAssertEqual(h.state.selectedTab, .answers)
        assertOneInterval(h, kind: .hover, commits: 1)
        h.controller.hide()
    }

    func testOpeningAskWhileCollapsedIsAskRatherThanHover() async throws {
        let h = Harness()
        h.controller.show()
        try await settle()
        h.clear()
        h.state.openAsk()
        try await settle()
        XCTAssertTrue(h.controller.presentation.isExpanded)
        XCTAssertEqual(h.events.filter { $0.phase == .begin }.map(\.kind), [.ask])
        assertBalanced(h)
        h.controller.hide()
    }

    func testStatusAndBusyDoNotInventAnswerIntervalsAndLogsContainOnlyClosedMetadata() async throws {
        let h = Harness()
        h.controller.show()
        try await settle()
        h.clear()
        h.state.setStatus("PRIVATE_STATUS_MARKER")
        h.state.showBusy(requestID: UUID(), generation: 1)
        try await settle()
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.logs.isEmpty)
        h.state.publish(answer("PRIVATE_ANSWER_MARKER", question: "PRIVATE_QUESTION_MARKER"))
        try await settle()
        XCTAssertEqual(h.logs.count, 1)
        for line in h.logs {
            XCTAssertFalse(line.contains("PRIVATE_"))
            XCTAssertNotNil(line.range(of: #"^\[MeetingCard\] transition=(hover|answer|delta|ask|tab|hide|show) frame_commits=[0-9]+$"#,
                                       options: .regularExpression))
        }
        assertBalanced(h)
        h.controller.hide()
    }

    func testSupersededStagingEndsItsIntervalWithoutPublishingAnotherCommit() async throws {
        let h = Harness()
        h.controller.show()
        try await settle()
        h.clear()
        h.controller.onTargetStaged = {
            h.controller.onTargetStaged = nil
            h.state.publish(self.answer("The newest replacement has a different target."))
            h.controller.syncPanelVisibility(force: true)
        }
        h.state.publish(answer(String(repeating: "The retired measurement. ", count: 12)))
        try await settle()
        XCTAssertEqual(h.events.filter { $0.phase == .begin }.count, 2)
        XCTAssertTrue(h.events.contains { $0.phase == .end && $0.frameCommits == 0 })
        assertBalanced(h)
        h.controller.hide()
    }

    func testRetargetCancellationAndLateCompletionsRemainBalanced() async throws {
        let animator = HeldAnimator()
        let h = Harness(animator: animator)
        h.controller.show()
        animator.completeAll()
        try await settle()
        animator.completeAll()
        h.clear()
        let request = UUID()
        h.state.showDraft(.init(requestID: request, generation: 1, kind: .answer, heard: nil,
            blocks: [.headline("A first streaming draft.")]))
        try await settle()
        let first = try XCTUnwrap(animator.completions.first)
        animator.completions.removeFirst()
        h.state.showDraft(.init(requestID: request, generation: 1, kind: .answer, heard: nil,
            blocks: [.headline(String(repeating: "The streaming draft grows. ", count: 12))]))
        try await settle()
        let owner = h.controller.activeAnimationRevision
        first()
        XCTAssertEqual(h.controller.activeAnimationRevision, owner)
        h.controller.hide()
        animator.completeAll()
        animator.completeAll()
        assertBalanced(h)
        XCTAssertTrue(h.events.contains { $0.kind == .delta && $0.phase == .end })
        XCTAssertTrue(h.events.contains { $0.kind == .hide && $0.phase == .end })
    }

    func testContentOnlyAnswerEndsWithZeroFramesAndPreservesNativeOwner() async throws {
        let animator = HeldAnimator()
        let h = Harness(animator: animator)
        h.controller.show()
        animator.completeAll()
        try await settle()
        animator.completeAll()
        h.clear()
        h.controller.pointerEntered(.capsule)
        try await settle()
        let owner = h.controller.activeAnimationRevision
        let before = h.controller.frameCommitCount
        h.state.publish(answer("The retained answer."))
        try await settle()
        XCTAssertEqual(h.controller.activeAnimationRevision, owner)
        XCTAssertEqual(h.controller.frameCommitCount, before)
        animator.completeAll()
        assertBalanced(h)
        XCTAssertEqual(h.events.filter { $0.phase == .end && $0.kind == .answer }.map(\.frameCommits), [0])
        h.controller.hide()
        animator.completeAll()
    }

    func testReducedMotionKeepsOneMeasuredCommitAndBalancedInterval() async throws {
        let h = Harness(reduced: true)
        h.controller.show()
        try await settle()
        h.clear()
        var geometryDuration: TimeInterval?
        h.controller.onTransitionCommitted = { geometryDuration = $0.geometryDuration }
        h.state.publish(answer(String(repeating: "A reduced motion answer. ", count: 12)))
        try await settle()
        XCTAssertEqual(geometryDuration, 0)
        assertOneInterval(h, kind: .answer, commits: 1)
        h.controller.hide()
    }

    func testControllerShowIncludesChangedOriginAndJointGeometry() async throws {
        let h = Harness()
        let before = h.controller.frameCommitCount
        h.controller.show()
        try await settle()
        let show = try XCTUnwrap(h.events.first { $0.kind == .show && $0.phase == .end })
        XCTAssertGreaterThanOrEqual(show.frameCommits, 2)
        XCTAssertEqual(show.frameCommits, h.controller.frameCommitCount - before)
        assertBalanced(h)
        h.controller.hide()
    }

    private func assertOneInterval(_ h: Harness, kind: MeetingCoachTransitionDiagnostics.Kind,
                                   commits: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.events.filter { $0.phase == .begin }.map(\.kind), [kind], file: file, line: line)
        XCTAssertEqual(h.events.filter { $0.phase == .end }.map(\.frameCommits), [commits], file: file, line: line)
        XCTAssertEqual(h.logs, ["[MeetingCard] transition=\(kind.rawValue) frame_commits=\(commits)"], file: file, line: line)
        assertBalanced(h, file: file, line: line)
    }

    private func assertBalanced(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let begins = h.events.filter { $0.phase == .begin }.map(\.id)
        let ends = h.events.filter { $0.phase == .end }.map(\.id)
        XCTAssertFalse(begins.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(begins).count, begins.count, file: file, line: line)
        XCTAssertEqual(begins.sorted(), ends.sorted(), file: file, line: line)
        XCTAssertEqual(h.logs.count, ends.count, file: file, line: line)
    }

    private func flushDeferredAndNativeCallbacks(_ h: Harness) async throws {
        h.controller.answerPanel?.contentView?.layoutSubtreeIfNeeded()
        h.controller.capsulePanel?.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await Task.yield() }
        h.controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: h.controller.capsulePanel))
        h.controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: h.controller.capsulePanel))
        try await settle()
        XCTAssertFalse(h.controller.answerPanel?.isVisible ?? true)
        XCTAssertFalse(h.controller.capsulePanel?.isVisible ?? true)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private func pressTab(_ index: Int, _ h: Harness) throws {
        let control = try XCTUnwrap(find(NSSegmentedControl.self, in: try XCTUnwrap(h.controller.answerPanel?.contentView)))
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }

    private func button(_ title: String, in view: NSView) -> MeetingCoachNativeButton? {
        if let button = view as? MeetingCoachNativeButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func answer(_ text: String, question: String? = nil) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), generation: 1, heard: nil, kind: .answer, provenance: .transcript,
                      action: nil, blocks: [.headline(text)], createdAt: Date(), question: question)
    }

    @MainActor private final class HeldAnimator {
        var completions: [() -> Void] = []
        func run(_ duration: TimeInterval, _ changes: @escaping () -> Void, _ completion: @escaping () -> Void) {
            changes()
            completions.append(completion)
        }
        func completeAll() {
            let pending = completions
            completions.removeAll()
            pending.forEach { $0() }
        }
    }

    @MainActor private final class Harness {
        let state = MeetingCoachState()
        var events: [MeetingCoachTransitionDiagnostics.Event] = []
        var logs: [String] = []
        var controller: MeetingCoachWindowController!

        init(reduced: Bool = false, animator: HeldAnimator? = nil) {
            state.arm(generation: 1)
            state.publish(MeetingAnswer(id: UUID(), generation: 1, heard: nil, kind: .answer,
                provenance: .transcript, action: nil, blocks: [.headline("The retained answer.")], createdAt: Date()))
            let diagnostics = MeetingCoachTransitionDiagnostics(eventSink: { [weak self] in self?.events.append($0) },
                                                                debugSink: { [weak self] in self?.logs.append($0) })
            if let animator {
                controller = MeetingCoachWindowController(state: state, ordersWindows: false,
                    visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 700) }, reduceMotion: { reduced },
                    transitionDiagnostics: diagnostics, runAnimation: animator.run)
            } else {
                controller = MeetingCoachWindowController(state: state, ordersWindows: false,
                    visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 700) }, reduceMotion: { reduced },
                    transitionDiagnostics: diagnostics)
            }
        }

        func clear() { events.removeAll(); logs.removeAll() }
    }
}
