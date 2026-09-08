import AppKit
import Carbon
import Foundation

/// Reads selected text from any app, translates it via OpenAI, and pastes the result back.
/// Triggered by Right ⌥ long-press (≥2s).
@MainActor
final class SelectionTranslator {
    private let textProcessor: TextProcessor
    private let textInserter: TextInsertionService
    private let soundService: SoundService
    private let overlay: RecordingOverlayController
    private let pasteboard: NSPasteboard

    init(textProcessor: TextProcessor, textInserter: TextInsertionService,
         soundService: SoundService, overlay: RecordingOverlayController,
         pasteboard: NSPasteboard = .general) {
        self.textProcessor = textProcessor
        self.textInserter = textInserter
        self.soundService = soundService
        self.overlay = overlay
        self.pasteboard = pasteboard
    }

    /// Reading the selection means borrowing the clipboard: clear it, ask the
    /// app to copy, take what lands. Everything borrowed is given back — every
    /// representation, on every path, including success — and never over a
    /// copy the user made meanwhile.
    ///
    /// This is `PasteboardReplacementTransaction`'s contract, which the layout
    /// fix has kept since 2026-08-16 (`LayoutClipboardOwnershipTests`). The
    /// translator kept its own: a snapshot of the plain-text flavour only, a
    /// `clearContents()` that destroyed the rest, and no restore at all when
    /// the translation succeeded.
    final class ClipboardBorrow {
        private let transaction: PasteboardReplacementTransaction

        init(pasteboard: NSPasteboard) {
            transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)
        }

        /// Clear, so a copy that lands is recognisably new.
        func begin() { transaction.beginSelectionCopy() }

        /// Exactly one advance is the app answering our synthetic ⌘C.
        @discardableResult
        func acknowledgeCopy() -> Bool { transaction.acknowledgeSelectionCopy() }

        /// Put back what we took, unless somebody else owns the clipboard now.
        func giveBack() { transaction.restoreIfOwned() }
    }

    /// Read the currently selected text, translate it, and paste the result back (replacing selection).
    func translateSelection() {
        guard AXIsProcessTrusted() else {
            NSLog("[SelectionTranslator] No accessibility permission")
            return
        }

        // Save the currently focused app so paste goes back to it
        textInserter.savePreviousApp()

        let borrow = ClipboardBorrow(pasteboard: pasteboard)
        borrow.begin()
        NSLog("[SelectionTranslator] borrowing the clipboard to read the selection")

        // Simulate Cmd+C to copy selected text
        simulateCmd(CGKeyCode(kVK_ANSI_C))

        // Wait for clipboard to update (some apps like Chrome are slow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                // Retry once more after another 0.3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.handleCopiedText(borrow: borrow)
                }
            } else {
                self.handleCopiedText(borrow: borrow)
            }
        }
    }

    private func handleCopiedText(borrow: ClipboardBorrow) {
        let owned = borrow.acknowledgeCopy()
        let selectedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard owned, !selectedText.isEmpty else {
            NSLog("[SelectionTranslator] nothing to translate (copy landed: %@, %d chars) — clipboard given back",
                  owned ? "yes" : "no", selectedText.count)
            borrow.giveBack()
            return
        }

        NSLog("[SelectionTranslator] Got %d chars, translating...", selectedText.count)
        soundService.playTranslateStart()
        overlay.showTranslating()

        Task { @MainActor in
            do {
                let translated = try await textProcessor.translateOnly(selectedText)
                // Paste replaces the selection (text is still selected in the target app)
                textInserter.insert(text: translated)
                soundService.playTranslateDone()
                overlay.hideTranslating()
                NSLog("[SelectionTranslator] ✅ done: %d → %d chars, clipboard given back",
                      selectedText.count, translated.count)
                borrow.giveBack()
            } catch {
                NSLog("[SelectionTranslator] ❌ %@ — clipboard given back", error.localizedDescription)
                soundService.playError()
                overlay.hideTranslating()
                borrow.giveBack()
                // `playError()` has an empty body and this class has no
                // banner, so a failure used to look exactly like the hotkey
                // never firing (audit, P1). Say it on the card surface every
                // other feature uses.
                let words = SelectionTranslateFeedback.wording(for: error)
                MWNotificationStack.shared.push(
                    MWNotification(kind: .advice, title: words.title, body: words.body, onTap: nil))
            }
        }
    }

    private func simulateCmd(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
