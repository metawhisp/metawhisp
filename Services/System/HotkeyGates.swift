import Foundation

/// The four switches of Settings → General → Hotkeys: each fixed hotkey may
/// be turned off on its own, so the keys MetaWhisp answers stay the user's.
///
/// Pure on purpose — the rules are pinned by tests without a monitor, a
/// timer or the live settings in the way. `HotkeyService` reads the switches
/// when a key arrives, so a change in the panel takes effect at once.
struct HotkeyGates: Equatable, Sendable {
    /// Right ⌘ — start/stop dictation: the short tap in Toggle mode, the
    /// hold in Push-to-Talk.
    var transcribe = true
    /// Right ⌥ short tap — translate the dictated text.
    var translate = true
    /// Right ⌘ hold — the spoken question to MetaChat (Toggle mode only).
    var voiceQuestion = true
    /// Right ⌥ hold — live translation of the microphone input.
    var autoTranslate = true

    /// The switches as the settings hold them.
    @MainActor
    static func current(_ settings: AppSettings) -> HotkeyGates {
        var gates = HotkeyGates()
        gates.transcribe = settings.transcribeHotkeyEnabled
        gates.translate = settings.translateHotkeyEnabled
        gates.voiceQuestion = settings.voiceQuestionHotkeyEnabled
        gates.autoTranslate = settings.autoTranslateHotkeyEnabled
        return gates
    }

    /// Whether Right ⌘ is the app's business in the given mode.
    ///
    /// The key carries two actions, and either being on keeps it ours. In
    /// Push-to-Talk the hold IS dictation — the mode has no action of its
    /// own, so the dictation switch alone decides.
    func tracksRightCommand(pushToTalk: Bool) -> Bool {
        pushToTalk ? transcribe : (transcribe || voiceQuestion)
    }

    /// Whether Right ⌥ is the app's business: the key carries the translate
    /// tap and the auto-translate hold, and either being on keeps it ours.
    var tracksRightOption: Bool {
        translate || autoTranslate
    }
}
