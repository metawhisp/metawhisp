import XCTest
@testable import MetaWhisp

/// The rows an errand collects (ITER-074 §4, §6.6, US-9): canonical cells, a
/// source address on every row, one row per site.
final class ScratchpadTests: XCTestCase {

    private func pad() -> Scratchpad { Scratchpad(columns: ["Name", "URL", "What they do"], emptyCell: "n/a") }

    func testARowKeepsItsSourceAndCanonicalCells() {
        var rows = pad()
        XCTAssertNil(rows.add(cells: ["  Site\tOne ", "https://site-1.test/", ""],
                              source: URL(string: "https://site-1.test/")!))
        XCTAssertEqual(rows.rows, [Scratchpad.Row(cells: ["Site One", "https://site-1.test/", "n/a"],
                                                  source: URL(string: "https://site-1.test/")!)])
    }

    /// A second row from a site already collected is skipped (§4 step 9) —
    /// "www." or not.
    func testASecondRowFromTheSameSiteIsSkipped() {
        var rows = pad()
        XCTAssertNil(rows.add(cells: ["One", "u", "d"], source: URL(string: "https://site-1.test/")!))
        XCTAssertEqual(rows.add(cells: ["One again", "u", "d"], source: URL(string: "https://www.Site-1.test/about")!),
                       .sameSite)
        XCTAssertNil(rows.add(cells: ["Two", "u", "d"], source: URL(string: "https://site-2.test/")!))
        XCTAssertEqual(rows.rows.count, 2)
    }

    /// A row that does not fit the columns cannot be pasted as one row.
    func testARowMustFitTheColumns() {
        var rows = pad()
        XCTAssertEqual(rows.add(cells: ["Only a name"], source: URL(string: "https://site-1.test/")!), .wrongCellCount)
        XCTAssertTrue(rows.rows.isEmpty)
    }

    /// Every row can be checked (US-9): its source is a web address.
    func testASourceMustBeAWebAddress() {
        var rows = pad()
        XCTAssertEqual(rows.add(cells: ["x", "y", "z"], source: URL(string: "file:///etc/hosts")!), .notAWebAddress)
        XCTAssertTrue(rows.rows.isEmpty)
    }
}
