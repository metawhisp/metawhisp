import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Computes the UTF-16 range of the buffered token immediately before a
/// separator. Accessibility APIs use UTF-16 offsets, unlike Swift `String`.
struct LayoutReplacementRange {
    static func plan(
        caretUTF16Offset: Int,
        expectedToken: String,
        trailingText: String
    ) -> NSRange? {
        let tokenLength = (expectedToken as NSString).length
        let trailingLength = (trailingText as NSString).length
        let totalLength = tokenLength + trailingLength

        guard tokenLength > 0, caretUTF16Offset >= totalLength else { return nil }
        return NSRange(
            location: caretUTF16Offset - totalLength,
            length: tokenLength
        )
    }
}

/// Validates that the Accessibility target still contains the buffered token.
/// Rich editors commonly expose bounded text through `AXStringForRange` while
/// omitting the full `AXValue`, so the bounded value takes precedence.
struct LayoutReplacementTextValidation {
    static func matches(
        expectedText: String,
        range: NSRange,
        boundedText: String?,
        fullText: String?
    ) -> Bool {
        if let boundedText {
            return boundedText == expectedText
        }

        guard let fullText else { return false }
        let nsText = fullText as NSString
        guard NSMaxRange(range) <= nsText.length else { return false }
        return nsText.substring(with: range) == expectedText
    }
}

/// Bounds the small Accessibility read used for an explicit Double Shift
/// correction. The range ends at the caret and never reaches forward.
struct LayoutContextWindow {
    static func plan(beforeCaretUTF16Offset caret: Int, maximumLength: Int) -> NSRange? {
        guard caret >= 0, maximumLength > 0 else { return nil }
        let length = min(caret, maximumLength)
        return NSRange(location: caret - length, length: length)
    }
}

/// Finds the complete line before the insertion point without reaching into
/// an earlier line. The range is UTF-16 because Accessibility uses UTF-16
/// offsets and includes any trailing spaces before the caret.
struct LayoutCurrentLineRange {
    static func plan(
        in text: String,
        caretUTF16Offset: Int,
        contextStartsAtDocumentStart: Bool = true
    ) -> NSRange? {
        let nsText = text as NSString
        guard (0...nsText.length).contains(caretUTF16Offset) else { return nil }

        var start = caretUTF16Offset
        while start > 0 {
            let codeUnit = nsText.character(at: start - 1)
            guard codeUnit != 0x0A, codeUnit != 0x0D else { break }
            start -= 1
        }

        guard start < caretUTF16Offset,
              contextStartsAtDocumentStart || start > 0 else {
            return nil
        }
        return NSRange(location: start, length: caretUTF16Offset - start)
    }
}

/// Keeps temporary Accessibility selection changes recoverable. It restores
/// the user's original selection on any failed replacement while the same
/// target is still focused, and never reaches back into an app that lost focus.
struct LayoutSelectionTransaction {
    static func run(
        originalSelection: NSRange,
        replacementRange: NSRange,
        caretAfterSuccess: Int?,
        targetIsStillFocused: () -> Bool,
        select: (NSRange) -> Bool,
        replace: () async -> Bool,
        verify: () -> Bool
    ) async -> Bool {
        guard targetIsStillFocused(), select(replacementRange) else { return false }

        guard await replace(), targetIsStillFocused(), verify() else {
            if targetIsStillFocused() {
                _ = select(originalSelection)
            }
            return false
        }

        if let caretAfterSuccess {
            _ = select(NSRange(location: caretAfterSuccess, length: 0))
        }
        return true
    }
}

/// Blocks text mutation in contexts where a wrong replacement has a
/// disproportionate cost or cannot be safely undone.
struct LayoutSafetyPolicy: Sendable {
    static let `default` = LayoutSafetyPolicy(
        excludedBundleIdentifiers: [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.apple.RemoteDesktop",
            "com.microsoft.rdc.macos",
            "com.microsoft.rdc.mac",
            "com.1password.1password",
            "com.bitwarden.desktop"
        ]
    )

    private let excludedBundleIdentifiers: Set<String>

    init(excludedBundleIdentifiers: Set<String>) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    init(excludedBundleIdentifiers: [String]) {
        self.init(excludedBundleIdentifiers: Set(excludedBundleIdentifiers))
    }

    func permits(bundleIdentifier: String?, isSecureField: Bool) -> Bool {
        guard !isSecureField, let bundleIdentifier else { return false }
        return !excludedBundleIdentifiers.contains(bundleIdentifier)
    }
}

/// Applies privacy exclusions before a key is admitted to the in-memory word
/// buffer. Mutation-time checks remain in `FocusedTextGateway` as a second,
/// independent boundary.
struct LayoutCaptureSafetyDecision {
    static func permits(
        bundleIdentifier: String?,
        ownBundleIdentifier: String?,
        frontmostProcessIdentifier: pid_t,
        focusedProcessIdentifier: pid_t,
        isSecureInputEnabled: Bool,
        isSecureField: Bool,
        safetyPolicy: LayoutSafetyPolicy = .default
    ) -> Bool {
        guard !isSecureInputEnabled,
              let bundleIdentifier,
              bundleIdentifier != ownBundleIdentifier,
              frontmostProcessIdentifier == focusedProcessIdentifier else {
            return false
        }
        return safetyPolicy.permits(
            bundleIdentifier: bundleIdentifier,
            isSecureField: isSecureField
        )
    }
}

/// Resolves the live AX field metadata once and applies the same privacy gate
/// at both capture time and immediately before mutation.
@MainActor
enum LayoutFocusedElementSafety {
    static func permits(
        _ focusedElement: AXUIElement,
        in frontmostApplication: NSRunningApplication,
        safetyPolicy: LayoutSafetyPolicy = .default
    ) -> Bool {
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            focusedElement,
            &focusedProcessIdentifier
        ) == .success else {
            return false
        }

        let subrole: String? = attributeValue(kAXSubroleAttribute, from: focusedElement)
        let protectedContent: NSNumber? = attributeValue(
            NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: focusedElement
        )
        let isSecureField = subrole == "AXSecureTextField"
            || protectedContent?.boolValue == true

        return LayoutCaptureSafetyDecision.permits(
            bundleIdentifier: frontmostApplication.bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            frontmostProcessIdentifier: frontmostApplication.processIdentifier,
            focusedProcessIdentifier: focusedProcessIdentifier,
            isSecureInputEnabled: IsSecureEventInputEnabled(),
            isSecureField: isSecureField,
            safetyPolicy: safetyPolicy
        )
    }

    private static func attributeValue<T>(
        _ attribute: String,
        from element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? T
    }
}

/// Replaces one validated token in the currently focused accessibility field.
///
/// There is intentionally no blind paste fallback here. Replacement is allowed
/// only after Command-C proves the exact AX-selected target and the clipboard
/// transaction can preserve any intervening user copy.
@MainActor
final class FocusedTextGateway {
    private static let manualMaximumUTF16Length = 4_096

    enum SkipReason: String, Equatable {
        case accessibilityDenied
        case noTargetApplication
        case excludedApplication
        case noFocusedTextField
        case staleTarget
        case unsupportedField
        case noConvertibleText
        case mutationFailed
    }

    enum ReplacementOutcome: Equatable {
        case replaced
        case skipped(SkipReason)
    }

    enum ManualCorrectionOutcome: Equatable {
        case corrected(LayoutCorrection)
        case skipped(SkipReason)
    }

    private let safetyPolicy: LayoutSafetyPolicy

    init(safetyPolicy: LayoutSafetyPolicy = .default) {
        self.safetyPolicy = safetyPolicy
    }

    /// Replaces `expectedToken` just before the caret and keeps the separator
    /// after the corrected token, so the user's next key continues naturally.
    func replaceTokenBeforeCaret(
        expectedToken: String,
        trailingText: String,
        replacement: String,
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> ReplacementOutcome {
        guard AXIsProcessTrusted() else {
            return .skipped(.accessibilityDenied)
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return .skipped(.noTargetApplication)
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement: AXUIElement = attributeValue(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            return .skipped(.noFocusedTextField)
        }

        guard LayoutFocusedElementSafety.permits(
            focusedElement,
            in: frontmostApplication,
            safetyPolicy: safetyPolicy
        ) else {
            return .skipped(.excludedApplication)
        }

        guard let selectedTextRange: AXValue = attributeValue(
                  kAXSelectedTextRangeAttribute,
                  from: focusedElement
              ) else {
            return .skipped(.unsupportedField)
        }

        var caretRange = CFRange()
        guard AXValueGetValue(selectedTextRange, .cfRange, &caretRange),
              caretRange.length == 0,
              let replacementRange = LayoutReplacementRange.plan(
                  caretUTF16Offset: caretRange.location,
                  expectedToken: expectedToken,
                  trailingText: trailingText
              ) else {
            return .skipped(.staleTarget)
        }

        let boundedText = textForRange(replacementRange, from: focusedElement)
        let fullText: String? = attributeValue(kAXValueAttribute, from: focusedElement)
        guard boundedText != nil || fullText != nil else {
            return .skipped(.unsupportedField)
        }
        guard LayoutReplacementTextValidation.matches(
            expectedText: expectedToken,
            range: replacementRange,
            boundedText: boundedText,
            fullText: fullText
        ) else {
            return .skipped(.staleTarget)
        }

        // The automatic path types instead of pasting. Everything above proved
        // WHAT to replace and WHERE; from here it is a ~1 ms burst of key
        // events with no selection left in the document and the clipboard never
        // touched. The clipboard protocol could not survive a user who keeps
        // typing — see LayoutKeystrokeReplacementTests.
        guard let plan = LayoutKeystrokeReplacementPlan.plan(
            token: expectedToken,
            trailingText: trailingText,
            replacement: replacement
        ) else {
            return .skipped(.noConvertibleText)
        }

        // Last check before we touch anything: same target, same keystroke.
        guard isStillCurrent(),
              targetIsStillFocused(focusedElement, in: frontmostApplication),
              LayoutKeystrokeSender.send(plan) else {
            return .skipped(.mutationFailed)
        }

        // Verification is a READ, so a user typing on cannot be harmed by it —
        // at worst the check fails and we decline to switch the input source.
        guard await replacementLanded(
            replacement,
            at: replacementRange.location,
            focusedElement: focusedElement,
            frontmostApplication: frontmostApplication
        ) else {
            return .skipped(.mutationFailed)
        }

        return .replaced
    }

    /// Polls the bounded Accessibility range until the replacement shows up.
    /// Read-only, and short: editors commit a key burst in a few milliseconds.
    private func replacementLanded(
        _ replacement: String,
        at location: Int,
        focusedElement: AXUIElement,
        frontmostApplication: NSRunningApplication
    ) async -> Bool {
        let range = NSRange(location: location, length: (replacement as NSString).length)
        for _ in 0 ..< 15 {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
            guard targetIsStillFocused(focusedElement, in: frontmostApplication) else { return false }
            if replacementIsVisible(replacement, in: range, from: focusedElement) {
                return true
            }
        }
        return false
    }

    /// Applies the explicit Double Shift intent to selected text, or the
    /// current line before the caret when there is no selection. This path does
    /// not require a dictionary match: the user deliberately asked for a
    /// physical-layout conversion, but secure/excluded targets are still
    /// refused.
    func correctSelectedTextOrCurrentLine(
        typedIn source: KeyboardLayout,
        mapper: KeyboardLayoutMapper = .russianEnglish,
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> ManualCorrectionOutcome {
        guard AXIsProcessTrusted() else {
            return .skipped(.accessibilityDenied)
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return .skipped(.noTargetApplication)
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement: AXUIElement = attributeValue(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            return .skipped(.noFocusedTextField)
        }

        guard LayoutFocusedElementSafety.permits(
            focusedElement,
            in: frontmostApplication,
            safetyPolicy: safetyPolicy
        ) else {
            return .skipped(.excludedApplication)
        }

        guard let selectedTextRange: AXValue = attributeValue(
                  kAXSelectedTextRangeAttribute,
                  from: focusedElement
              ) else {
            return .skipped(.unsupportedField)
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedTextRange, .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length >= 0 else {
            return .skipped(.unsupportedField)
        }

        guard selectedRange.location <= Int.max - selectedRange.length else {
            return .skipped(.staleTarget)
        }
        let originalCaret = selectedRange.location + selectedRange.length

        let replacementRange: NSRange
        let originalText: String
        if selectedRange.length > 0 {
            guard selectedRange.length <= Self.manualMaximumUTF16Length else {
                return .skipped(.noConvertibleText)
            }
            replacementRange = NSRange(location: selectedRange.location, length: selectedRange.length)
            guard let selectedText = textForRange(
                replacementRange,
                from: focusedElement
            ) ?? attributeValue(kAXSelectedTextAttribute, from: focusedElement) else {
                return .skipped(.noConvertibleText)
            }
            originalText = selectedText
        } else {
            guard let contextRange = LayoutContextWindow.plan(
                beforeCaretUTF16Offset: selectedRange.location,
                maximumLength: Self.manualMaximumUTF16Length
            ), let context = textForRange(contextRange, from: focusedElement) ?? fallbackContext(
                endingAt: selectedRange.location,
                maximumLength: Self.manualMaximumUTF16Length,
                from: focusedElement
            ), let currentLineRange = LayoutCurrentLineRange.plan(
                in: context,
                caretUTF16Offset: (context as NSString).length,
                contextStartsAtDocumentStart: contextRange.location == 0
            ) else {
                return .skipped(.noConvertibleText)
            }
            replacementRange = NSRange(
                location: contextRange.location + currentLineRange.location,
                length: currentLineRange.length
            )
            originalText = (context as NSString).substring(with: currentLineRange)
        }

        let detectedSource: KeyboardLayout
        if selectedRange.length > 0 {
            detectedSource = mapper.sourceLayout(for: originalText, fallback: source)
        } else {
            guard let unambiguousSource = mapper.unambiguousSourceLayout(
                for: originalText,
                fallback: source
            ) else {
                return .skipped(.noConvertibleText)
            }
            detectedSource = unambiguousSource
        }
        guard let replacement = mapper.convertText(originalText, from: detectedSource) else {
            return .skipped(.noConvertibleText)
        }
        let correction = LayoutCorrection(
            replacement: replacement,
            targetLayout: detectedSource.opposite
        )

        let caretAfterReplacement: Int?
        if selectedRange.length == 0 {
            let trailingLength = originalCaret - NSMaxRange(replacementRange)
            caretAfterReplacement = replacementRange.location
                + (replacement as NSString).length
                + trailingLength
        } else {
            caretAfterReplacement = nil
        }
        guard await replaceAndVerify(
            expectedText: originalText,
            replacement: replacement,
            in: replacementRange,
            originalSelection: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            ),
            focusedElement: focusedElement,
            frontmostApplication: frontmostApplication,
            caretAfterReplacement: caretAfterReplacement,
            isStillCurrent: isStillCurrent
        ) else {
            return .skipped(.mutationFailed)
        }

        return .corrected(correction)
    }

    /// Rich editors can acknowledge `AXSelectedText` writes without applying
    /// them. We use one reliable protocol instead: select the precise range,
    /// prove it with Command-C, then replace it with Command-V and verify the
    /// bounded AX range before reporting success.
    private func replaceAndVerify(
        expectedText: String,
        replacement: String,
        in range: NSRange,
        originalSelection: NSRange,
        focusedElement: AXUIElement,
        frontmostApplication: NSRunningApplication,
        caretAfterReplacement: Int?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        NSLog("[LayoutFix] Replacement started")

        // Between selecting the word and pasting over it, the word sits in the
        // user's document as a REAL selection. If they type in that window
        // their character replaces it and our paste lands somewhere else
        // entirely (release review, 2026-08-16). Focus and pid are unchanged by
        // typing, so validity has to mean BOTH "same target" and "no newer key
        // input" — checked at every existing checkpoint, including the one
        // immediately before Cmd-V is posted.
        let stillValid: @MainActor () -> Bool = { [weak self] in
            guard let self, isStillCurrent() else { return false }
            return self.targetIsStillFocused(focusedElement, in: frontmostApplication)
        }

        guard stillValid() else {
            NSLog("[LayoutFix] Replacement aborted: target or input moved on")
            return false
        }

        let succeeded = await LayoutSelectionTransaction.run(
            originalSelection: originalSelection,
            replacementRange: range,
            caretAfterSuccess: caretAfterReplacement,
            targetIsStillFocused: stillValid,
            select: { [weak self] range in
                self?.select(range, in: focusedElement) ?? false
            },
            replace: {
                await TextInsertionService.replaceVerifiedSelectionPreservingPasteboard(
                    expectedText: expectedText,
                    replacement: replacement,
                    targetIsStillFocused: stillValid
                )
            },
            verify: { [weak self] in
                self?.replacementIsVisible(replacement, in: range, from: focusedElement) ?? false
            }
        )
        guard succeeded else {
            NSLog("[LayoutFix] Selection copy/paste was not confirmed and selection was recovered")
            return false
        }
        NSLog("[LayoutFix] Selection paste verified")
        return true
    }

    private func targetIsStillFocused(
        _ focusedElement: AXUIElement,
        in frontmostApplication: NSRunningApplication
    ) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostApplication.processIdentifier,
              let currentFocusedElement: AXUIElement = attributeValue(
                  kAXFocusedUIElementAttribute,
                  from: AXUIElementCreateSystemWide()
              ) else {
            return false
        }
        return CFEqual(currentFocusedElement, focusedElement)
    }

    private func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var selectedRange = CFRange(location: range.location, length: range.length)
        guard let selectedRangeValue = AXValueCreate(.cfRange, &selectedRange) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            selectedRangeValue
        ) == .success
    }

    private func replacementIsVisible(
        _ replacement: String,
        in range: NSRange,
        from element: AXUIElement
    ) -> Bool {
        if textForRange(range, from: element) == replacement {
            return true
        }
        guard let fullText: String = attributeValue(kAXValueAttribute, from: element),
              NSMaxRange(range) <= (fullText as NSString).length else {
            return false
        }
        return (fullText as NSString).substring(with: range) == replacement
    }

    private func attributeValue<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    /// Reads a bounded AX range. Rich text controls frequently expose this
    /// parameterized attribute while declining a full `AXValue`.
    private func textForRange(_ range: NSRange, from element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    /// Native editors that do not support parameterized reads retain the
    /// existing AXValue fallback. It is immediately sliced to the same bounded
    /// range and never persisted or logged.
    private func fallbackContext(
        endingAt caret: Int,
        maximumLength: Int,
        from element: AXUIElement
    ) -> String? {
        guard let fullText: String = attributeValue(kAXValueAttribute, from: element),
              let range = LayoutContextWindow.plan(
                  beforeCaretUTF16Offset: caret,
                  maximumLength: maximumLength
              ), NSMaxRange(range) <= (fullText as NSString).length else {
            return nil
        }
        return (fullText as NSString).substring(with: range)
    }
}
