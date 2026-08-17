import AppKit
import Carbon
import Foundation

/// How many backspaces to send and what to type back, to fix a word in place.
///
/// This exists because the clipboard protocol could not survive continuous
/// typing. Selecting the word, proving it with ⌘C and replacing it with ⌘V
/// leaves a live selection in the user's document for ~180 ms; the next
/// character of the phrase they are typing lands inside that window. Deleting
/// and re-typing takes about a millisecond and leaves no selection and no
/// clipboard trace at all.
///
/// The caret sits AFTER the separator that triggered the correction, so the
/// separator is deleted with the word and typed back with the replacement.
struct LayoutKeystrokeReplacementPlan: Equatable {

    /// Ceiling on one burst. The word buffer caps tokens at 24 characters, so
    /// anything past this means the plan was built from something we never
    /// validated — and a runaway burst would eat text nobody checked.
    static let maximumBackspaces = 32

    let backspaces: Int
    let insertion: String

    static func plan(
        token: String,
        trailingText: String,
        replacement: String
    ) -> LayoutKeystrokeReplacementPlan? {
        guard !token.isEmpty, !replacement.isEmpty else { return nil }

        // Backspace deletes what the editor considers one character. A
        // combining sequence may count as one or several depending on the
        // editor, so its on-screen length is not knowable — refuse rather than
        // delete the wrong amount. Refusing only skips the correction.
        guard token.allSatisfy({ $0.unicodeScalars.count == 1 }),
              trailingText.allSatisfy({ $0.unicodeScalars.count == 1 }) else {
            return nil
        }

        let backspaces = token.count + trailingText.count
        guard backspaces <= maximumBackspaces else { return nil }

        return LayoutKeystrokeReplacementPlan(
            backspaces: backspaces,
            insertion: replacement + trailingText
        )
    }
}

/// Posts a plan as synthetic key events. Separated from the plan so the
/// arithmetic is unit-tested without touching the window server.
enum LayoutKeystrokeSender {

    /// Deletes `backspaces` characters, then types `insertion`.
    ///
    /// Events go out back-to-back with no `await` between them: the whole point
    /// is that nothing of the user's can interleave. Characters are sent one at
    /// a time — some editors ignore a multi-character unicode payload.
    @MainActor
    @discardableResult
    static func send(_ plan: LayoutKeystrokeReplacementPlan) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for _ in 0 ..< plan.backspaces {
            guard postKey(CGKeyCode(kVK_Delete), source: source) else { return false }
        }

        for character in plan.insertion {
            guard postCharacter(character, source: source) else { return false }
        }
        return true
    }

    private static func postKey(_ virtualKey: CGKeyCode, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postCharacter(_ character: Character, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        var utf16 = Array(String(character).utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
