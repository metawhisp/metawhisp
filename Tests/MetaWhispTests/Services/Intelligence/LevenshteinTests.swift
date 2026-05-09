import XCTest
@testable import MetaWhisp

/// Pure-function tests for `Levenshtein.distance(_:_:)`.
///
/// Wagner-Fischer minimum edit distance. Used by `ProjectClusterDecision`
/// to merge typo-near-duplicates: `Island Expand` vs `Island Expend`
/// (1 char) at canonical level. Standard textbook edit-distance.
final class LevenshteinTests: XCTestCase {

    func test_identicalStringsDistanceZero() {
        XCTAssertEqual(Levenshtein.distance("chatapp", "chatapp"), 0)
    }

    func test_singleSubstitution() {
        XCTAssertEqual(Levenshtein.distance("expend", "expand"), 1)
    }

    func test_singleInsertion() {
        XCTAssertEqual(Levenshtein.distance("cat", "cats"), 1)
    }

    func test_singleDeletion() {
        XCTAssertEqual(Levenshtein.distance("cats", "cat"), 1)
    }

    /// Two-char diff — `Island Expend` vs `Island Expand` at the relevant
    /// position has 1; bigger words like `kitten` → `sitting` = 3.
    func test_threeOperations_kitten_sitting() {
        XCTAssertEqual(Levenshtein.distance("kitten", "sitting"), 3)
    }

    /// Empty strings — distance equals the length of the non-empty one.
    func test_emptyVsString() {
        XCTAssertEqual(Levenshtein.distance("", "hello"), 5)
        XCTAssertEqual(Levenshtein.distance("hello", ""), 5)
        XCTAssertEqual(Levenshtein.distance("", ""), 0)
    }
}
