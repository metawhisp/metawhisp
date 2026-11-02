import XCTest
@testable import MetaWhisp

/// The switches of Settings → General → Hotkeys: each of the four fixed
/// hotkeys may be off on its own, and the rules say which keys the app may
/// then still answer.
///
/// Pure on purpose: the same switches always give the same answer, without a
/// monitor, a timer or the live settings in the way.
final class HotkeyGatesTests: XCTestCase {

    // MARK: - The defaults

    /// Every hotkey is on until the user says otherwise: an install that
    /// never opened the panel works exactly as before.
    func testEveryGateIsOnByDefault() {
        let gates = HotkeyGates()
        XCTAssertTrue(gates.transcribe, "dictation off out of the box")
        XCTAssertTrue(gates.translate, "translate off out of the box")
        XCTAssertTrue(gates.voiceQuestion, "voice question off out of the box")
        XCTAssertTrue(gates.autoTranslate, "auto-translate off out of the box")
    }

    // MARK: - Right ⌘

    /// Right ⌘ carries two actions: with either on, the key is still ours.
    func testRightCommandIsOursWhileEitherActionIsOn() {
        var gates = HotkeyGates()
        gates.transcribe = false
        XCTAssertTrue(gates.tracksRightCommand(pushToTalk: false),
                      "the voice-question hold was lost with the tap")
        gates = HotkeyGates()
        gates.voiceQuestion = false
        XCTAssertTrue(gates.tracksRightCommand(pushToTalk: false),
                      "the dictation tap was lost with the hold")
    }

    /// With both of Right ⌘'s actions off, the key is not the app's.
    func testRightCommandIsIgnoredWhenBothActionsAreOff() {
        var gates = HotkeyGates()
        gates.transcribe = false
        gates.voiceQuestion = false
        XCTAssertFalse(gates.tracksRightCommand(pushToTalk: false))
        XCTAssertFalse(gates.tracksRightCommand(pushToTalk: true))
    }

    /// In Push-to-Talk the hold IS dictation: the mode has no action of its
    /// own, so the dictation switch alone decides.
    func testPushToTalkFollowsTheDictationSwitchAlone() {
        var gates = HotkeyGates()
        gates.transcribe = false
        gates.voiceQuestion = true
        XCTAssertFalse(gates.tracksRightCommand(pushToTalk: true),
                       "Push-to-Talk answered with dictation off")
        gates.transcribe = true
        gates.voiceQuestion = false
        XCTAssertTrue(gates.tracksRightCommand(pushToTalk: true),
                      "the voice-question switch muted Push-to-Talk")
    }

    // MARK: - Right ⌥

    /// Right ⌥ carries two actions: with either on, the key is still ours.
    func testRightOptionIsOursWhileEitherActionIsOn() {
        var gates = HotkeyGates()
        gates.translate = false
        gates.autoTranslate = true
        XCTAssertTrue(gates.tracksRightOption)
        gates = HotkeyGates()
        gates.translate = true
        gates.autoTranslate = false
        XCTAssertTrue(gates.tracksRightOption)
    }

    /// With both of Right ⌥'s actions off, the key is not the app's.
    func testRightOptionIsIgnoredWhenBothActionsAreOff() {
        var gates = HotkeyGates()
        gates.translate = false
        gates.autoTranslate = false
        XCTAssertFalse(gates.tracksRightOption)
    }
}
