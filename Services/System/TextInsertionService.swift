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

    /// Outcome of an `insert(text:)` call. Fine-grained so callers can
    /// produce honest user-facing messages — `clipboardOnly` is "clipboard
    /// has the text, paste manually" while `clipboardFailed` is "we
    /// couldn't even put it on the clipboard, recover from History".
    enum InsertOutcome {
        case autoPasted          // clipboard verified + ⌘V CGEvent fired
        case clipboardOnly       // clipboard verified; AX denied, no auto-paste
        case clipboardFailed     // NSPasteboard write failed even after retries
    }

    /// Returns true if auto-paste worked, false otherwise. Kept for callers
    /// that don't need the granular reason.
    @discardableResult
    func insert(text: String) -> Bool {
        switch insertResult(text: text) {
        case .autoPasted: return true
        case .clipboardOnly, .clipboardFailed: return false
        }
    }

    /// Granular variant. New 2026-05-01 to expose the `clipboardFailed` case
    /// — root cause of the "ничего не вставляется ⌘V" bug. Previous
    /// version called `pasteboard.setString` and discarded its Bool return.
    /// macOS NSPasteboard ownership is racey: if another process
    /// (Universal Clipboard sync, a clipboard-manager, or macOS itself)
    /// calls `clearContents()` between OUR `clearContents()` and our
    /// `setString`, the setString returns false and text never lands.
    /// Symptom user hit: log said "Copied N chars", user presses ⌘V — nothing.
    /// Verified write + retry catches this at the source.
    func insertResult(text: String) -> InsertOutcome {
        guard Self.writeToClipboardVerified(text) else {
            NSLog("[TextInserter] ❌ clipboard write FAILED after retries — text NOT on clipboard")
            return .clipboardFailed
        }
        NSLog("[TextInserter] ✅ Copied %d chars to clipboard (verified)", text.count)

        // Try auto-paste only if accessibility is granted
        guard AXIsProcessTrusted() else {
            NSLog("[TextInserter] No accessibility — text on clipboard, user pastes manually")
            return .clipboardOnly
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
        return .autoPasted
    }

    /// Write `text` to NSPasteboard.general and verify it landed. Retries up
    /// to 3 times when:
    ///   - `setString` returns false (ownership lost mid-write), OR
    ///   - read-back doesn't match what we wrote (clipboard manager
    ///     overwrote between our write and read).
    /// Returns true only when the verified read-back matches `text`.
    /// Static so tests can call without an instance.
    static func writeToClipboardVerified(_ text: String, attempts: Int = 3) -> Bool {
        let pb = NSPasteboard.general
        for attempt in 1...attempts {
            pb.clearContents()
            let writeOK = pb.setString(text, forType: .string)
            // Tiny breath so any racing process gets a chance to land before
            // we read back. Empirically 5ms is enough on Apple Silicon — the
            // Universal Clipboard / pasteboard-manager polls run on ~50ms
            // cadence, so this either catches them on the same tick or our
            // re-write wins on the next attempt.
            usleep(5_000)
            let readBack = pb.string(forType: .string)
            if writeOK, readBack == text {
                if attempt > 1 {
                    NSLog("[TextInserter] clipboard write succeeded on attempt %d", attempt)
                }
                return true
            }
            NSLog("[TextInserter] clipboard write attempt %d failed (writeOK=%@, readBackLen=%d expected=%d)",
                  attempt, writeOK ? "yes" : "no",
                  readBack?.count ?? -1, text.count)
        }
        return false
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
