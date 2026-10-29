import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MetaWhisp

/// ITER-076 — the shortcut recorder of the Settings window (§3.8).
///
/// The recorder listens while a combo is being recorded. It belongs to the
/// Settings window: the keys of that window are its own and are swallowed,
/// so no stray Return presses a button behind it. The keys of another
/// window are the user's: they go on to the app.
@MainActor
final class MeetingHelpShortcutRecorderTests: XCTestCase {

    // MARK: - The rules

    /// A press of another window is not the recorder's.
    func testAPressOfAnotherWindowIsNotTheRecorders() {
        XCTAssertEqual(MeetingHelpRecorderRules.action(keyCode: 48, modifiers: 0, isOwnWindow: false),
                       .pass,
                       "the key of another window was taken by the recorder")
    }

    /// The keys of the window that records the combo belong to the recorder.
    func testTheKeysOfTheRecordingWindowBelongToTheRecorder() {
        XCTAssertEqual(MeetingHelpRecorderRules.action(keyCode: 36, modifiers: controlKey, isOwnWindow: true),
                       .accepted(MeetingHelpCombo(keyCode: 36, modifiers: controlKey)))
        XCTAssertEqual(MeetingHelpRecorderRules.action(keyCode: 48, modifiers: 0, isOwnWindow: true),
                       .refused(.needsControlOrOption))
    }

    /// Esc cancels the recording, and only in the window that records.
    func testEscCancelsTheRecording() {
        XCTAssertEqual(MeetingHelpRecorderRules.action(keyCode: 53, modifiers: 0, isOwnWindow: true),
                       .cancelled)
        XCTAssertEqual(MeetingHelpRecorderRules.action(keyCode: 53, modifiers: 0, isOwnWindow: false),
                       .pass,
                       "the Esc of another window cancelled the recording")
    }

    // MARK: - The monitor

    /// The monitor lets the keys of another window through: they belong to
    /// the app the user is working in.
    func testTheMonitorLetsTheKeysOfAnotherWindowThrough() throws {
        _ = NSApplication.shared
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        settings.orderFront(nil)
        other.orderFront(nil)

        let recorder = MeetingHelpShortcutRecorder()
        recorder.start(window: settings)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                   location: .zero,
                                                   modifierFlags: [],
                                                   timestamp: 0,
                                                   windowNumber: other.windowNumber,
                                                   context: nil,
                                                   characters: "\t",
                                                   charactersIgnoringModifiers: "\t",
                                                   isARepeat: false,
                                                   keyCode: 48))
        let result = recorder.monitorHandler(event)

        XCTAssertNotNil(result, "the key of another window was swallowed")
        XCTAssertTrue(recorder.isRecording, "the recording of the combo stopped")
        recorder.stop()
    }

    /// The monitor swallows the keys of the window that records the combo.
    func testTheMonitorSwallowsTheKeysOfTheRecordingWindow() throws {
        _ = NSApplication.shared
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.orderFront(nil)

        let recorder = MeetingHelpShortcutRecorder()
        recorder.start(window: settings)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                   location: .zero,
                                                   modifierFlags: [],
                                                   timestamp: 0,
                                                   windowNumber: settings.windowNumber,
                                                   context: nil,
                                                   characters: "\t",
                                                   charactersIgnoringModifiers: "\t",
                                                   isARepeat: false,
                                                   keyCode: 48))
        let result = recorder.monitorHandler(event)

        XCTAssertNil(result, "the key of the recording window was not swallowed")
        recorder.stop()
    }
}
