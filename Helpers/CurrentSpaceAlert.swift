import AppKit

/// A question the app asks on its own — a sign-in link it did not expect, a move to Applications — as an alert on the
/// Space the user is on, a full-screen one included. The alert joins every Space (`MWWindowBehavior.main`), so the
/// plain activation that brings it in front of the app the user was in switches none (WindowActivationGuardTests).
@MainActor
enum CurrentSpaceAlert {
    /// The alert: its message and its buttons, the first the default (Return); with more than one, the last answers
    /// Escape.
    static func make(_ message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        for title in buttons { alert.addButton(withTitle: title) }
        if buttons.count > 1 { alert.buttons.last?.keyEquivalent = "\u{1b}" }
        alert.window.collectionBehavior = MWWindowBehavior.main
        return alert
    }

    /// Brings the alert in front and waits for the answer: the index of the button pressed.
    static func ask(_ alert: NSAlert) -> Int {
        NSApp.activate()
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
