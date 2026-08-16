import XCTest
@testable import MetaWhisp

final class FocusedTextGatewayTests: XCTestCase {
    func test_contextWindowBoundsReadsOnlyTheImmediateTextBeforeCaret() {
        XCTAssertEqual(
            LayoutContextWindow.plan(beforeCaretUTF16Offset: 260, maximumLength: 128),
            NSRange(location: 132, length: 128)
        )
        XCTAssertEqual(
            LayoutContextWindow.plan(beforeCaretUTF16Offset: 12, maximumLength: 128),
            NSRange(location: 0, length: 12)
        )
    }

    func test_contextWindowBoundsRejectsInvalidCaretOrLimit() {
        XCTAssertNil(LayoutContextWindow.plan(beforeCaretUTF16Offset: -1, maximumLength: 128))
        XCTAssertNil(LayoutContextWindow.plan(beforeCaretUTF16Offset: 12, maximumLength: 0))
    }

    func test_replacementRangeSelectsOnlyTokenBeforeTypedSeparator() {
        let range = LayoutReplacementRange.plan(
            caretUTF16Offset: "ghbdtn ".utf16.count,
            expectedToken: "ghbdtn",
            trailingText: " "
        )

        XCTAssertEqual(range, NSRange(location: 0, length: 6))
    }

    func test_replacementRangeRejectsCaretBeforeCompleteToken() {
        XCTAssertNil(
            LayoutReplacementRange.plan(
                caretUTF16Offset: 3,
                expectedToken: "ghbdtn",
                trailingText: " "
            )
        )
    }

    func test_replacementRangeRejectsCaretBeforeSeparatorIsCommitted() {
        XCTAssertNil(
            LayoutReplacementRange.plan(
                caretUTF16Offset: "ghbdtn".utf16.count,
                expectedToken: "ghbdtn",
                trailingText: " "
            )
        )
    }

    func test_replacementTextValidationUsesBoundedRichEditorRangeWithoutFullAXValue() {
        XCTAssertTrue(
            LayoutReplacementTextValidation.matches(
                expectedText: "ghbdtn",
                range: NSRange(location: 12, length: 6),
                boundedText: "ghbdtn",
                fullText: nil
            )
        )
    }

    func test_replacementTextValidationFallsBackToFullValueButRejectsStaleText() {
        XCTAssertTrue(
            LayoutReplacementTextValidation.matches(
                expectedText: "ghbdtn",
                range: NSRange(location: 6, length: 6),
                boundedText: nil,
                fullText: "hello ghbdtn "
            )
        )
        XCTAssertFalse(
            LayoutReplacementTextValidation.matches(
                expectedText: "ghbdtn",
                range: NSRange(location: 6, length: 6),
                boundedText: "changed",
                fullText: "hello changed "
            )
        )
    }

    func test_safetyPolicyRejectsSecureFieldBeforeExaminingText() {
        XCTAssertFalse(
            LayoutSafetyPolicy.default.permits(
                bundleIdentifier: "com.apple.TextEdit",
                isSecureField: true
            )
        )
    }

    func test_safetyPolicyRejectsTerminalAndRemoteDesktop() {
        XCTAssertFalse(
            LayoutSafetyPolicy.default.permits(
                bundleIdentifier: "com.apple.Terminal",
                isSecureField: false
            )
        )
        XCTAssertFalse(
            LayoutSafetyPolicy.default.permits(
                bundleIdentifier: "com.googlecode.iterm2",
                isSecureField: false
            )
        )
        XCTAssertFalse(
            LayoutSafetyPolicy.default.permits(
                bundleIdentifier: "com.microsoft.rdc.macos",
                isSecureField: false
            )
        )
    }

    func test_captureSafetyRejectsSecureProtectedExcludedAndOwnAppInput() {
        let ordinaryBundle = "com.apple.TextEdit"
        let ownBundle = "com.metawhisp.app"

        XCTAssertFalse(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: ordinaryBundle,
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 42,
                isSecureInputEnabled: true,
                isSecureField: false
            )
        )
        XCTAssertFalse(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: ordinaryBundle,
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 42,
                isSecureInputEnabled: false,
                isSecureField: true
            )
        )
        XCTAssertFalse(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: "com.apple.Terminal",
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 42,
                isSecureInputEnabled: false,
                isSecureField: false
            )
        )
        XCTAssertFalse(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: ownBundle,
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 42,
                isSecureInputEnabled: false,
                isSecureField: false
            )
        )
        XCTAssertTrue(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: ordinaryBundle,
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 42,
                isSecureInputEnabled: false,
                isSecureField: false
            )
        )
        XCTAssertFalse(
            LayoutCaptureSafetyDecision.permits(
                bundleIdentifier: ordinaryBundle,
                ownBundleIdentifier: ownBundle,
                frontmostProcessIdentifier: 42,
                focusedProcessIdentifier: 99,
                isSecureInputEnabled: false,
                isSecureField: false
            )
        )
    }

    func test_safetyPolicyAllowsOrdinaryTextEditor() {
        XCTAssertTrue(
            LayoutSafetyPolicy.default.permits(
                bundleIdentifier: "com.apple.TextEdit",
                isSecureField: false
            )
        )
    }

    func test_currentLineRangeSelectsTheWholeSentenceBeforeCaret() {
        let text = "keep this\nghbdtn rfr ltkf!"
        let range = LayoutCurrentLineRange.plan(
            in: text,
            caretUTF16Offset: text.utf16.count
        )

        XCTAssertEqual(
            range,
            NSRange(location: "keep this\n".utf16.count, length: "ghbdtn rfr ltkf!".utf16.count)
        )
    }

    func test_currentLineRangeIncludesTrailingSpacesButRejectsAnEmptyLine() {
        let text = "ghbdtn rfr  "
        XCTAssertEqual(
            LayoutCurrentLineRange.plan(in: text, caretUTF16Offset: text.utf16.count),
            NSRange(location: 0, length: text.utf16.count)
        )
        XCTAssertNil(LayoutCurrentLineRange.plan(in: "hello\n", caretUTF16Offset: 6))
    }

    func test_currentLineRangeRejectsATruncatedLineButAcceptsOneAfterCapturedNewline() {
        XCTAssertNil(
            LayoutCurrentLineRange.plan(
                in: "ghbdtn rfr ltkf",
                caretUTF16Offset: "ghbdtn rfr ltkf".utf16.count,
                contextStartsAtDocumentStart: false
            )
        )
        XCTAssertEqual(
            LayoutCurrentLineRange.plan(
                in: "older\nghbdtn rfr ltkf",
                caretUTF16Offset: "older\nghbdtn rfr ltkf".utf16.count,
                contextStartsAtDocumentStart: false
            ),
            NSRange(location: "older\n".utf16.count, length: "ghbdtn rfr ltkf".utf16.count)
        )
    }

    func test_selectionTransactionRestoresOriginalSelectionWhenReplacementFails() async {
        let original = NSRange(location: 12, length: 0)
        let replacement = NSRange(location: 0, length: 12)
        var selectedRanges: [NSRange] = []

        let succeeded = await LayoutSelectionTransaction.run(
            originalSelection: original,
            replacementRange: replacement,
            caretAfterSuccess: nil,
            targetIsStillFocused: { true },
            select: { range in
                selectedRanges.append(range)
                return true
            },
            replace: { false },
            verify: { false }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(selectedRanges, [replacement, original])
    }

    func test_selectionTransactionDoesNotTouchTargetAfterFocusChanges() async {
        let original = NSRange(location: 12, length: 0)
        let replacement = NSRange(location: 0, length: 12)
        var focused = true
        var selectedRanges: [NSRange] = []

        let succeeded = await LayoutSelectionTransaction.run(
            originalSelection: original,
            replacementRange: replacement,
            caretAfterSuccess: nil,
            targetIsStillFocused: { focused },
            select: { range in
                selectedRanges.append(range)
                return true
            },
            replace: {
                focused = false
                return false
            },
            verify: { false }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(selectedRanges, [replacement])
    }
}
