import AppKit
import Carbon
import Foundation

/// Reads selected text from any app, translates it via OpenAI, and pastes the result back.
/// Triggered by Right ⌥ long-press (≥2s).
@MainActor
final class SelectionTranslator {
    private let textProcessor: TextProcessor
    private let soundService: SoundService
    private let overlay: RecordingOverlayController
    private let pasteboard: NSPasteboard
    private var operationGate = OperationGate()

    struct OperationGate {
        private var isRunning = false

        mutating func begin() -> Bool {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }

        mutating func finish() { isRunning = false }
    }

    init(textProcessor: TextProcessor,
         soundService: SoundService, overlay: RecordingOverlayController,
         pasteboard: NSPasteboard = .general) {
        self.textProcessor = textProcessor
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
        private let pasteboard: NSPasteboard
        private let targetPID: pid_t?
        private let targetBundleIdentifier: String?
        private let readText: () -> String?
        private var copiedText: String?

        init(pasteboard: NSPasteboard, targetPID: pid_t? = nil,
             targetBundleIdentifier: String? = nil, readText: (() -> String?)? = nil) {
            transaction = PasteboardReplacementTransaction(pasteboard: pasteboard)
            self.pasteboard = pasteboard
            self.targetPID = targetPID
            self.targetBundleIdentifier = targetBundleIdentifier
            self.readText = readText ?? { pasteboard.string(forType: .string) }
        }

        /// Clear, so a copy that lands is recognisably new.
        func begin() { transaction.beginSelectionCopy() }

        /// Exactly one advance is the app answering our synthetic ⌘C.
        @discardableResult
        func acknowledgeCopy() -> Bool { transaction.acknowledgeSelectionCopy() }

        func readCopiedText(frontmostPID: () -> pid_t?) -> (owned: Bool, text: String) {
            guard let targetPID, frontmostPID() == targetPID else { return (false, "") }
            let beforeRead = pasteboard.changeCount
            let rawText = readText() ?? ""
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let types = pasteboard.types ?? []
            guard frontmostPID() == targetPID, pasteboard.changeCount == beforeRead else {
                return (false, text)
            }
            // The native Telegram composer clears, then declares its rich
            // representations. Both ownership changes belong to that copy.
            let isTelegramRichCopy = targetBundleIdentifier == "ru.keepcoder.Telegram"
                && types.contains(.rtf)
                && types.contains(NSPasteboard.PasteboardType("TelegramTextPboardType"))
                && !text.isEmpty
            NSLog("[SelectionTranslator] copy source pid=%d, native rich copy=%@",
                  targetPID, isTelegramRichCopy ? "yes" : "no")
            let owned = transaction.acknowledgeSelectionCopy(
                expectedChanges: isTelegramRichCopy ? 2 : 1, logChanges: true)
            if owned { copiedText = rawText }
            return (owned, text)
        }

        func pasteTranslation(_ text: String, frontmostPID: () -> pid_t?,
                              waitBeforePaste: () async -> Void, postPaste: () -> Bool,
                              settlePaste: () async -> Void) async -> Bool {
            defer { giveBack() }
            guard !Task.isCancelled, let targetPID, let copiedText,
                  frontmostPID() == targetPID,
                  transaction.stillOwns(contents: copiedText) else { return false }
            guard transaction.prepare(replacement: text) else { return false }
            await waitBeforePaste()
            guard !Task.isCancelled, frontmostPID() == targetPID,
                  transaction.stillOwns(contents: text) else { return false }
            guard postPaste() else { return false }
            // Once posted, cancellation cannot retract the event. Keep the
            // replacement available for the same bounded settling period.
            await settlePaste()
            return true
        }

        /// Put back what we took, unless somebody else owns the clipboard now.
        func giveBack() { transaction.restoreIfOwned() }
    }

    /// Read the currently selected text, translate it, and paste the result back (replacing selection).
    func translateSelection() {
        guard AXIsProcessTrusted() else {
            NSLog("[SelectionTranslator] No accessibility permission")
            return
        }
        guard operationGate.begin() else { return }

        let targetApp = NSWorkspace.shared.frontmostApplication
        let borrow = ClipboardBorrow(pasteboard: pasteboard,
                                     targetPID: targetApp?.processIdentifier,
                                     targetBundleIdentifier: targetApp?.bundleIdentifier)
        borrow.begin()
        NSLog("[SelectionTranslator] borrowing the clipboard to read the selection")

        // Simulate Cmd+C to copy selected text
        simulateCmd(CGKeyCode(kVK_ANSI_C))

        // Wait for clipboard to update (some apps like Chrome are slow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { borrow.giveBack(); return }
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
        let copy = borrow.readCopiedText { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let owned = copy.owned
        let selectedText = copy.text

        guard owned, !selectedText.isEmpty else {
            NSLog("[SelectionTranslator] nothing to translate (copy landed: %@, %d chars) — clipboard given back",
                  owned ? "yes" : "no", selectedText.count)
            borrow.giveBack()
            operationGate.finish()
            return
        }

        NSLog("[SelectionTranslator] Got %d chars, translating...", selectedText.count)
        soundService.playTranslateStart()
        overlay.showTranslating()

        Task { @MainActor in
            defer { operationGate.finish() }
            do {
                let translated = try await textProcessor.translateOnly(selectedText)
                let pasted = await borrow.pasteTranslation(
                    translated,
                    frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    waitBeforePaste: { await Self.pauseBeforeClipboardRead(0.032) },
                    postPaste: { AXIsProcessTrusted() && self.simulateCmd(CGKeyCode(kVK_ANSI_V)) },
                    settlePaste: { await Self.pauseBeforeClipboardRead(0.18) })
                guard pasted else {
                    overlay.hideTranslating()
                    NSLog("[SelectionTranslator] paste abandoned before posting")
                    return
                }
                soundService.playTranslateDone()
                overlay.hideTranslating()
                NSLog("[SelectionTranslator] paste sent: %d → %d chars, clipboard cleanup complete",
                      selectedText.count, translated.count)
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

    private static func pauseBeforeClipboardRead(_ seconds: TimeInterval) async {
        // Deliberately not Task.sleep: an already posted paste still needs its
        // settling time when cancellation arrives. This is not a read-back.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    @discardableResult
    private func simulateCmd(_ keyCode: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
