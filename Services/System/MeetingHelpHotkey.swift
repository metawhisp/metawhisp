import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - The combo

/// The default help shortcut: ⌃↩ (§3.8).
enum MeetingHelpDefaults {
    /// Return.
    static let keyCode = 36
    /// Control.
    static let modifiers = controlKey
}

/// The help shortcut as the settings store it: a virtual key code and a
/// Carbon modifier mask.
///
/// Carbon is the only way to get a shortcut that works while another app has
/// the focus, without an Accessibility grant and without taking the key away
/// from the app the user is typing in.
struct MeetingHelpCombo: Equatable, Sendable {
    /// The virtual key code.
    let keyCode: Int
    /// The Carbon modifier mask.
    let modifiers: Int

    /// The label the overlay shows — "⌃↩".
    var label: String { MeetingHelpLabel.label(keyCode: keyCode, modifiers: modifiers) }
}

/// Why the recorder refused a combo (§3.8).
enum MeetingHelpRefusal: String, Equatable, Sendable, Error {
    /// The combo carried ⌘.
    case commandNotAllowed
    /// The combo was a modifier key on its own.
    case modifierOnly
    /// The combo had neither ⌃ nor ⌥.
    case needsControlOrOption

    /// The sentence the Settings row shows under the recorder.
    var message: String {
        switch self {
        case .commandNotAllowed:
            return "⌘ is not allowed — it would start dictation."
        case .modifierOnly:
            return "That is only a modifier — add a letter, a number or Return."
        case .needsControlOrOption:
            return "Needs ⌃ or ⌥ — a bare key would fire while you type."
        }
    }
}

/// The rules of the shortcut recorder (§3.8).
///
/// Pure on purpose: the same keys always give the same answer, so the rules
/// are pinned by tests without a window in the way.
enum MeetingHelpComboValidator {
    /// The key codes of the modifier keys — both sides.
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62]

    /// Whether the key code is a modifier key.
    static func isModifierKey(_ keyCode: Int) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    /// Checks a combo and hands it back when it is allowed.
    static func validate(keyCode: Int, modifiers: Int) -> Result<MeetingHelpCombo, MeetingHelpRefusal> {
        // ⌘ first. Carbon cannot tell the left ⌘ from the right one, and a
        // Right ⌘ inside the combo would reach dictation's push-to-talk
        // branch, which ignores foreign keys.
        if modifiers & cmdKey != 0 { return .failure(.commandNotAllowed) }
        // A modifier on its own is not a shortcut.
        if isModifierKey(keyCode) { return .failure(.modifierOnly) }
        // Without ⌃ or ⌥ the key would fire in whatever the user is typing in.
        if modifiers & (controlKey | optionKey) == 0 { return .failure(.needsControlOrOption) }
        return .success(MeetingHelpCombo(keyCode: keyCode, modifiers: modifiers))
    }
}

/// The mapping from the AppKit modifier flags to the Carbon mask (§3.9).
enum MeetingHelpModifiers {
    /// The Carbon mask for the flags. Pure.
    static func carbonMask(for flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        return mask
    }
}

/// The label of a combo — "⌃↩" — as the overlay and the Settings row show
/// it. Pure.
enum MeetingHelpLabel {
    /// The whole label.
    static func label(keyCode: Int, modifiers: Int) -> String {
        parts(keyCode: keyCode, modifiers: modifiers).joined()
    }

    /// The parts of the label: the modifiers, then the key. The Settings row
    /// draws one keycap per part.
    static func parts(keyCode: Int, modifiers: Int) -> [String] {
        var out: [String] = []
        if modifiers & controlKey != 0 { out.append("⌃") }
        if modifiers & optionKey != 0 { out.append("⌥") }
        if modifiers & shiftKey != 0 { out.append("⇧") }
        if modifiers & cmdKey != 0 { out.append("⌘") }
        out.append(keyName(keyCode))
        return out
    }

    /// The name of a key. The US layout does not put the letters and the
    /// digits in the alphabet's order, so they are written out.
    static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case 36: return "↩"   // Return
        case 48: return "⇥"   // Tab
        case 49: return "Space"
        case 51: return "⌫"   // Delete
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let letter = letters[keyCode] { return letter }
            if let digit = digits[keyCode] { return digit }
            return "Key \(keyCode)"
        }
    }

    private static let letters: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
    ]

    private static let digits: [Int: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
    ]
}

// MARK: - The recorder's rules

/// What the recorder does with a key press.
enum MeetingHelpRecorderAction: Equatable {
    /// The press belongs to another window: it goes on to the app.
    case pass
    /// Esc: the recording is over and the shortcut stays as it was.
    case cancelled
    /// The combo was accepted.
    case accepted(MeetingHelpCombo)
    /// The combo was refused.
    case refused(MeetingHelpRefusal)
}

/// The rules of the recorder, as the monitor needs them (§3.8).
///
/// The recorder belongs to the window that records the combo. A press of
/// another window is not the recorder's: it goes on to the app, so the user
/// keeps typing where they were typing.
enum MeetingHelpRecorderRules {

    /// What the recorder does with a press.
    ///
    /// - Parameters:
    ///   - keyCode: the key that was pressed.
    ///   - modifiers: the Carbon mask of the modifiers that were held.
    ///   - isOwnWindow: whether the press happened in the window that
    ///     records the combo.
    static func action(keyCode: Int, modifiers: Int, isOwnWindow: Bool) -> MeetingHelpRecorderAction {
        guard isOwnWindow else { return .pass }
        // Esc: the shortcut stays as it was.
        if keyCode == 53 { return .cancelled }
        switch MeetingHelpComboValidator.validate(keyCode: keyCode, modifiers: modifiers) {
        case .success(let combo): return .accepted(combo)
        case .failure(let reason): return .refused(reason)
        }
    }
}

// MARK: - The registration

/// The registration behind a protocol, so the tests can drive the shortcut
/// without the window server.
protocol MeetingHotkeyRegistrar: AnyObject {
    /// Installs the one application event handler that serves the hot key.
    /// Returns false when it cannot be installed.
    func installPressHandler(_ handler: @escaping (UInt32) -> Void) -> Bool
    /// Registers a hot key and returns the status — 0 is ok.
    func register(id: UInt32, keyCode: Int, modifiers: Int) -> OSStatus
    /// Takes the hot key with that id back.
    func unregister(id: UInt32)
}

/// The Carbon registration: the window server's own hot key table.
///
/// The handler is installed once on the application event target and lives
/// for the app: a hot key press arrives there, and nowhere else.
final class CarbonMeetingHotkeyRegistrar: MeetingHotkeyRegistrar {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var pressHandler: ((UInt32) -> Void)?

    func installPressHandler(_ handler: @escaping (UInt32) -> Void) -> Bool {
        pressHandler = handler
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The callback carries no context of its own: it finds the registrar
        // through the pointer the handler was installed with.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return OSStatus(noErr) }
                let registrar = Unmanaged<CarbonMeetingHotkeyRegistrar>.fromOpaque(userData)
                    .takeUnretainedValue()
                registrar.handle(event: event)
                return OSStatus(noErr)
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        return status == noErr
    }

    func register(id: UInt32, keyCode: Int, modifiers: Int) -> OSStatus {
        var hotKeyID = EventHotKeyID(signature: MeetingHelpHotkey.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                          GetApplicationEventTarget(),
                                          OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr { hotKeyRefs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = hotKeyRefs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    /// The hot key that was pressed.
    private func handle(event: EventRef?) {
        guard let event else { return }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID),
                                      nil,
                                      MemoryLayout<EventHotKeyID>.size,
                                      nil,
                                      &hotKeyID)
        guard status == noErr else { return }
        pressHandler?(hotKeyID.id)
    }
}

// MARK: - The shortcut

/// The help shortcut, as the live hints see it.
///
/// The Carbon hot key is behind this protocol, so the session that owns the
/// shortcut during a meeting can be driven by a fake in the tests.
@MainActor
protocol MeetingHelpShortcut: AnyObject, Sendable {
    /// The label of the registered shortcut — nil when nothing is registered
    /// or the registration failed.
    var shortcutLabel: String? { get }
    /// Called on every accepted press.
    var onPress: (() -> Void)? { get set }
    /// Registers the shortcut for an owner.
    ///
    /// The owner is the session that took the shortcut: only that owner may
    /// take it back (§6.15).
    ///
    /// Answers whether the shortcut was really taken: a registration that
    /// failed leaves the session without a shortcut, so it may try again
    /// (§3.9).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, owner: UUID) -> Bool
    /// Takes the shortcut back — but only from the owner that holds it.
    ///
    /// A session that was stopped may not take the shortcut away from the
    /// session that holds it now. Answers whether the shortcut was really
    /// taken back.
    @discardableResult
    func unregister(owner: UUID) -> Bool
}

/// The shortcut that asks for an answer during a meeting (§3.9).
///
/// One application event handler serves the whole app: it is installed once
/// and stays. The shortcut itself is registered only while a meeting with
/// hints is recording, so the app is not listening for keys the rest of the
/// time.
@MainActor
final class MeetingHelpHotkey: ObservableObject, MeetingHelpShortcut {
    /// The app's one instance.
    static let shared = MeetingHelpHotkey()

    /// The id of the hot key the handler knows.
    static let hotkeyID: UInt32 = 1
    /// The signature that goes with the id — four characters, "MWH1".
    static let signature: OSType = 0x4D57_4831
    /// Two presses within a second are one press (§3.6).
    static let repeatWindow: TimeInterval = 1

    /// The label of the registered shortcut — the overlay shows it. Nil when
    /// nothing is registered or the registration failed.
    @Published private(set) var shortcutLabel: String?
    /// Why the shortcut could not be registered.
    @Published private(set) var registrationError: String?

    /// The app's hot key service. A press has to reach it: a Right ⌥ inside
    /// the combo would otherwise read as a translate tap.
    weak var hotkeyService: HotkeyService?

    /// Called on every accepted press.
    var onPress: (() -> Void)?

    private let registrar: MeetingHotkeyRegistrar
    private let clock: () -> Date
    private var lastPress: Date?
    private var isRegistered = false
    /// The owner that holds the registration right now.
    ///
    /// A session that was stopped may not take the shortcut away from the
    /// session that holds it now: a late balance failure of the old meeting
    /// must not reach into the new one (§6.15).
    private var currentOwner: UUID?

    init(registrar: MeetingHotkeyRegistrar = CarbonMeetingHotkeyRegistrar(),
         clock: @escaping () -> Date = { Date() }) {
        self.registrar = registrar
        self.clock = clock
    }

    /// Registers the shortcut. A change takes the old one back first; a
    /// failure is published for the Settings row and the overlay.
    ///
    /// Answers whether the shortcut was really taken: the session that asked
    /// holds no shortcut when the registration failed, and it may try again
    /// (§3.9).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, owner: UUID) -> Bool {
        takeBack()
        guard registrar.installPressHandler({ [weak self] id in self?.handlePress(id) }) else {
            NSLog("[MeetingHelpHotkey] ❌ the application handler could not be installed")
            registrationError = "This shortcut could not be registered — pick another"
            shortcutLabel = nil
            return false
        }
        let status = registrar.register(id: Self.hotkeyID, keyCode: keyCode, modifiers: modifiers)
        guard status == noErr else {
            NSLog("[MeetingHelpHotkey] ❌ the shortcut could not be registered — status %d", status)
            registrationError = Self.errorMessage(for: status)
            shortcutLabel = nil
            return false
        }
        isRegistered = true
        currentOwner = owner
        registrationError = nil
        shortcutLabel = MeetingHelpLabel.label(keyCode: keyCode, modifiers: modifiers)
        NSLog("[MeetingHelpHotkey] ✅ %@ registered", shortcutLabel ?? "")
        return true
    }

    /// Takes the shortcut back: at the end of a meeting, when the hints are
    /// turned off, or when the combo changes.
    ///
    /// Only the owner that holds the registration may take it back — an old
    /// session that was stopped never takes the new one's shortcut away
    /// (§6.15).
    @discardableResult
    func unregister(owner: UUID) -> Bool {
        guard currentOwner == owner else { return false }
        takeBack()
        onPress = nil
        return true
    }

    /// Gives the hot key back to the window server. The owner goes with it.
    private func takeBack() {
        guard isRegistered else {
            currentOwner = nil
            return
        }
        registrar.unregister(id: Self.hotkeyID)
        isRegistered = false
        currentOwner = nil
        shortcutLabel = nil
    }

    /// The reason the shortcut was refused, in the words the Settings row
    /// shows.
    static func errorMessage(for status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "This shortcut is taken by another app — pick another"
        }
        return "This shortcut could not be registered — pick another"
    }

    /// A press of the shortcut.
    private func handlePress(_ id: UInt32) {
        guard id == Self.hotkeyID else { return }
        // The app's own modifier taps must not read the combo as a tap. Every
        // press marks the foreign key — a press that repeats inside a second
        // is ignored as an action, but the Right ⌥ it carries still has to be
        // spoiled, or the tap fires and starts or stops a recording.
        hotkeyService?.noteForeignKeyPress()
        let now = clock()
        // Two presses within a second are one press: the hand rests on the key.
        if let last = lastPress, now.timeIntervalSince(last) < Self.repeatWindow { return }
        lastPress = now
        onPress?()
    }
}
