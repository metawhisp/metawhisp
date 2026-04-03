import ApplicationServices
import Foundation

/// Monitors the focused text field after paste to detect user corrections.
/// Uses macOS Accessibility API to read the field content before and after editing.
@MainActor
final class CorrectionMonitor {
    private let dictionary: CorrectionDictionary
    private var monitorTask: Task<Void, Never>?

    /// Seconds to wait before first read-back from the field.
    private static let readDelay: TimeInterval = 8.0
    /// Seconds between stability reads (field must be unchanged between two reads).
    private static let stabilityInterval: TimeInterval = 3.0
    /// Maximum stability retries before giving up.
    private static let maxStabilityRetries = 5
    /// Seconds to wait after paste before first read (paste needs to complete).
    private static let pasteDelay: TimeInterval = 0.5

    init(dictionary: CorrectionDictionary) {
        self.dictionary = dictionary
    }

    /// Start monitoring after pasting text. Reads the field after a delay to detect edits.
    func startMonitoring(pastedText: String) {
        monitorTask?.cancel()

        monitorTask = Task { @MainActor in
            // Wait for paste to complete (Cmd+V is async)
            try? await Task.sleep(nanoseconds: UInt64(Self.pasteDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            // Read field content right after paste
            guard let element = getFocusedTextElement(),
                  let contentAfterPaste = getElementValue(element) else {
                NSLog("[CorrectionMonitor] Cannot read focused element after paste")
                return
            }

            // Find our pasted text in the field
            guard let range = contentAfterPaste.range(of: pastedText) else {
                NSLog("[CorrectionMonitor] Pasted text not found in field")
                return
            }

            let prefixBefore = String(contentAfterPaste[..<range.lowerBound])
            let suffixAfter = String(contentAfterPaste[range.upperBound...])

            // Read placeholder to avoid learning it as a correction
            let placeholder = getPlaceholder(element) ?? ""

            NSLog("[CorrectionMonitor] Watching: prefix=%d, pasted=%d, suffix=%d, placeholder='%@'",
                  prefixBefore.count, pastedText.count, suffixAfter.count, placeholder)

            // Wait for user to start editing
            try? await Task.sleep(nanoseconds: UInt64(Self.readDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            // Stability loop: read twice, only proceed if field content is stable
            var contentAfterEdit: String?
            for attempt in 1...Self.maxStabilityRetries {
                guard let read1 = getElementValue(element) else {
                    NSLog("[CorrectionMonitor] Cannot read element (attempt %d), skipping", attempt)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.stabilityInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let read2 = getElementValue(element) else {
                    NSLog("[CorrectionMonitor] Cannot read element (stability check), skipping")
                    return
                }
                if read1 == read2 {
                    contentAfterEdit = read2
                    NSLog("[CorrectionMonitor] Field stable after %d attempt(s)", attempt)
                    break
                }
                NSLog("[CorrectionMonitor] Field still changing (attempt %d/%d)", attempt, Self.maxStabilityRetries)
            }

            guard let contentAfterEdit else {
                NSLog("[CorrectionMonitor] Field never stabilized, skipping")
                return
            }

            // If field matches placeholder → user sent/cleared the message, skip
            if contentAfterEdit.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
               || contentAfterEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("[CorrectionMonitor] Field cleared (placeholder/empty), skipping")
                return
            }

            // Verify field structure: should still have same prefix
            guard contentAfterEdit.hasPrefix(prefixBefore) else {
                NSLog("[CorrectionMonitor] Prefix changed, skipping")
                return
            }

            // Extract the edited region (between prefix and suffix)
            let afterPrefix = String(contentAfterEdit.dropFirst(prefixBefore.count))
            let editedText: String
            if suffixAfter.isEmpty {
                editedText = afterPrefix
            } else if afterPrefix.hasSuffix(suffixAfter) {
                editedText = String(afterPrefix.dropLast(suffixAfter.count))
            } else {
                NSLog("[CorrectionMonitor] Suffix changed, skipping")
                return
            }

            // Skip if no actual change
            guard editedText != pastedText else {
                NSLog("[CorrectionMonitor] No changes detected")
                return
            }

            // Skip if edit has zero common words with original (= field was replaced entirely)
            if !hasWordOverlap(editedText, pastedText) {
                NSLog("[CorrectionMonitor] No word overlap, skipping (field likely replaced)")
                return
            }

            NSLog("[CorrectionMonitor] Detected edit: '%@' → '%@'",
                  String(pastedText.prefix(50)), String(editedText.prefix(50)))
            dictionary.learn(original: pastedText, corrected: editedText)
        }
    }

    // MARK: - Helpers

    /// Check if two strings share at least one word (case-insensitive).
    private func hasWordOverlap(_ a: String, _ b: String) -> Bool {
        let wordsA = Set(a.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let wordsB = Set(b.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        return !wordsA.isDisjoint(with: wordsB)
    }

    // MARK: - Accessibility

    private func getFocusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private func getElementValue(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }

    private func getPlaceholder(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }
}
