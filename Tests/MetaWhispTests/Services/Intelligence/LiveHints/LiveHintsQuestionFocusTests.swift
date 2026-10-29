import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsQuestionFocusTests: XCTestCase {
    func testSessionStopReleasesFocusedQuestionField() async {
        let fakes = FakeLiveHintsEnvironment()
        let session = LiveHintsMeeting(environment: fakes.environment())
        let field = MeetingCoachQuestionField.makeField()
        let coordinator = MeetingCoachQuestionField.Coordinator(state: fakes.state)
        let panel = RecordingPanel(state: fakes.state)
        field.delegate = coordinator
        fakes.state.onEndQuestionEditing = {
            MeetingCoachQuestionFocus.giveUp(panel: panel)
        }
        await session.start()
        defer { session.stop() }
        var submittedQuestions: [String] = []
        let questionHandler = fakes.state.onQuestion
        fakes.state.onQuestion = { question in
            submittedQuestions.append(question)
            questionHandler?(question)
        }
        field.stringValue = "An unfinished question about the delivery date"
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification,
                                                            object: field))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                      object: field))
        XCTAssertTrue(fakes.state.isQuestionEditing)
        XCTAssertFalse(fakes.state.questionText.isEmpty)

        session.stop()

        XCTAssertEqual(panel.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        XCTAssertEqual(panel.visibleDuringCalls, [true, true, true],
                       "the field must release its panel before the session disarms the card")
        XCTAssertFalse(fakes.state.isQuestionEditing)
        XCTAssertFalse(fakes.state.isVisible)
        await Task.yield()
        XCTAssertTrue(submittedQuestions.isEmpty)
        XCTAssertTrue(fakes.pro.requests.isEmpty, "stopping must not submit the unfinished question")
        XCTAssertTrue(fakes.engine.calls.isEmpty)
    }

    private final class RecordingPanel: MeetingCoachPanelOrdering {
        let state: MeetingCoachState
        var calls: [String] = []
        var visibleDuringCalls: [Bool] = []

        init(state: MeetingCoachState) { self.state = state }

        func endEditing(for object: Any?) { record("endEditing") }
        func orderOut(_ sender: Any?) { record("orderOut") }
        func orderFrontRegardless() { record("orderFrontRegardless") }

        private func record(_ call: String) {
            calls.append(call)
            visibleDuringCalls.append(state.isVisible)
        }
    }
}
