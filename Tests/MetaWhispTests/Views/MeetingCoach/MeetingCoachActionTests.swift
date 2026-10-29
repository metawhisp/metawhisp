import AppKit
import XCTest
@testable import MetaWhisp

/// The action row is driven without displaying a panel.
@MainActor
final class MeetingCoachActionTests: XCTestCase {
    func testSymbolButtonsDrawOnlyTheIconAndRetainAccessibleNames() {
        for (title, symbol) in [("Send", "arrow.up"), ("Close question", "xmark")] {
            let view = MeetingCoachButton(title: title, action: {}).symbol(symbol)
            let button = MeetingCoachButton.makeButton(title: title, action: {})
            view.updateButton(button)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.attributedTitle.string, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.accessibilityLabel(), title)
        }
    }

    func testButtonsRefuseFocusAndDoNotRequireAKeyPanel() {
        for title in ["Answers", "Transcript", "Hide", "Show", "Questions", "Recap", "More", "Ask…", "Stop", "Send", "Close question"] {
            let button = MeetingCoachButton.makeButton(title: title, action: {})
            XCTAssertEqual(button.title, title)
            XCTAssertTrue(button.refusesFirstResponder)
            XCTAssertFalse(button.acceptsFirstResponder)
            XCTAssertFalse(button.needsPanelToBecomeKey)
        }
    }

    func testGlassPaddingBelongsToTheNativeButtonHitBounds() {
        let button = MeetingCoachButton.makeButton(title: "Ask…", action: {})
        let original = button.intrinsicContentSize
        button.contentPadding = CGSize(width: 6, height: 5)
        XCTAssertEqual(button.intrinsicContentSize.width, original.width + 12)
        XCTAssertEqual(button.intrinsicContentSize.height, original.height + 10)
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        XCTAssertNotNil(button.hitTest(NSPoint(x: 1, y: 1)))
        XCTAssertFalse(button.needsPanelToBecomeKey)
    }

    func testNativeButtonDeliversOneClickAndRespectsDisabledState() {
        var calls = 0
        let button = MeetingCoachButton.makeButton(title: "Questions", action: { calls += 1 })
        button.performClick(nil)
        XCTAssertEqual(calls, 1)
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertEqual(calls, 1)
    }

    func testArmedEmptyCardAllowsHelpQuestionsAndRecap() {
        let state = MeetingCoachState()
        var helpCount = 0
        var actions: [MeetingAnswerAction] = []
        state.onHelp = { helpCount += 1 }
        state.onAction = { actions.append($0) }
        state.arm()

        state.helpPressed()
        state.actionPressed(.questions)
        state.actionPressed(.recap)
        state.actionPressed(.more)

        XCTAssertEqual(helpCount, 1)
        XCTAssertEqual(actions, [.questions, .recap])
        XCTAssertFalse(state.canExpandLatest)
    }

    func testDisarmedCardDoesNotInvokeCallbacks() {
        let state = MeetingCoachState()
        var calls = 0
        state.onHelp = { calls += 1 }
        state.onAction = { _ in calls += 1 }
        state.arm()
        state.publish(answer(kind: .answer))
        state.disarm()

        state.helpPressed()
        state.actionPressed(.questions)
        state.actionPressed(.recap)
        state.actionPressed(.more)

        XCTAssertEqual(calls, 0)
    }

    func testMoreDependsOnlyOnTheNewestCardsPublicationRule() {
        let cases: [(MeetingAnswerKind, MeetingAnswerProvenance, MeetingAnswerAction?, Bool)] = [
            (.answer, .transcript, nil, true),
            (.action, .transcript, .questions, true),
            (.action, .transcript, .more, true),
            (.action, .transcript, .recap, false),
            (.action, .transcript, .screen, false),
            (.answer, .screen, nil, false),
            (.action, .screen, .questions, false),
            (.action, .screen, .more, false),
            (.action, .screen, .recap, false),
            (.action, .screen, .screen, false)
        ]
        for (kind, provenance, action, expandable) in cases {
            let state = MeetingCoachState()
            var actions: [MeetingAnswerAction] = []
            state.onAction = { actions.append($0) }
            state.arm()
            state.publish(answer(kind: .answer))
            state.publish(answer(kind: kind, provenance: provenance, action: action))

            XCTAssertEqual(state.canExpandLatest, expandable)
            state.actionPressed(.more)
            XCTAssertEqual(actions, expandable ? [.more] : [])
        }
    }

    func testMoreIsDisabledWhileTheNewerDraftIsDrawn() {
        let state = MeetingCoachState()
        state.arm()
        state.publish(answer(kind: .answer))
        state.showDraft(MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
            heard: nil, blocks: [.headline("Draft")]))
        XCTAssertFalse(state.canExpandLatest)
    }

    func testCardFilesNeverActivateTheApplication() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("Views/MeetingCoach")
        let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("NSApp.activate"), file.lastPathComponent)
            XCTAssertFalse(source.contains("NSApplication.shared.activate"), file.lastPathComponent)
        }
    }

    private func answer(kind: MeetingAnswerKind,
                        provenance: MeetingAnswerProvenance = .transcript,
                        action: MeetingAnswerAction? = nil) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), heard: nil, kind: kind, provenance: provenance,
                      action: action, blocks: [.paragraph("A useful response.")], createdAt: Date())
    }
}
