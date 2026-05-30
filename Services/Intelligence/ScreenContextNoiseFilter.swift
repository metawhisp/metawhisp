import Foundation

/// ITER-042 (cheap hypothesis) — drop the app's OWN window OCR from the chat's
/// screen-context block.
///
/// Why: the app's window shows the assistant's own previous answers + task /
/// people lists. When the screen-context capture OCRs that window, the text
/// re-enters the next prompt as a `<recent_screen_activity>` "fact on screen",
/// forming a feedback loop — the model cites its own prior output (and the
/// user's own name leaks back in as if a third party). Verified in the store:
/// the screenshot's people had ~8 sightings inside `MetaWhisp`'s own OCR.
///
/// Scope: filter ONLY the app's own window. Real comms, browsers, IDEs, Finder
/// etc. stay — they are genuine activity signal for non-people questions. The
/// broader workspace tagging / AI-tools down-ranking is ITER-042.1+, not here.
enum ScreenContextNoiseFilter {

    /// True when an OCR row came from the app's own window (case/whitespace
    /// insensitive). Empty inputs never match — a missing bundle name must not
    /// accidentally filter rows with an empty appName.
    static func isOwnWindow(appName: String, ownAppName: String) -> Bool {
        let a = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = ownAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !own.isEmpty else { return false }
        return a.caseInsensitiveCompare(own) == .orderedSame
    }
}
