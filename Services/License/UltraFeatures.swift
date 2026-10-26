import Foundation

/// U1 (owner, 2026-10-25): screen hints and the browser agent are not part of Pro — they cost more than the yearly plan
/// brings in, and wait for a plan of their own. Until then one local switch turns them on: off unless set by hand —
/// `defaults write com.metawhisp.app ultraPreview -bool true` — and never shown in the app.
///
/// Off, the browser agent is never offered and never starts, from MetaChat, a voice question or anywhere else; the
/// screen hints and the realtime task reactor make no model call; their Settings are hidden. What the user set for them
/// is never written, so the switch on brings back exactly what they had.
enum UltraFeatures {
    /// The switch's key in the app's defaults.
    static let key = "ultraPreview"

    /// Whether the switch is on: only a stored `true` — read at each ask, never kept.
    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

extension AgentSettings {
    /// These settings behind `gate` (U1): the agent is on only while the gate is open and the user's own switch is on.
    /// The user's switch is read, never written, so an open gate brings back what they set.
    func gated(by gate: @escaping @MainActor () -> Bool) -> AgentSettings {
        var gated = self
        let usersSwitch = isOn
        gated.isOn = { gate() && usersSwitch() }
        return gated
    }
}
