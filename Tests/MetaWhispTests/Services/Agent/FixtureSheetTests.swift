import XCTest
@testable import MetaWhisp

/// The fixture sheet stands in for a new Google Sheet at level 3 (ITER-074
/// §12.1). It must behave like one where it matters: a leading apostrophe
/// makes a cell text and is not shown, and "=" makes a formula.
final class FixtureSheetTests: XCTestCase {

    @MainActor
    func testAnEscapedPasteReadsBackAsItsCanonicalValues() async throws {
        let sheet = FixtureSheet()
        var receipt: URL?
        let address = try await sheet.create(title: "Competitors", made: { receipt = $0 })
        XCTAssertEqual(sheet.title, "Competitors")
        XCTAssertEqual(receipt, address, "the receipt names the Sheet made")
        let rows = [["=1+1", "-5", "Site One"], ["'quoted", "@home", " plain "]]
        try await sheet.paste(SheetCells.pasteText(rows: rows, empty: "n/a"), into: address)
        let read = try await sheet.readBack(address)
        XCTAssertFalse(read.holdsFormula)
        XCTAssertTrue(SheetCells.readBackMatches(expected: rows, displayed: read.cells, empty: "n/a"))
    }

    /// Without the escape a cell starting with "=" is a formula — which is
    /// exactly what the read-back must catch.
    @MainActor
    func testAnUnescapedFormulaIsCaught() async throws {
        let sheet = FixtureSheet()
        let address = try await sheet.create(title: "Test", made: { _ in })
        try await sheet.paste("=1+1\tplain", into: address)
        let read = try await sheet.readBack(address)
        XCTAssertTrue(read.holdsFormula)
        XCTAssertFalse(SheetCells.readBackMatches(expected: [["=1+1", "plain"]], displayed: read.cells, empty: "n/a"))
    }

    @MainActor
    func testASheetThatWasNotCreatedCannotBeUsed() async throws {
        let sheet = FixtureSheet()
        do {
            try await sheet.paste("x", into: URL(string: "https://sheets.test/other")!)
            XCTFail("pasted into a sheet it never created")
        } catch {}
    }
}
