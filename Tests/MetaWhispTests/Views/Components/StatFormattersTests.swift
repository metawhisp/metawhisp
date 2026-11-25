import XCTest
@testable import MetaWhisp

/// ITER-087 — the Dashboard's counts fit their tiles. `fmtNum` knew only thousands, so 2,352,400 words showed as
/// "2352.4k" and the tile cut it to "2352…". A count is shown as it is up to 999, in thousands with one decimal up to
/// just under a million, and in millions with two decimals from there.
final class StatFormattersTests: XCTestCase {
    func testACountIsShownAsItIsUpTo999() {
        XCTAssertEqual(StatFormatters.count(0), "0")
        XCTAssertEqual(StatFormatters.count(426), "426")
        XCTAssertEqual(StatFormatters.count(999), "999")
    }

    func testThousandsCarryOneDecimal() {
        XCTAssertEqual(StatFormatters.count(1_000), "1.0k")
        XCTAssertEqual(StatFormatters.count(11_400), "11.4k")
        XCTAssertEqual(StatFormatters.count(999_949), "999.9k")
    }

    func testMillionsCarryTwoDecimalsAndNeverShowAThousandThousands() {
        XCTAssertEqual(StatFormatters.count(999_950), "1.00M", "not 1000.0k")
        XCTAssertEqual(StatFormatters.count(2_352_400), "2.35M")
        XCTAssertEqual(StatFormatters.count(19_295_000), "19.30M")
    }
}
