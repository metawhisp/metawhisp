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

    init(textProcessor: TextProcessor, textInserter: TextInsertionService,
         soundService: SoundService, overlay: RecordingOverlayController) {
        self.textProcessor = textProcessor
        self.textInserter = textInserter
        self.soundService = soundService
        self.overlay = overlay
    }

    /// Read the currently selected text, translate it, and paste the result back (replacing selection).
    func translateSelection() {
        guard AXIsProcessTrusted() else {
            NSLog("[SelectionTranslator] No accessibility permission")
            return
        }

        // Save the currently focused app so paste goes back to it
        textInserter.savePreviousApp()

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Clear clipboard so we can detect if Cmd+C copies something new
        pasteboard.clearContents()

        // Simulate Cmd+C to copy selected text
        simulateCmd(CGKeyCode(kVK_ANSI_C))

        // Wait for clipboard to update (some apps like Chrome are slow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                // Retry once more after another 0.3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.handleCopiedText(pasteboard: pasteboard, previousContents: previousContents)
                }
            } else {
                self.handleCopiedText(pasteboard: pasteboard, previousContents: previousContents)
            }
        }
    }

    private func handleCopiedText(pasteboard: NSPasteboard, previousContents: String?) {
        let selectedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !selectedText.isEmpty else {
            NSLog("[SelectionTranslator] No text selected, aborting")
            // Restore previous clipboard
            if let prev = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
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
                NSLog("[SelectionTranslator] ✅ Done: %d → %d chars", selectedText.count, translated.count)
            } catch {
                NSLog("[SelectionTranslator] ❌ %@", error.localizedDescription)
                soundService.playError()
                overlay.hideTranslating()
                // Restore original clipboard on failure
                if let prev = previousContents {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
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
