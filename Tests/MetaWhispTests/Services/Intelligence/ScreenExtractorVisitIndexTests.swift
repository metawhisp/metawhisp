import XCTest
@testable import MetaWhisp

/// ITER-064A.1 — the hourly batch extractor asks the model for a `visitIndex`
/// per memory/task and then subscripts the visit array with it.
///
/// The old guard was `visitIndex < trimmed.count`. A model returning `-1`
/// (or any negative index) satisfies that comparison, and `trimmed[-1]` is a
/// fatal trap in Swift — the app terminates, it does not throw.
///
/// These cases pin the full range check so a malformed model response can only
/// drop one item, never kill the process.
final class ScreenExtractorVisitIndexTests: XCTestCase {

    func testNegativeIndexIsRejected() {
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(-1, count: 3),
                       "-1 passed the old `< count` check and then crashed the subscript")
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(Int.min, count: 3))
    }

    func testIndexAtOrBeyondCountIsRejected() {
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(3, count: 3))
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(99, count: 3))
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(Int.max, count: 3))
    }

    func testInRangeIndexIsAccepted() {
        XCTAssertTrue(ScreenExtractor.isValidVisitIndex(0, count: 3))
        XCTAssertTrue(ScreenExtractor.isValidVisitIndex(2, count: 3))
    }

    /// An empty visit list must accept nothing at all — including index 0.
    func testEmptyVisitListAcceptsNothing() {
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(0, count: 0))
        XCTAssertFalse(ScreenExtractor.isValidVisitIndex(-1, count: 0))
    }
}
