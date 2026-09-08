import Foundation

/// What the user is told when translating a selection fails.
///
/// The failure path called `SoundService.playError()` — whose body is empty —
/// hid the overlay and returned. `SelectionTranslator` sets no banner and
/// posts no card, so an expired licence, a refused prompt or a dead network
/// were all indistinguishable from the hotkey not having registered at all
/// (audit, 2026-09-06, P1).
///
/// Pure, and it never quotes the selection: this appears on screen, and the
/// words being translated are the user's own.
enum SelectionTranslateFeedback {

    static func wording(for error: Error) -> (title: String, body: String) {
        let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = reason.isEmpty
            ? "The app did not say why. Try again, and check Settings if it keeps failing."
            : reason
        return ("Translation failed",
                "The selection was left as it is and your clipboard is back the way it was. \(tail)")
    }
}
