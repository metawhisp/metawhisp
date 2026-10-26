import Foundation

/// The three steps every cell goes through, in this order (ITER-074 §6.6): a
/// canonical value, an escape so the Sheet reads it as text, and a read-back
/// that must equal the canonical value.
enum SheetCells {
    /// The most a cell holds, in UTF-16 code units — as a page's script
    /// counts text — below the 50,000 characters Google Sheets takes in one
    /// cell, with room for the escape's apostrophe (ITER-076 stage 6, № 177):
    /// a value cut by the Sheet itself could never read back as pasted.
    static let maxCell = 49_000

    /// 1. Canonical value. Control characters (tabs and line breaks included)
    /// and Unicode line and paragraph separators become a space; any run of
    /// whitespace becomes one space; the value is cut to `maxCell`, never
    /// inside a character; the ends are trimmed. An empty result becomes the
    /// request's placeholder (in the request's own language), itself put
    /// through the same rules — so it cannot add a column or a row either —
    /// or "-" when nothing is left of it.
    ///
    /// Only real control characters (category Cc) are replaced — format
    /// characters such as the zero-width joiner inside an emoji stay.
    static func canonical(_ raw: String, empty: String) -> String {
        let value = normalised(raw)
        guard value.isEmpty else { return value }
        let placeholder = normalised(empty)
        return placeholder.isEmpty ? "-" : placeholder
    }

    private static func normalised(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in raw.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.generalCategory == .control
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var value = capped(String(scalars))
        if value.hasSuffix(" ") { value.removeLast() }
        return value
    }

    /// `value` cut to `maxCell` UTF-16 units, at a character's end.
    private static func capped(_ value: String) -> String {
        guard value.utf16.count > maxCell else { return value }
        var kept = 0
        var end = value.startIndex
        for character in value {
            kept += character.utf16.count
            guard kept <= maxCell else { break }
            end = value.index(after: end)
        }
        return String(value[..<end])
    }

    /// 2. Escape for the paste. Every value gets one apostrophe in front: the
    /// Sheet reads a leading apostrophe as "this is text" and does not show
    /// it. Without it the live probe of 2026-10-06 saw Google Sheets read
    /// `1.50` as a number shown `1.5`, a leading double quote as quoting, and
    /// `=` as a formula — none of which reads back as pasted (ITER-076 stage
    /// 6). Numbers therefore arrive as text, which a list does not mind.
    static func escaped(_ canonical: String) -> String {
        "'" + canonical
    }

    /// The text of one paste: every cell canonical first, escaped second,
    /// tabs between cells, line breaks between rows. A canonical value holds
    /// no tab and no line break, so no cell can add a column or a row.
    static func pasteText(rows: [[String]], empty: String) -> String {
        rows.map { row in row.map { escaped(canonical($0, empty: empty)) }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// 3. Read-back: the same number of rows and cells, and every displayed
    /// cell equal to its canonical value. Whether a cell holds a formula is
    /// checked by the read-back itself, not here.
    static func readBackMatches(expected: [[String]], displayed: [[String]], empty: String) -> Bool {
        guard expected.count == displayed.count else { return false }
        for (row, shown) in zip(expected, displayed) {
            guard row.count == shown.count else { return false }
            for (cell, seen) in zip(row, shown) where canonical(cell, empty: empty) != seen {
                return false
            }
        }
        return true
    }
}
