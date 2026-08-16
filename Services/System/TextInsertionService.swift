import AppKit
import Carbon
import Foundation

/// Prevents a delayed restoration from overwriting a copy made by the user or
/// another process after a temporary layout-correction paste.
struct PasteboardRestorationGuard {
    static func shouldRestore(currentChangeCount: Int, expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
    }
}

/// A copied selection must exactly match the range that the caller intended
/// to replace. This prevents a stale selection or old clipboard value from
/// being pasted over unrelated text.
struct SelectionCopyValidation {
    static func matches(copiedText: String?, expectedText: String) -> Bool {
        copiedText == expectedText
    }
}

/// Owns a temporary replacement value on the pasteboard. The original
/// representations stay in RAM and are restored only if nothing else copied
/// over the replacement in the meantime.
final class PasteboardReplacementTransaction {
    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private var ownedChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    }

    @discardableResult
    func prepare(replacement: String) -> Bool {
        guard TextInsertionService.writeToClipboardVerified(replacement, to: pasteboard) else {
            return false
        }
        markCurrentContentsAsOwned()
        return true
    }

    func beginSelectionCopy() {
        pasteboard.clearContents()
        markCurrentContentsAsOwned()
    }

    /// Our synthetic Cmd-C is executed by the TARGET APPLICATION, so it
    /// advances `changeCount` exactly once — and until this existed, that
    /// advance was indistinguishable from a stranger copying. `restoreIfOwned`
    /// concluded it no longer owned the pasteboard and walked away, so every
    /// aborted correction destroyed the user's clipboard and left the text
    /// they had just typed sitting on it (release review, 2026-08-16; with
    /// Universal Clipboard on, that text left the Mac).
    ///
    /// Exactly one advance is ours. Anything else is somebody else's copy and
    /// must be left strictly alone.
    @discardableResult
    func acknowledgeSelectionCopy() -> Bool {
        guard let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount + 1 else {
            return false
        }
        self.ownedChangeCount = pasteboard.changeCount
        return true
    }

    func stillOwns(contents: String) -> Bool {
        guard let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount else {
            return false
        }
        return pasteboard.string(forType: .string) == contents
    }

    private func markCurrentContentsAsOwned() {
        ownedChangeCount = pasteboard.changeCount
    }

    func restoreIfOwned() {
        guard let ownedChangeCount,
              PasteboardRestorationGuard.shouldRestore(
                  currentChangeCount: pasteboard.changeCount,
                  expectedChangeCount: ownedChangeCount
              ) else {
            return
        }
        _ = snapshot.restore(to: pasteboard)
    }
}

/// Keeps all available clipboard representations in RAM briefly. It is
/// intentionally not persisted or logged.
private struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }
}

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
    static func writeToClipboardVerified(
        _ text: String,
        to pasteboard: NSPasteboard = .general,
        attempts: Int = 3
    ) -> Bool {
        for attempt in 1...attempts {
            pasteboard.clearContents()
            let writeOK = pasteboard.setString(text, forType: .string)
            // Tiny breath so any racing process gets a chance to land before
            // we read back. Empirically 5ms is enough on Apple Silicon — the
            // Universal Clipboard / pasteboard-manager polls run on ~50ms
            // cadence, so this either catches them on the same tick or our
            // re-write wins on the next attempt.
            usleep(5_000)
            let readBack = pasteboard.string(forType: .string)
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

    /// Replaces an AX-selected range only after a real Command-C confirms the
    /// target editor committed that exact selection. This follows the same
    /// copy-then-paste protocol used by layout switchers for rich editors
    /// which acknowledge AX writes without applying them.
    static func replaceVerifiedSelectionPreservingPasteboard(
        expectedText: String,
        replacement: String,
        targetIsStillFocused: () -> Bool
    ) async -> Bool {
        guard targetIsStillFocused() else { return false }

        let transaction = PasteboardReplacementTransaction()
        defer { transaction.restoreIfOwned() }

        let pasteboard = NSPasteboard.general
        transaction.beginSelectionCopy()
        guard postLayoutCommandKey(CGKeyCode(kVK_ANSI_C)) else { return false }
        NSLog("[LayoutFix] Selection copy requested")

        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return false
        }

        // Claim our own copy BEFORE anything can bail out, so every failure
        // path below still restores the user's clipboard via the `defer`.
        let ownsCopy = transaction.acknowledgeSelectionCopy()
        let copiedText = pasteboard.string(forType: .string)
        guard targetIsStillFocused(),
              ownsCopy,
              SelectionCopyValidation.matches(copiedText: copiedText, expectedText: expectedText),
              transaction.prepare(replacement: replacement) else {
            return false
        }

        do {
            try await Task.sleep(for: .milliseconds(32))
        } catch {
            return false
        }

        guard targetIsStillFocused(),
              transaction.stillOwns(contents: replacement),
              postLayoutCommandKey(CGKeyCode(kVK_ANSI_V)) else {
            return false
        }
        NSLog("[LayoutFix] Selection paste requested")

        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return false
        }
        return targetIsStillFocused()
    }

    private func simulatePaste() {
        guard Self.postCommandPaste() else {
            NSLog("[TextInserter] ❌ Failed to create CGEvents")
            return
        }
        NSLog("[TextInserter] ✅ Auto-pasted via Cmd+V")
    }

    @discardableResult
    private static func postCommandPaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private static func postLayoutCommandKey(_ virtualKey: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
