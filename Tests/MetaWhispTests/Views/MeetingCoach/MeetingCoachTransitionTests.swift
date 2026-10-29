import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachTransitionTests: XCTestCase {
    func testTargetIsMeasuredBeforeInstalledPixelsChangeAndCommitsOnlyOnce() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(answer("The original answer."))
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        let document = try XCTUnwrap(controller.answerScrollView?.documentView)
        let original = try pixels(document)
        let originalHeight = try XCTUnwrap(controller.answerPanel).frame.height
        var measured: [CGFloat] = []
        var commits: [MeetingCoachWindowController.Transition] = []
        controller.onTargetMeasured = { height in
            measured.append(height)
            XCTAssertEqual(try? self.pixels(document), original)
            XCTAssertEqual(controller.answerPanel?.frame.height, originalHeight)
        }
        controller.onTransitionCommitted = { transition in
            commits.append(transition)
            XCTAssertEqual(NSAnimationContext.current.duration, 0.18)
            XCTAssertEqual(controller.answerPanel?.frame, transition.answerFrame)
        }
        state.publish(answer(String(repeating: "A larger answer remains readable. ", count: 8)))
        try await Task.sleep(for: .milliseconds(300))
        document.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(commits.count, 1, "Deferred sizing must not produce a second frame commit.")
        XCTAssertGreaterThan(try XCTUnwrap(measured.first), originalHeight)
        XCTAssertEqual(commits.first?.geometryDuration, 0.18)
        XCTAssertEqual(commits.first?.opacityDuration, 0.18)
        XCTAssertNotEqual(try pixels(document), original)
        controller.onTargetMeasured = nil
        controller.onTransitionCommitted = nil
    }

    func testHoverFreezesControlsAndSubmitsAllDependentWindowTargets() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(answer("The original answer."))
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let root = try XCTUnwrap(capsule.contentView)
        var targets = Set<ObjectIdentifier>()
        controller.onFrameTarget = { panel, _ in targets.insert(ObjectIdentifier(panel)) }
        controller.pointerEntered(.capsule)
        root.layoutSubtreeIfNeeded()
        XCTAssertNil(button("Hide", in: root))
        XCTAssertEqual(capsule.frame.width, 168)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertNotNil(button("Hide", in: root))
        XCTAssertEqual(capsule.frame.width, 208)
        for panel in [controller.capsulePanel, controller.answerPanel,
                      controller.capsuleShadowPanel, controller.answerShadowPanel] {
            XCTAssertTrue(targets.contains(ObjectIdentifier(try XCTUnwrap(panel))))
        }
        let answerRoot = try XCTUnwrap(controller.answerPanel?.contentView)
        let scroll = try XCTUnwrap(controller.answerScrollView)
        XCTAssertEqual(scroll.autoresizingMask, [.width, .height])
        let header = try XCTUnwrap(answerRoot.subviews.first { $0.autoresizingMask.contains(.minYMargin) })
        XCTAssertEqual(header.frame.minY, scroll.frame.maxY)
    }

    func testReduceMotionUsesImmediateGeometryAndOpacityOnly() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(answer("The original answer."))
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) }, reduceMotion: { true })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(180))
        var commits: [MeetingCoachWindowController.Transition] = []
        controller.onTransitionCommitted = { commits.append($0) }
        controller.pointerEntered(.capsule)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.geometryDuration, 0)
        XCTAssertEqual(commits.first?.opacityDuration, 0.18)
        XCTAssertEqual(controller.capsulePanel?.frame.width, 208)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
    }

    func testStreamingRetargetSuppressesNativeCallbacksUntilNewestCompletion() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        var completions: [() -> Void] = []
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) },
            runAnimation: { duration, changes, completion in
                changes()
                if duration == 0 { completion() } else { completions.append(completion) }
            })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(100))
        let id = UUID()
        var commits: [MeetingCoachWindowController.Transition] = []
        controller.onTransitionCommitted = { commits.append($0) }
        for count in [1, 20] {
            state.showDraft(MeetingAnswerDraft(requestID: id, generation: 1, kind: .answer,
                heard: nil, blocks: [.headline("The streaming answer.")]
                    + Array(repeating: .bullet("A supporting point."), count: count)))
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.last?.retargets, true)
        let latest = try XCTUnwrap(controller.activeAnimationRevision)
        completions.first?()
        XCTAssertEqual(controller.activeAnimationRevision, latest)
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let target = try XCTUnwrap(commits.last?.capsuleFrame)
        capsule.setFrame(NSRect(origin: capsule.frame.origin, size: NSSize(width: 200, height: 34)), display: false)
        controller.giveUpQuestionFocus()
        XCTAssertEqual(controller.activeAnimationRevision, latest,
                       "Attachment-only focus release cannot retire an in-flight animation.")
        XCTAssertEqual(commits.count, 2)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let notice = Notification(name: name, object: capsule)
            if name == NSWindow.didMoveNotification { controller.windowDidMove(notice) }
            else { controller.windowDidResize(notice) }
        }
        XCTAssertEqual(commits.count, 2)
        capsule.setFrame(target, display: false)
        XCTAssertEqual(controller.answerPanel?.frame.maxY, capsule.frame.minY - 8)
        completions.last?()
        XCTAssertNil(controller.activeAnimationRevision)
        XCTAssertLessThanOrEqual(try XCTUnwrap(controller.answerPanel).frame.height, controller.availableAnswerHeight)
    }

    func testScreenSettingUsesStagedInstalledChipVisibility() async throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "screenContextEnabled")
        defaults.set(false, forKey: "screenContextEnabled")
        defer {
            if let old { defaults.set(old, forKey: "screenContextEnabled") }
            else { defaults.removeObject(forKey: "screenContextEnabled") }
        }
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let controller = makeController(state)
        controller.pointerEntered(.capsule)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        let document = try XCTUnwrap(controller.answerScrollView?.documentView)
        XCTAssertNil(button("Screen", in: document))
        var measured = 0
        controller.onTargetMeasured = { _ in
            measured += 1
            document.layoutSubtreeIfNeeded()
            XCTAssertNil(self.button("Screen", in: document))
        }
        defaults.set(true, forKey: "screenContextEnabled")
        document.layoutSubtreeIfNeeded()
        XCTAssertNil(button("Screen", in: document))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(measured, 1)
        XCTAssertNotNil(button("Screen", in: document))
        controller.onTargetMeasured = nil
    }

    func testInstalledAnswerDoesNotExposeNewContentBeforeControllerMeasuresIt() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(answer("The original answer."))
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        let document = try XCTUnwrap(controller.answerScrollView?.documentView)
        let original = try pixels(document)
        let frame = try XCTUnwrap(controller.answerPanel).frame

        state.publish(answer("An entirely different answer that needs several more lines to explain the proposed next step."))
        // Force the actual installed SwiftUI tree to render before the controller's
        // scheduled turn. A separate snapshot property cannot satisfy this check.
        XCTAssertEqual(try pixels(document), original,
                       "Content must remain frozen until target measurement and the joint commit.")
        XCTAssertEqual(controller.answerPanel?.frame, frame)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNotEqual(try pixels(document), original)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
    }

    private func answer(_ headline: String) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), generation: 1, heard: nil, kind: .answer, provenance: .transcript,
                      action: nil, blocks: [.headline(headline)], createdAt: Date())
    }

    private func makeController(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        return controller
    }

    private func pixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func button(_ title: String, in view: NSView) -> MeetingCoachNativeButton? {
        if let button = view as? MeetingCoachNativeButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }
}
