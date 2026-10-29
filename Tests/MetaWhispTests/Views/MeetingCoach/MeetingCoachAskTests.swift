import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachAskTests: XCTestCase {
    func testDisarmWhileRequestIsInFlightClearsThinking() {
        let state = MeetingCoachState()
        state.arm(generation: 5)
        state.setThinking(true)
        XCTAssertTrue(state.showsThinkingPlaceholder)

        state.disarm()

        XCTAssertFalse(state.isThinking)
        XCTAssertFalse(state.showsThinkingPlaceholder)
        state.arm(generation: 6)
        XCTAssertFalse(state.isThinking)
        XCTAssertFalse(state.showsThinkingPlaceholder)
        XCTAssertFalse(state.shouldShowPanel(isExpanded: false))
    }

    func testOpeningAskRequestsFieldFocusWithoutActivatingApp() async throws {
        let state = MeetingCoachState()
        state.arm()
        var requests: [(NSPanel, MeetingCoachQuestionTextField)] = []
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 700) },
            requestQuestionFocus: { requests.append(($0, $1)) })
        controller.show()
        let active = NSApp.isActive
        state.openAsk()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(requests.count, 1)
        if let (panel, field) = requests.first {
            XCTAssertTrue(panel === controller.answerPanel)
            XCTAssertTrue(field.window === panel)
            XCTAssertTrue(field.needsPanelToBecomeKey)
            XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        }
        XCTAssertEqual(NSApp.isActive, active)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isKeyWindow)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
        state.openAsk()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests.count, 1)
        state.closeAsk()
        state.openAsk()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(requests.count, 2)
        controller.hide()
    }

    func testDisclosureCloseReleasesBeforeRemovalAndPreservesUnsentText() {
        let state = MeetingCoachState()
        state.arm()
        XCTAssertFalse(state.isAskOpen)
        state.openAsk()
        state.updateQuestionText("Unsent question")
        state.beginQuestionEditing()
        var releases = 0
        state.onEndQuestionEditing = {
            XCTAssertTrue(state.isAskOpen)
            XCTAssertTrue(state.isVisible)
            releases += 1
        }
        state.closeAsk()
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(state.isAskOpen)
        XCTAssertEqual(state.questionText, "Unsent question")
        state.openAsk()
        XCTAssertEqual(state.questionText, "Unsent question")
        state.disarm()
        XCTAssertFalse(state.isAskOpen)
        XCTAssertEqual(state.questionText, "")
    }

    func testReturnAndSendStayOpenAndSendAndCloseReleasesFirst() {
        let state = MeetingCoachState()
        state.arm()
        state.openAsk()
        var questions: [String] = []
        state.onQuestion = { questions.append($0) }
        state.beginQuestionEditing()
        state.updateQuestionText("  First question  ")
        state.submitQuestion()
        XCTAssertEqual(questions, ["First question"])
        XCTAssertTrue(state.isAskOpen)
        XCTAssertFalse(state.isQuestionEditing)
        XCTAssertEqual(state.questionText, "")
        state.beginQuestionEditing()
        state.updateQuestionText("Follow up")
        state.onEndQuestionEditing = { XCTAssertTrue(state.isAskOpen) }
        state.submitQuestion(closeAfterSending: true)
        XCTAssertEqual(questions, ["First question", "Follow up"])
        XCTAssertFalse(state.isAskOpen)
    }

    func testDisclosedNativeEscapeUsesPreservingClosePath() {
        let state = MeetingCoachState()
        state.arm()
        state.openAsk()
        state.updateQuestionText("Unsent text")
        state.beginQuestionEditing()
        let coordinator = MeetingCoachQuestionField.Coordinator(state: state, onClose: state.closeAsk)
        let field = MeetingCoachQuestionField.makeField()
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(state.questionText, "Unsent text")
        XCTAssertFalse(state.isAskOpen)
        XCTAssertFalse(state.isQuestionEditing)
    }

    func testPlaceholderUsesOnlyTheRegisteredShortcut() {
        let state = MeetingCoachState()
        XCTAssertEqual(state.questionPlaceholder, "Ask about this call")
        state.shortcutLabel = "⌃↩"
        XCTAssertEqual(state.questionPlaceholder, "Ask about this call — ⌃↩ for an answer now")
        state.shortcutLabel = "⌥H"
        XCTAssertEqual(state.questionPlaceholder, "Ask about this call — ⌥H for an answer now")
        state.shortcutLabel = ""
        XCTAssertEqual(state.questionPlaceholder, "Ask about this call")
    }

    func testStopClearsBubbleAndClosesBeforeRemovingTheSurface() {
        let state = MeetingCoachState()
        state.arm(generation: 6)
        state.openAsk()
        state.beginQuestionEditing()
        state.showDraft(MeetingAnswerDraft(requestID: UUID(), generation: 6, kind: .answer,
            heard: nil, blocks: [.headline("Draft")], question: "A typed question"))
        XCTAssertEqual(state.displayedQuestion, "A typed question")
        state.onEndQuestionEditing = {
            XCTAssertTrue(state.isAskOpen)
            XCTAssertTrue(state.recordingSurface)
        }
        state.disarm()
        XCTAssertNil(state.displayedQuestion)
        XCTAssertFalse(state.isAskOpen)
        state.arm(generation: 7)
        XCTAssertNil(state.displayedQuestion)
    }
}
