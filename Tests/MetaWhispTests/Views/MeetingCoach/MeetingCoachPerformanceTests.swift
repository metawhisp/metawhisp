import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachPerformanceTests: XCTestCase {
    func testIdenticalDraftBlocksDoNotPublishButNewRequestKeepsOwnership() {
        let state = MeetingCoachState()
        let first = UUID()
        let second = UUID()
        var publications = 0
        let token = state.$draft.dropFirst().sink { _ in publications += 1 }
        defer { token.cancel() }
        let blocks: [MeetingAnswerBlock] = [.headline("**A useful next step.**")]
        state.showDraft(draft(first, blocks: blocks))
        state.showDraft(draft(first, blocks: blocks))
        XCTAssertEqual(publications, 1)
        state.showDraft(draft(first, blocks: blocks + [.bullet("Send the report.")]))
        XCTAssertEqual(publications, 2)
        state.showDraft(draft(second, blocks: blocks + [.bullet("Send the report.")]))
        XCTAssertEqual(publications, 3)
        state.clearDraft(requestID: first, generation: 1)
        XCTAssertEqual(state.draft?.requestID, second)
        XCTAssertEqual(publications, 3)
        state.showDraft(.init(requestID: second, generation: 2, kind: .answer, heard: nil,
                              blocks: blocks + [.bullet("Send the report.")]))
        state.clearDraft(requestID: second, generation: 1)
        XCTAssertEqual(state.draft?.generation, 2)
        XCTAssertEqual(publications, 4)
    }

    func testSpeakerChangesDoNotInvalidateTheAnswerState() {
        let state = MeetingCoachState()
        var publications = 0
        let token = state.objectWillChange.sink { publications += 1 }
        defer { token.cancel() }
        state.setSpeaker(.them)
        XCTAssertEqual(state.speaker, .them)
        state.setSpeaker(.quiet)
        XCTAssertEqual(state.speaker, .quiet)
        XCTAssertEqual(publications, 0)
    }

    func testTranscriptTailMemoizesEachAcceptedRevisionAndProviderReplacement() {
        let state = MeetingCoachState()
        var calls = 0
        var text = "The accepted line."
        state.transcriptTailProvider = {
            calls += 1
            return [.init(speaker: .them, text: text, startSample: 0, endSample: 16_000)]
        }
        for _ in 0..<20 { XCTAssertEqual(state.transcriptTail.first?.text, text) }
        XCTAssertEqual(calls, 1)
        text = "The accepted continuation."
        state.transcriptDidChange()
        for _ in 0..<20 { XCTAssertEqual(state.transcriptTail.first?.text, text) }
        XCTAssertEqual(calls, 2)
        state.transcriptTailProvider = { calls += 1; return [] }
        XCTAssertTrue(state.transcriptTail.isEmpty)
        XCTAssertTrue(state.transcriptTail.isEmpty)
        XCTAssertEqual(calls, 3)
        state.disarm()
        XCTAssertTrue(state.transcriptTail.isEmpty)
    }

    func testAnswerSnapshotDoesNotReadAnInvisibleTranscriptTail() {
        let state = MeetingCoachState()
        state.arm()
        var reads = 0
        state.transcriptTailProvider = { reads += 1; return [] }
        _ = MeetingCoachRenderSnapshot(state: state, expanded: true, screenContextEnabled: false)
        XCTAssertEqual(reads, 0)
        state.selectTab(.transcript)
        _ = MeetingCoachRenderSnapshot(state: state, expanded: true, screenContextEnabled: false)
        XCTAssertEqual(reads, 1)
    }

    func testSpeakerKeystrokesAndHiddenTranscriptDoNotStageGeometry() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.openAsk()
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        var measurements = 0
        var commits = 0
        controller.onTargetMeasured = { _ in measurements += 1 }
        controller.onTransitionCommitted = { _ in commits += 1 }
        state.setSpeaker(.them)
        state.updateQuestionText("A local draft")
        state.transcriptTailProvider = {
            [.init(speaker: .them, text: "An accepted line.", startSample: 0, endSample: 16_000)]
        }
        state.transcriptDidChange()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(measurements, 0)
        XCTAssertEqual(commits, 0)
        let document = try XCTUnwrap(controller.answerScrollView?.documentView)
        document.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(button("Send", in: document)).isEnabled)
        controller.onTargetMeasured = nil
        controller.onTransitionCommitted = nil
    }

    func testUnchangedTrackingBoundsKeepTheExistingArea() throws {
        _ = NSApplication.shared
        let view = MeetingCoachTrackingView(frame: NSRect(x: 0, y: 0, width: 392, height: 180))
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.contentView = view
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first)
        for _ in 0..<20 { view.updateTrackingAreas() }
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(view.trackingAreas.first === area)
        view.setFrameSize(NSSize(width: 392, height: 220))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertFalse(view.trackingAreas.first === area)
        XCTAssertTrue(view.trackingAreas.first?.options.contains(.inVisibleRect) == true)
        let resized = try XCTUnwrap(view.trackingAreas.first)
        panel.setFrameOrigin(NSPoint(x: 70, y: 80))
        view.updateTrackingAreas()
        XCTAssertFalse(view.trackingAreas.first === resized)
        XCTAssertFalse(panel.isVisible)
    }

    func testBoundWaveCoalescesBeforeDeliveringInputsToMain() async throws {
        let state = MeetingCoachState()
        state.setSpeaker(.both)
        let me = CurrentValueSubject<Float, Never>(0)
        let them = CurrentValueSubject<Float, Never>(0)
        let wave = MeetingCoachWaveModel()
        wave.bind(me: me.eraseToAnyPublisher(), them: them.eraseToAnyPublisher(), state: state)
        for tick in 0..<500 { me.send(Float(tick) / 500); them.send(1) }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(wave.mainInputDeliveryCount, 0)
        XCTAssertLessThanOrEqual(wave.mainInputDeliveryCount, 4,
                                 "Coalescing bars after every input reaches main is too late.")
        XCTAssertEqual(wave.bars.max(), 14)
        state.setSpeaker(.unavailable)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(wave.bars.isEmpty)
    }

    func testRenderedMarkdownMemoizesTheDisplayedBlockRevision() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let id = UUID()
        let blocks: [MeetingAnswerBlock] = [.headline("**Keep** the spaces."), .bullet("Send **one** report.")]
        state.showDraft(draft(id, blocks: blocks))
        for _ in 0..<20 { XCTAssertEqual(state.renderedBlocks.count, 2) }
        XCTAssertEqual(state.markdownRenderCount, 2)
        XCTAssertEqual(String(state.renderedBlocks[0].characters), "Keep the spaces.")
        XCTAssertTrue(state.renderedBlocks[0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        state.setSpeaker(.them)
        state.setStatus("Ready")
        _ = MeetingCoachRenderSnapshot(state: state, expanded: true, screenContextEnabled: false)
        XCTAssertEqual(state.markdownRenderCount, 2)
        state.showDraft(draft(id, blocks: [.headline("**Keep** the order."), .bullet("Send **two** reports.")]))
        XCTAssertEqual(String(state.renderedBlocks[0].characters), "Keep the order.")
        XCTAssertEqual(state.markdownRenderCount, 4)
        state.arm(generation: 2)
        XCTAssertTrue(state.renderedBlocks.isEmpty)
    }

    func testContentOnlyFeedbackSkipsMeasurementAndNativeGeometryWithoutRetiringAnimation() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(answer([.headline("The retained answer.")]))
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) },
            runAnimation: { duration, changes, completion in changes(); if duration == 0 { completion() } })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(100))
        controller.pointerEntered(.capsule)
        try await Task.sleep(for: .milliseconds(100))
        let active = try XCTUnwrap(controller.activeAnimationRevision)
        let document = try XCTUnwrap(controller.answerScrollView?.documentView)
        document.layoutSubtreeIfNeeded()
        let questions = try XCTUnwrap(button("Questions", in: document))
        let operations = controller.geometryOperationCount
        var measurements = 0
        controller.onTargetMeasured = { _ in measurements += 1 }
        state.showBusy(requestID: UUID(), generation: 1)
        state.flashRepeatedAction(.questions)
        try await Task.sleep(for: .milliseconds(180))
        document.layoutSubtreeIfNeeded()
        XCTAssertEqual(measurements, 0)
        XCTAssertEqual(controller.geometryOperationCount, operations)
        XCTAssertEqual(controller.activeAnimationRevision, active)
        XCTAssertTrue(button("Questions", in: document) === questions)
        XCTAssertEqual(questions.repeatFlashCount, 1)
        controller.onTargetMeasured = nil
    }

    func testSameHeightNewAnswerResetsScrollButRepeatedGeometryDoesNoWork() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let blocks: [MeetingAnswerBlock] = [.headline("The retained answer.")]
            + Array(repeating: .paragraph("A supporting point with enough detail to fill the scroll viewport."), count: 24)
        state.publish(answer(blocks))
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(220))
        let scroll = try XCTUnwrap(controller.answerScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let height = document.frame.height + MeetingCoachHeaderView.height
        let bottom = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        let operations = controller.geometryOperationCount
        controller.updateAnswerHeight(height)
        controller.updateAnswerHeight(height)
        XCTAssertEqual(controller.geometryOperationCount, operations)
        let priorFrame = controller.answerPanel?.frame
        state.publish(answer(blocks))
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(controller.answerPanel?.frame, priorFrame)
        let topDistance = document.isFlipped ? scroll.documentVisibleRect.minY - document.bounds.minY
            : document.bounds.maxY - scroll.documentVisibleRect.maxY
        XCTAssertEqual(topDistance, 0, accuracy: 1)
    }

    func testHostsWithoutSizeConsumersDoNotScheduleReports() async throws {
        let host = SelfSizingHostingView(rootView: Text("A fixed capsule label."))
        host.frame = NSRect(x: 0, y: 0, width: 168, height: 34)
        for _ in 0..<20 { host.invalidateIntrinsicContentSize(); host.layoutSubtreeIfNeeded() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.sizeReportScheduleCount, 0)
        var reports = 0
        host.onContentSizeChange = { _ in reports += 1 }
        host.invalidateIntrinsicContentSize()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(reports, 0, "Existing consumers such as MeetingRecap still receive size changes.")
    }

    func testRevertedOrContentOnlyTargetRetiresAPendingMeasurement() async throws {
        for feedback in [false, true] {
            let state = MeetingCoachState()
            state.arm(generation: 1)
            state.setStatus("Ready")
            let controller = makeController(state)
            defer { controller.hide() }
            try await Task.sleep(for: .milliseconds(180))
            var measurements = 0
            var commits = 0
            controller.onTargetMeasured = { _ in measurements += 1 }
            controller.onTransitionCommitted = { _ in commits += 1 }
            controller.onTargetStaged = {
                controller.onTargetStaged = nil
                state.setStatus("Ready")
                if feedback { state.showBusy(requestID: UUID(), generation: 1) }
                controller.syncPanelVisibility()
            }
            state.setStatus("A superseded target")
            try await Task.sleep(for: .milliseconds(220))
            XCTAssertEqual(measurements, 0)
            XCTAssertEqual(commits, feedback ? 1 : 0)
            controller.onTargetMeasured = nil
            controller.onTransitionCommitted = nil
        }
    }

    func testSameStatusCanReappearAfterItsEffectiveExpiry() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let state = MeetingCoachState(clock: { now })
        state.arm(generation: 1)
        state.setStatus("Ready", seconds: 100)
        let controller = makeController(state)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(controller.isAnswerPresented)
        now = now.addingTimeInterval(101)
        controller.syncPanelVisibility()
        XCTAssertFalse(controller.isAnswerPresented)
        state.setStatus("Ready", seconds: 100)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(controller.isAnswerPresented)
    }

    private func answer(_ blocks: [MeetingAnswerBlock]) -> MeetingAnswer {
        .init(id: UUID(), generation: 1, heard: nil, kind: .answer, provenance: .transcript,
              action: nil, blocks: blocks, createdAt: Date())
    }

    private func draft(_ id: UUID, blocks: [MeetingAnswerBlock]) -> MeetingAnswerDraft {
        .init(requestID: id, generation: 1, kind: .answer, heard: nil, blocks: blocks)
    }

    private func makeController(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        return controller
    }

    private func button(_ title: String, in view: NSView) -> MeetingCoachNativeButton? {
        if let button = view as? MeetingCoachNativeButton,
           button.title == title || button.accessibilityLabel() == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }
}
