import AppKit
import Carbon
import Foundation

/// Inserts transcribed text into the active application.
/// Always copies to clipboard. If Accessibility is granted, also simulates Cmd+V.
final class TextInsertionService {

    /// The app that was active before MetaWhisp took focus (for restoring focus before paste).
    private var previousApp: NSRunningApplication?

    /// Remember the currently focused app (call before MetaWhisp steals focus).
    func savePreviousApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = app
            NSLog("[TextInserter] Saved previous app: %@", app.localizedName ?? "?")
        }
    }

    /// Returns true if auto-paste worked, false if only clipboard was set.
    @discardableResult
    func insert(text: String) -> Bool {
        // Always copy to clipboard — text stays there for manual Cmd+V
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NSLog("[TextInserter] Copied %d chars to clipboard", text.count)

        // Try auto-paste only if accessibility is granted
        guard AXIsProcessTrusted() else {
            NSLog("[TextInserter] No accessibility — text on clipboard, user pastes manually")
            return false
        }

        // Restore focus to previous app before pasting
        if let prev = previousApp, !prev.isTerminated {
            prev.activate()
            NSLog("[TextInserter] Restoring focus to: %@", prev.localizedName ?? "?")
            // Longer delay to allow app activation before Cmd+V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.simulatePaste()
            }
        } else {
            // No saved app — try to find frontmost non-self app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.simulatePaste()
            }
        }
        return true
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            NSLog("[TextInserter] ❌ Failed to create CGEvents")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        NSLog("[TextInserter] ✅ Auto-pasted via Cmd+V")
    }
}
