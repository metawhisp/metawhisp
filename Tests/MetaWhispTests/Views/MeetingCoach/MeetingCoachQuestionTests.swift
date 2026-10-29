import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// Native commands and panel calls are exercised without displaying a window.
@MainActor
final class MeetingCoachQuestionTests: XCTestCase {
    func testReturnSendsExactlyOnceAndReleasesEditing() {
        let harness = Harness()
        harness.beginEditing("What changed?")

        XCTAssertTrue(harness.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(harness.command(#selector(NSResponder.insertNewline(_:))))

        XCTAssertEqual(harness.sent, ["What changed?"])
        XCTAssertEqual(harness.field.stringValue, "")
        XCTAssertEqual(harness.state.questionText, "")
        XCTAssertFalse(harness.state.isQuestionEditing)
        XCTAssertEqual(harness.panel.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        XCTAssertEqual(harness.restoredAfter, [harness.panel.calls])
    }

    func testReturnIgnoresEmptyAndWhitespaceOnlyQuestions() {
        for text in ["", "   ", " \t\n "] {
            let harness = Harness()
            harness.beginEditing(text)
            XCTAssertTrue(harness.command(#selector(NSResponder.insertNewline(_:))))
            XCTAssertTrue(harness.sent.isEmpty)
        }
    }

    func testEscapeClearsWithoutSendingAndReleasesEditing() {
        let harness = Harness()
        harness.beginEditing("An unfinished question")

        XCTAssertTrue(harness.command(#selector(NSResponder.cancelOperation(_:))))

        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.field.stringValue, "")
        XCTAssertEqual(harness.state.questionText, "")
        XCTAssertFalse(harness.state.isQuestionEditing)
        XCTAssertEqual(harness.panel.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
    }

    func testOtherEditorCommandsAreNotSwallowed() {
        let harness = Harness()
        harness.beginEditing("A draft")
        XCTAssertFalse(harness.command(#selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(harness.state.questionText, "A draft")
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertTrue(harness.panel.calls.isEmpty)
    }

    func testFieldAndSentQuestionAreLimitedTo500UnicodeCharacters() {
        let harness = Harness()
        let character = "👨‍👩‍👧‍👦"
        harness.beginEditing(String(repeating: character, count: 501))

        XCTAssertEqual(harness.field.stringValue, String(repeating: character, count: 500))
        XCTAssertEqual(harness.state.questionText.count, 500)
        XCTAssertTrue(harness.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(harness.sent, [String(repeating: character, count: 500)])
    }

    func testNativeFieldIsSingleLineAndCanRequestThePanelKeyStatus() {
        let field = MeetingCoachQuestionField.makeField()
        XCTAssertEqual(field.placeholderString, "Ask about this call")
        XCTAssertTrue(field.usesSingleLineMode)
        XCTAssertEqual(field.maximumNumberOfLines, 1)
        XCTAssertTrue(field.isEditable)
        XCTAssertFalse(field.refusesFirstResponder)
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertTrue(field.needsPanelToBecomeKey)
    }

    func testPanelConfigurationDoesNotRequireShowingThePanel() {
        _ = NSApplication.shared
        let panel = MeetingCoachPanel.make()
        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertEqual(panel.collectionBehavior, MWWindowBehavior.overlay)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isVisible)
    }

    func testCoachHostingRefusesFocusWhileSharedHostingKeepsItsDefault() {
        let hosting = SelfSizingHostingView(rootView: Text("Answer text"))
        let originalAcceptsFirstResponder = hosting.acceptsFirstResponder
        let originalNeedsKey = hosting.needsPanelToBecomeKey
        XCTAssertTrue(hosting.permitsKeyboardFocus)

        hosting.permitsKeyboardFocus = false
        XCTAssertFalse(hosting.acceptsFirstResponder)
        XCTAssertFalse(hosting.needsPanelToBecomeKey)

        hosting.permitsKeyboardFocus = true
        XCTAssertEqual(hosting.acceptsFirstResponder, originalAcceptsFirstResponder)
        XCTAssertEqual(hosting.needsPanelToBecomeKey, originalNeedsKey)
    }

    func testStopWhileFocusedReleasesBeforeTheCardDisarms() {
        let harness = Harness()
        harness.beginEditing("A pending question")

        harness.state.disarm()

        XCTAssertEqual(harness.panel.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        XCTAssertEqual(harness.visibleDuringRelease, [true])
        XCTAssertFalse(harness.state.isQuestionEditing)
        XCTAssertFalse(harness.state.isVisible)
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testStopWithoutFieldFocusDoesNotReorderThePanel() {
        let harness = Harness()
        harness.state.disarm()
        XCTAssertTrue(harness.panel.calls.isEmpty)
    }

    func testClickingTheFieldWithoutEditingStillReleasesOnStop() {
        let harness = Harness()
        let field = FocusField()
        field.onFocus = harness.state.beginQuestionEditing

        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertTrue(harness.state.isQuestionEditing)
        harness.state.disarm()

        XCTAssertEqual(harness.panel.calls, ["endEditing", "orderOut", "orderFrontRegardless"])
        XCTAssertEqual(harness.visibleDuringRelease, [true])
        XCTAssertFalse(harness.state.isQuestionEditing)
    }

    func testFailedFocusAcquisitionDoesNotMarkTheFieldFocused() {
        let harness = Harness()
        let field = FocusField()
        field.acceptsFocus = false
        field.onFocus = harness.state.beginQuestionEditing

        XCTAssertFalse(field.becomeFirstResponder())
        XCTAssertFalse(harness.state.isQuestionEditing)
        harness.state.disarm()
        XCTAssertTrue(harness.panel.calls.isEmpty)
    }

    func testArmingAnotherMeetingClearsTheDraft() {
        let harness = Harness()
        harness.beginEditing("Old draft")
        harness.state.disarm()
        harness.state.arm()
        XCTAssertEqual(harness.state.questionText, "")
        XCTAssertFalse(harness.state.isQuestionEditing)
    }

    func testCardSourcesNeverActivateOrExplicitlyMakeAWindowKey() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("Views/MeetingCoach")
        let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["NSApp.activate", "NSApplication.shared.activate",
                              ".makeKey(", ".makeKeyAndOrderFront(", ".makeKeyWindow("] {
                XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent): \(forbidden)")
            }
        }
        let controller = try String(contentsOf: folder.appendingPathComponent("MeetingCoachWindowController.swift"),
                                    encoding: .utf8)
        XCTAssertTrue(controller.contains("hosting.permitsKeyboardFocus = false"))
    }

    private final class Panel: MeetingCoachPanelOrdering {
        var calls: [String] = []
        func endEditing(for object: Any?) { calls.append("endEditing") }
        func orderOut(_ sender: Any?) { calls.append("orderOut") }
        func orderFrontRegardless() { calls.append("orderFrontRegardless") }
    }

    private final class FocusField: MeetingCoachQuestionTextField {
        var acceptsFocus = true
        override func acquireFirstResponder() -> Bool { acceptsFocus }
    }

    @MainActor
    private final class Harness {
        let state = MeetingCoachState()
        let field = MeetingCoachQuestionField.makeField()
        let editor = NSTextView()
        let panel = Panel()
        let coordinator: MeetingCoachQuestionField.Coordinator
        var sent: [String] = []
        var visibleDuringRelease: [Bool] = []
        var restoredAfter: [[String]] = []

        init() {
            coordinator = MeetingCoachQuestionField.Coordinator(state: state)
            field.delegate = coordinator
            state.onQuestion = { [weak self] in self?.sent.append($0) }
            state.onEndQuestionEditing = { [weak self] in
                guard let self else { return }
                self.visibleDuringRelease.append(self.state.isVisible)
                MeetingCoachQuestionFocus.giveUp(panel: self.panel) {
                    self.restoredAfter.append(self.panel.calls)
                }
            }
            state.arm()
        }

        func beginEditing(_ text: String) {
            field.stringValue = text
            coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification,
                                                                 object: field))
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                           object: field))
        }

        func command(_ selector: Selector) -> Bool {
            coordinator.control(field, textView: editor, doCommandBy: selector)
        }
    }
}
