import Foundation

/// Normalizes a window title by stripping cosmetic noise (spinners, timers,
/// terminal dimensions, unread counts) so that rapid UI updates don't trigger
/// repeated re-analysis. Apps like Toggl, VS Code, browser tabs with unread
/// counters mutate their window title 60+ times per second; without
/// normalization the proactive surface fires endlessly.
///
/// Pure function. Ported verbatim from reference desktop client's
/// `ContextDetection.normalizeWindowTitle` (ITER-027.1, 2026-05-09).
enum WindowTitleNormalizer {
    /// Returns a canonical form of the title for equality comparison only —
    /// the original is preserved by the caller for display.
    static func normalize(_ title: String?) -> String? {
        guard var result = title else { return nil }

        // Strip Braille spinner block (U+2800-U+28FF) entirely.
        result = result.unicodeScalars
            .filter { !($0.value >= 0x2800 && $0.value <= 0x28FF) }
            .reduce(into: "") { $0.append(String($1)) }

        // Strip common spinner / progress glyphs (arrows, dot rotations).
        let spinnerChars: Set<Character> = [
            "✳", "↻", "◐", "◑", "◒", "◓",
            "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
            "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
            "◴", "◷", "◶", "◵", "◰", "◳", "◲", "◱",
            "▖", "▘", "▝", "▗",
            "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"
        ]
        result = String(result.filter { !spinnerChars.contains($0) })

        // Strip timer patterns: 12:34, 1:23:45, 00:05:23.
        result = result.replacingOccurrences(
            of: #"\b\d{1,2}:\d{2}(:\d{2})?\b"#,
            with: "",
            options: .regularExpression
        )

        // Strip terminal dimensions: 80×24, 60x88.
        result = result.replacingOccurrences(
            of: #"\b\d+[×x]\d+\b"#,
            with: "",
            options: .regularExpression
        )

        // Strip notification / unread counts: (2), (16), [3].
        result = result.replacingOccurrences(
            of: #"\(\d+\)"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[\d+\]"#, with: "", options: .regularExpression
        )

        // Collapse whitespace runs to single space, trim ends.
        result = result.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return result.isEmpty ? nil : result
    }

    /// Returns `true` iff either the app changed OR the *normalized* window
    /// title changed. Used by the proactive surface trigger to decide whether
    /// to enqueue a fresh analysis. Without normalization, every spinner
    /// frame would re-trigger.
    static func didContextChange(
        fromApp: String?,
        fromTitle: String?,
        toApp: String?,
        toTitle: String?
    ) -> Bool {
        if fromApp != toApp { return true }
        let nFrom = normalize(fromTitle)
        let nTo = normalize(toTitle)
        return nFrom != nTo
    }
}
