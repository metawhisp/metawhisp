import XCTest
@testable import MetaWhisp

/// Every cell goes through the same three steps before and after the paste
/// (ITER-074 §6.6): a canonical value, an escape so the Sheet reads it as
/// text, and a read-back that must equal the canonical value.
final class SheetCellsTests: XCTestCase {

    // MARK: - 1. Canonical value

    func testLineBreaksTabsAndControlCharactersBecomeSpaces() {
        XCTAssertEqual(SheetCells.canonical("a\tb\nc\r\nd\u{0007}e", empty: "-"), "a b c d e")
    }

    func testUnicodeLineAndParagraphSeparatorsBecomeSpaces() {
        XCTAssertEqual(SheetCells.canonical("a\u{2028}b\u{2029}c", empty: "-"), "a b c")
    }

    func testRunsOfSpacesCollapseAndTheEndsAreTrimmed() {
        XCTAssertEqual(SheetCells.canonical("   a    b   ", empty: "-"), "a b")
        XCTAssertEqual(SheetCells.canonical("a\u{00A0}\u{00A0}b", empty: "-"), "a b",
                       "a non-breaking space is a space too")
    }

    /// Format characters are not control characters: the joiner inside a
    /// family emoji must survive, or the cell shows three separate faces.
    func testAJoinedEmojiSurvives() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(SheetCells.canonical(family, empty: "-"), family)
    }

    func testAnEmptyValueBecomesTheRequestsPlaceholder() {
        XCTAssertEqual(SheetCells.canonical("", empty: "n/a"), "n/a")
        XCTAssertEqual(SheetCells.canonical(" \t\n ", empty: "n/a"), "n/a")
    }

    /// The placeholder obeys the same rules as any cell, so it cannot add a
    /// column or a row either; an empty placeholder falls back to "-".
    func testThePlaceholderIsCanonicalToo() {
        XCTAssertEqual(SheetCells.canonical("", empty: "a\tb\nc"), "a b c")
        XCTAssertEqual(SheetCells.canonical("", empty: " \n "), "-")
        XCTAssertEqual(SheetCells.pasteText(rows: [[""]], empty: "a\tb\nc"), "'a b c")
    }

    /// ITER-076 stage 6 (№ 177): a cell holds at most `maxCell` UTF-16 units — what a page's script counts — below
    /// the 50,000 characters Google Sheets takes in one, with room for the escape's apostrophe. A longer value is
    /// cut there, never inside a character, and its end trimmed; the read-back expects the value so cut.
    func testACellIsCappedBelowTheSheetsLimit() {
        XCTAssertEqual(SheetCells.maxCell, 49_000)
        XCTAssertEqual(SheetCells.canonical(String(repeating: "a", count: 60_000), empty: "-"),
                       String(repeating: "a", count: 49_000))
        let straddling = String(repeating: "a", count: 48_999) + "\u{1F600}b"
        XCTAssertEqual(SheetCells.canonical(straddling, empty: "-"), String(repeating: "a", count: 48_999),
                       "an emoji that would cross the cap is left out whole")
        let spaced = String(repeating: "a", count: 48_999) + " bcd"
        XCTAssertEqual(SheetCells.canonical(spaced, empty: "-"), String(repeating: "a", count: 48_999),
                       "a cut that ends in a space is trimmed")
        XCTAssertLessThan(SheetCells.escaped(SheetCells.canonical(String(repeating: "=", count: 60_000), empty: "-"))
            .utf16.count, 50_000)
        let long = String(repeating: "b", count: 50_500)
        XCTAssertTrue(SheetCells.readBackMatches(expected: [[long]], displayed: [[String(repeating: "b", count: 49_000)]],
                                                 empty: "-"))
    }

    // MARK: - 2. Escape for the paste

    /// A cell that starts like a formula must arrive as text: the Sheet
    /// treats a leading apostrophe as "this is text" and hides it.
    func testFormulaLikeStartsGetAnApostrophe() {
        for value in ["=IMPORTXML(\"https://a.test\")", "+1", "-5%", "@mention", "'quoted"] {
            XCTAssertEqual(SheetCells.escaped(value), "'" + value, value)
        }
    }

    /// ITER-076 stage 6, the live probe of 2026-10-06: without the apostrophe Google Sheets shows `1.50` as `1.5`
    /// and reads a leading double quote as quoting — `"Quoted" start` came back `Quoted start` — so the read-back
    /// could never match. With it, every value came back exactly as pasted: every cell gets one.
    func testEveryValueGetsAnApostropheSoTheSheetKeepsItAsText() {
        for value in ["Site One", "5%", "1.50", "2026-10-06", "\"Quoted\" start", "a=b", "https://a.test/-x", "n/a"] {
            XCTAssertEqual(SheetCells.escaped(value), "'" + value, value)
        }
    }

    // MARK: - The paste text

    /// Canonical first, escape second, then tabs between cells and line
    /// breaks between rows — a cell can never add a column or a row.
    func testRowsBecomeTabSeparatedTextThatCannotGrowColumnsOrRows() {
        let text = SheetCells.pasteText(rows: [["Site\tOne", "=1+1"], ["", "line\nbreak"]], empty: "n/a")
        XCTAssertEqual(text, "'Site One\t'=1+1\n'n/a\t'line break")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.components(separatedBy: "\t").count == 2 })
    }

    func testTheOrderIsCanonicalThenEscape() {
        // Only after trimming does the value start with "=".
        XCTAssertEqual(SheetCells.pasteText(rows: [["   =SUM(A1)"]], empty: "n/a"), "'=SUM(A1)")
    }

    // MARK: - 3. Read-back

    func testAReadBackOfTheCanonicalValuesMatches() {
        let rows = [["Site\tOne", "=1+1"], ["", "-5%"]]
        let displayed = [["Site One", "=1+1"], ["n/a", "-5%"]]
        XCTAssertTrue(SheetCells.readBackMatches(expected: rows, displayed: displayed, empty: "n/a"))
    }

    func testAnyDifferenceIsAMismatch() {
        let rows = [["a", "b"]]
        XCTAssertFalse(SheetCells.readBackMatches(expected: rows, displayed: [["a", "c"]], empty: "n/a"))
        XCTAssertFalse(SheetCells.readBackMatches(expected: rows, displayed: [["a"]], empty: "n/a"))
        XCTAssertFalse(SheetCells.readBackMatches(expected: rows, displayed: [["a", "b"], ["x", "y"]], empty: "n/a"))
        XCTAssertFalse(SheetCells.readBackMatches(expected: rows, displayed: [], empty: "n/a"))
    }
}
