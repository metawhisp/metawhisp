import Carbon.HIToolbox
import XCTest
@testable import MetaWhisp

/// ITER-076 P5 — the help shortcut of the in-call hints.
///
/// Three things are pinned here: the rules the recorder follows (§3.8), the
/// registration behind the Carbon hot key table (§3.9), and the clash guard
/// — a Right ⌥ held inside the combo must never read as a translate tap.
@MainActor
final class MeetingHelpHotkeyTests: XCTestCase {

    /// The owner of the registrations in these tests.
    private let owner = UUID()

    // MARK: - The recorder's rules

    func testTheRecorderRefusesAKeyWithoutAModifier() {
        XCTAssertEqual(MeetingHelpComboValidator.validate(keyCode: 31, modifiers: 0),
                       .failure(.needsControlOrOption),
                       "a bare key would fire in whatever the user is typing in")
    }

    func testTheRecorderRefusesCommand() {
        XCTAssertEqual(MeetingHelpComboValidator.validate(keyCode: 31, modifiers: cmdKey | optionKey),
                       .failure(.commandNotAllowed),
                       "Carbon cannot tell the left ⌘ from the right one")
    }

    func testTheRecorderRefusesAModifierOnItsOwn() {
        XCTAssertEqual(MeetingHelpComboValidator.validate(keyCode: 59, modifiers: controlKey),
                       .failure(.modifierOnly), "Control alone is not a shortcut")
        XCTAssertEqual(MeetingHelpComboValidator.validate(keyCode: 61, modifiers: optionKey),
                       .failure(.modifierOnly), "Right Option alone is not a shortcut")
    }

    func testTheRecorderAcceptsControlReturn() {
        XCTAssertEqual(MeetingHelpComboValidator.validate(keyCode: 36, modifiers: controlKey),
                       .success(MeetingHelpCombo(keyCode: 36, modifiers: controlKey)))
    }

    // MARK: - The modifiers and the label

    func testTheModifiersMapToTheCarbonMask() {
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: []), 0)
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: .command), cmdKey)
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: .option), optionKey)
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: .control), controlKey)
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: .shift), shiftKey)
        XCTAssertEqual(MeetingHelpModifiers.carbonMask(for: [.control, .shift]),
                       controlKey | shiftKey)
    }

    func testTheLabelOfTheShortcut() {
        XCTAssertEqual(MeetingHelpLabel.label(keyCode: 36, modifiers: controlKey), "⌃↩")
        XCTAssertEqual(MeetingHelpLabel.label(keyCode: 49, modifiers: optionKey), "⌥Space")
        XCTAssertEqual(MeetingHelpLabel.label(keyCode: 31, modifiers: cmdKey | optionKey), "⌥⌘O")
        XCTAssertEqual(MeetingHelpLabel.label(keyCode: 29, modifiers: controlKey), "⌃0")
        XCTAssertEqual(MeetingHelpLabel.label(keyCode: 999, modifiers: controlKey), "⌃Key 999",
                       "an unknown key falls back to its number")
    }

    // MARK: - The registration

    func testRegisteringAndUnregistering() {
        let registrar = FakeMeetingHotkeyRegistrar()
        let hotkey = MeetingHelpHotkey(registrar: registrar)
        hotkey.register(keyCode: 36, modifiers: controlKey, owner: owner)
        XCTAssertTrue(registrar.handlerInstalled, "the one application handler is installed")
        XCTAssertEqual(registrar.registrations.map(\.keyCode), [36])
        XCTAssertEqual(registrar.registrations.map(\.modifiers), [controlKey])
        XCTAssertNil(hotkey.registrationError)
        XCTAssertEqual(hotkey.shortcutLabel, "⌃↩", "the overlay shows the shortcut")

        hotkey.unregister(owner: owner)
        XCTAssertEqual(registrar.unregistered, [MeetingHelpHotkey.hotkeyID])
    }

    func testChangingTheShortcutTakesTheOldOneAndRegistersTheNewOne() {
        let registrar = FakeMeetingHotkeyRegistrar()
        let hotkey = MeetingHelpHotkey(registrar: registrar)
        hotkey.register(keyCode: 36, modifiers: controlKey, owner: owner)
        hotkey.register(keyCode: 31, modifiers: optionKey, owner: owner)
        XCTAssertEqual(registrar.registrations.map(\.keyCode), [36, 31])
        XCTAssertEqual(registrar.unregistered, [MeetingHelpHotkey.hotkeyID],
                       "the old combo is taken back")
        XCTAssertEqual(hotkey.shortcutLabel, "⌥O")
    }

    func testAFailedRegistrationPublishesTheReason() {
        let registrar = FakeMeetingHotkeyRegistrar()
        registrar.status = OSStatus(eventHotKeyExistsErr)
        let hotkey = MeetingHelpHotkey(registrar: registrar)
        hotkey.register(keyCode: 36, modifiers: controlKey, owner: owner)
        XCTAssertEqual(hotkey.registrationError, "This shortcut is taken by another app — pick another")
        XCTAssertNil(hotkey.shortcutLabel, "the overlay header shows no shortcut")
    }

    /// A registration belongs to the session that took it: an old session
    /// that was stopped may not take the shortcut away from the session that
    /// holds it now (§6.15).
    func testOnlyTheOwnerMayTakeTheShortcutBack() {
        let registrar = FakeMeetingHotkeyRegistrar()
        let hotkey = MeetingHelpHotkey(registrar: registrar)
        let old = UUID()
        let current = UUID()

        hotkey.register(keyCode: 36, modifiers: controlKey, owner: old)
        hotkey.register(keyCode: 31, modifiers: optionKey, owner: current)

        XCTAssertFalse(hotkey.unregister(owner: old),
                       "the old owner took the shortcut away")
        XCTAssertEqual(registrar.unregistered, [MeetingHelpHotkey.hotkeyID],
                       "the old owner's unregister reached the window server")
        XCTAssertEqual(hotkey.shortcutLabel, "⌥O",
                       "the shortcut of the current owner is gone")

        XCTAssertTrue(hotkey.unregister(owner: current),
                      "the owner could not take its own shortcut back")
        XCTAssertNil(hotkey.shortcutLabel)
    }

    // MARK: - The press

    func testAPressWithinASecondIsIgnored() {
        let registrar = FakeMeetingHotkeyRegistrar()
        var now = Date()
        let hotkey = MeetingHelpHotkey(registrar: registrar, clock: { now })
        var presses = 0
        hotkey.onPress = { presses += 1 }
        hotkey.register(keyCode: 36, modifiers: controlKey, owner: owner)

        registrar.press()
        now = now.addingTimeInterval(0.5)
        registrar.press()
        XCTAssertEqual(presses, 1, "the second press is the same press")

        now = now.addingTimeInterval(0.6)
        registrar.press()
        XCTAssertEqual(presses, 2, "a second later it is a new press")
    }

    /// The clash guard (§3.9): the combo carries a Right ⌥, and the app's
    /// global monitors see that ⌥ as a bare tap. The press has to spoil it,
    /// or every answer would translate the selected text as well.
    func testThePressSpoilsTheRightOptionTap() async {
        let service = HotkeyService()
        var translateTaps = 0
        service.register(onToggle: {}, onPTTStart: {}, onPTTStop: {},
                         onTranslateToggle: { translateTaps += 1 },
                         onTranslateLongPress: {}, onVoiceQuestionStart: {}, onVoiceQuestionStop: {})
        defer { service.unregister() }

        // Right ⌥ goes down.
        service.handleDeviceFlags(0x40)

        let registrar = FakeMeetingHotkeyRegistrar()
        let hotkey = MeetingHelpHotkey(registrar: registrar)
        hotkey.hotkeyService = service
        hotkey.register(keyCode: 36, modifiers: optionKey, owner: owner)
        registrar.press()

        // Right ⌥ comes up: without the press this would have been a tap.
        service.handleDeviceFlags(0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(translateTaps, 0, "the translate tap must not fire")

        // The control: with nothing spoiling it, the same tap does fire.
        service.handleDeviceFlags(0x40)
        service.handleDeviceFlags(0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(translateTaps, 1, "the tap fires when nothing spoils it")
    }

    /// A press that repeats inside a second is the same press, and the
    /// shortcut does not act on it — but the Right ⌥ it carries is still a
    /// foreign key, and the tap it would otherwise be must be spoiled every
    /// time (§3.9).
    func testARepeatedPressStillSpoilsTheRightOptionTap() async {
        let service = HotkeyService()
        var translateTaps = 0
        service.register(onToggle: {}, onPTTStart: {}, onPTTStop: {},
                         onTranslateToggle: { translateTaps += 1 },
                         onTranslateLongPress: {}, onVoiceQuestionStart: {}, onVoiceQuestionStop: {})
        defer { service.unregister() }

        let registrar = FakeMeetingHotkeyRegistrar()
        var now = Date()
        let hotkey = MeetingHelpHotkey(registrar: registrar, clock: { now })
        hotkey.hotkeyService = service
        hotkey.register(keyCode: 36, modifiers: optionKey, owner: owner)

        // Right ⌥ goes down, the combo is pressed, and Right ⌥ comes up: the
        // tap is spoiled by the press.
        service.handleDeviceFlags(0x40)
        registrar.press()
        service.handleDeviceFlags(0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(translateTaps, 0, "the translate tap must not fire")

        // Right ⌥ goes down again: the flag is reset.
        service.handleDeviceFlags(0x40)
        // The combo is pressed again inside a second: the shortcut ignores
        // the repeat, but the Right ⌥ is still a foreign key.
        now = now.addingTimeInterval(0.3)
        registrar.press()

        // Right ⌥ comes up: the tap must not fire.
        service.handleDeviceFlags(0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(translateTaps, 0,
                       "the repeated press let the translate tap fire")
    }
}

/// A registrar that keeps the calls instead of making them, so the tests can
/// drive the shortcut without the window server.
final class FakeMeetingHotkeyRegistrar: MeetingHotkeyRegistrar {
    struct Registration: Equatable {
        let id: UInt32
        let keyCode: Int
        let modifiers: Int
    }

    private(set) var registrations: [Registration] = []
    private(set) var unregistered: [UInt32] = []
    private(set) var handlerInstalled = false
    /// The status the registration returns.
    var status: OSStatus = noErr
    /// Whether the one application handler can be installed.
    var installSucceeds = true

    private var pressHandler: ((UInt32) -> Void)?

    func installPressHandler(_ handler: @escaping (UInt32) -> Void) -> Bool {
        pressHandler = handler
        guard installSucceeds else { return false }
        handlerInstalled = true
        return true
    }

    func register(id: UInt32, keyCode: Int, modifiers: Int) -> OSStatus {
        guard status == noErr else { return status }
        registrations.append(Registration(id: id, keyCode: keyCode, modifiers: modifiers))
        return noErr
    }

    func unregister(id: UInt32) {
        unregistered.append(id)
    }

    /// A press of the shortcut.
    func press(id: UInt32 = MeetingHelpHotkey.hotkeyID) {
        pressHandler?(id)
    }
}
