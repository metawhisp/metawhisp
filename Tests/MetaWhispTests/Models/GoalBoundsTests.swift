import XCTest
@testable import MetaWhisp

/// AUD-032 — pure-function tests for `GoalBounds`. A Rating/scale goal feeds a
/// `Slider(in: lo...hi)`. Swift's `lo...hi` traps the process when `lo > hi` or
/// either bound is non-finite, so the range must never be built directly from
/// raw goal bounds. These tests pin the safe ordering/clamping behaviour.
final class GoalBoundsTests: XCTestCase {

    // MARK: - safeScaleRange (render side — must never crash)

    func test_safeScaleRange_normalBounds_passThrough() {
        XCTAssertEqual(GoalBounds.safeScaleRange(min: 1, max: 10), 1...10)
    }

    func test_safeScaleRange_invertedBounds_areOrdered() {
        // The crash scenario: min 10, max 1. Must order, not trap.
        XCTAssertEqual(GoalBounds.safeScaleRange(min: 10, max: 1), 1...10)
    }

    func test_safeScaleRange_nilBounds_defaultTo1to10() {
        XCTAssertEqual(GoalBounds.safeScaleRange(min: nil, max: nil), 1...10)
    }

    func test_safeScaleRange_equalBounds_returnNonEmptyRange() {
        // Slider needs lo < hi; equal bounds must widen by one.
        XCTAssertEqual(GoalBounds.safeScaleRange(min: 5, max: 5), 5...6)
    }

    func test_safeScaleRange_nonFiniteBounds_replaced() {
        XCTAssertEqual(GoalBounds.safeScaleRange(min: .nan, max: 10), 1...10)
        XCTAssertEqual(GoalBounds.safeScaleRange(min: 1, max: .infinity), 1...10)
        // Both non-finite → full default.
        XCTAssertEqual(GoalBounds.safeScaleRange(min: .nan, max: .nan), 1...10)
    }

    // MARK: - normalizedBounds (save side — owner layer)

    func test_normalizedBounds_inverted_swapsToAscending() {
        let r = GoalBounds.normalizedBounds(min: 10, max: 1)
        XCTAssertEqual(r.min, 1)
        XCTAssertEqual(r.max, 10)
    }

    func test_normalizedBounds_equal_bumpsMax() {
        let r = GoalBounds.normalizedBounds(min: 5, max: 5)
        XCTAssertEqual(r.min, 5)
        XCTAssertEqual(r.max, 6)
    }

    func test_normalizedBounds_nilLeftUntouched() {
        // Non-scale goals carry no bounds — leave them alone.
        let r = GoalBounds.normalizedBounds(min: nil, max: 10)
        XCTAssertNil(r.min)
        XCTAssertEqual(r.max, 10)
    }

    func test_normalizedBounds_nonFinite_replacedAndOrdered() {
        let r = GoalBounds.normalizedBounds(min: .nan, max: 8)
        XCTAssertEqual(r.min, 1)   // NaN → default 1
        XCTAssertEqual(r.max, 8)
    }
}
