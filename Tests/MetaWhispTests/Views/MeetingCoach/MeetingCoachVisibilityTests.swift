import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachVisibilityTests: XCTestCase {
    func testNewSurfaceNeverShowsRetiredSessionContentBeforeArming() {
        let state = MeetingCoachState()
        state.arm(generation: 9)
        state.publish(answer("Retired answer"))
        state.setStatus("Retired status")
        state.setThinking(true)
        state.disarm()
        state.showRecordingSurface(generation: 9)
        XCTAssertTrue(state.displayedBlocks.isEmpty)
        XCTAssertNil(state.status)
        XCTAssertFalse(state.showsThinkingPlaceholder)
        XCTAssertFalse(state.shouldShowPanel(isExpanded: false))
    }

    func testSettingsReplacementPreservesUnsentTextUntilRecordingEnds() async throws {
        let key = "liveMeetingAdviceEnabled"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: key)
        let fakes = FakeLiveHintsEnvironment()
        let advisor = LiveMeetingAdvisor()
        advisor.environment = fakes.environment()
        await advisor.arm()
        defer { advisor.disarm() }
        fakes.state.openAsk()
        fakes.state.updateQuestionText("An unfinished question")
        fakes.state.hidePanel()
        defaults.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<100 where advisor.isActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(advisor.isActive)
        XCTAssertEqual(fakes.state.questionText, "An unfinished question")
        defaults.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<100 where !fakes.state.isVisible { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(advisor.isActive)
        XCTAssertEqual(fakes.state.questionText, "An unfinished question")
        XCTAssertTrue(fakes.state.panelHidden)
        advisor.disarm()
        XCTAssertEqual(fakes.state.questionText, "")
    }

    func testHideRetainsEligibilityAndArrivalsUntilShowOrHelp() {
        let state = MeetingCoachState()
        state.arm(generation: 9)
        state.hidePanel()
        XCTAssertTrue(state.panelHidden)
        XCTAssertTrue(state.recordingSurface)
        XCTAssertTrue(state.canRequestAnswers)
        state.publish(answer("An unseen answer"))
        XCTAssertTrue(state.hasUnseenAnswer)
        XCTAssertFalse(state.shouldShowPanel(isExpanded: true))
        XCTAssertEqual(state.answers.count, 1)
        state.showPanel()
        XCTAssertFalse(state.hasUnseenAnswer)
        XCTAssertFalse(state.panelHidden)
        XCTAssertTrue(state.shouldShowPanel(isExpanded: false))
        state.hidePanel()
        var requests = 0
        state.onHelp = { requests += 1; XCTAssertFalse(state.panelHidden) }
        state.helpPressed()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(state.panelHidden)
    }

    func testHiddenResetsOnlyForANewRecordingGeneration() {
        let state = MeetingCoachState()
        state.arm(generation: 9)
        state.hidePanel()
        state.publish(answer("Old session"))
        state.disarm()
        state.arm(generation: 9)
        XCTAssertTrue(state.panelHidden)
        XCTAssertTrue(state.answers.isEmpty)
        state.showRecordingSurface(generation: 10)
        XCTAssertFalse(state.panelHidden)
        XCTAssertFalse(state.hasUnseenAnswer)
    }

    func testHideAndTranscriptReleaseBeforeRemovingTheField() {
        let state = MeetingCoachState()
        state.arm()
        for hide in [true, false] {
            state.showPanel()
            state.openAsk()
            state.updateQuestionText("Keep my unsent text")
            state.beginQuestionEditing()
            var releases = 0
            state.onEndQuestionEditing = {
                XCTAssertTrue(state.isAskOpen)
                XCTAssertFalse(state.panelHidden)
                XCTAssertEqual(state.selectedTab, .answers)
                releases += 1
            }
            if hide { state.hidePanel() } else { state.selectTab(.transcript) }
            XCTAssertEqual(releases, 1)
            XCTAssertFalse(state.isAskOpen)
            XCTAssertEqual(state.questionText, "Keep my unsent text")
        }
    }

    func testShowReattachesAndHoverExitReturnsToAnswers() async throws {
        let state = MeetingCoachState()
        state.arm()
        let controller = makeController(state)
        controller.show()
        controller.pointerEntered(.capsule)
        state.selectTab(.transcript)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(controller.isAnswerPresented)
        state.hidePanel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(controller.isAnswerPresented)
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let panel = try XCTUnwrap(controller.answerPanel)
        capsule.removeChildWindow(panel)
        state.showPanel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(panel.parent === capsule)
        XCTAssertEqual(panel.frame.maxY, capsule.frame.minY - 8)
        state.selectTab(.transcript)
        controller.pointerExited(.capsule)
        try await Task.sleep(for: .milliseconds(370))
        XCTAssertEqual(state.selectedTab, .answers)
        XCTAssertFalse(controller.presentation.isExpanded)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(capsule.isVisible)
    }

    func testTranscriptNaturalHeightGrowsCapsAndShrinksThroughRealHosting() async throws {
        let state = MeetingCoachState()
        state.arm()
        var lines: [LiveMeetingTranscript.Line] = []
        state.transcriptTailProvider = { lines }
        let controller = makeController(state)
        controller.show()
        controller.pointerEntered(.capsule)
        state.selectTab(.transcript)
        try await Task.sleep(for: .milliseconds(80))
        let capsule = try XCTUnwrap(controller.capsulePanel).frame
        var heights: [CGFloat] = []
        for repeats in [1, 80, 2] {
            lines = [.init(speaker: .me, text: String(repeating: "A useful accepted sentence. ", count: repeats),
                           startSample: 0, endSample: 16_000)]
            state.transcriptDidChange()
            try await Task.sleep(for: .milliseconds(120))
            let scroll = try XCTUnwrap(controller.answerScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            heights.append(try XCTUnwrap(controller.answerPanel?.frame.height))
            XCTAssertEqual(controller.capsulePanel?.frame, capsule)
            if repeats == 80 {
                XCTAssertTrue(scroll.hasVerticalScroller)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(heights[1], heights[0])
        XCTAssertEqual(heights[1], controller.availableAnswerHeight)
        XCTAssertLessThan(heights[2], heights[1])
        state.disarm()
        XCTAssertTrue(state.transcriptTail.isEmpty)
    }

    private func answer(_ text: String) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
                      action: nil, blocks: [.headline(text)], createdAt: Date())
    }

    private func makeController(_ state: MeetingCoachState) -> MeetingCoachWindowController {
        MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
    }
}
