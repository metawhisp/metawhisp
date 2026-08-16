import XCTest
@testable import MetaWhisp

final class LayoutDoubleShiftDetectorTests: XCTestCase {
    func test_detectsTwoCleanShiftReleasesInsideTheThreshold() {
        var detector = LayoutDoubleShiftDetector()

        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 100))
        detector.recordShiftPress()
        XCTAssertTrue(detector.recordShiftRelease(atNanoseconds: 300_000_100))
    }

    func test_rejectsSlowOrInterruptedDoubleShift() {
        var detector = LayoutDoubleShiftDetector()

        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 100))
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 500_000_101))

        detector.interrupt()
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 600_000_000))
        detector.interrupt()
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 700_000_000))
    }

    func test_resetsAfterFiringSoOneTripletDoesNotTriggerTwice() {
        var detector = LayoutDoubleShiftDetector()

        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 100))
        detector.recordShiftPress()
        XCTAssertTrue(detector.recordShiftRelease(atNanoseconds: 200_000_000))
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 300_000_000))
    }

    func test_shiftUsedForUppercaseCannotBecomeFirstTap() {
        var detector = LayoutDoubleShiftDetector()

        detector.recordShiftPress()
        detector.interrupt(ignoringNextShiftRelease: true)
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 100))
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 200_000_000))
        detector.recordShiftPress()
        XCTAssertTrue(detector.recordShiftRelease(atNanoseconds: 300_000_000))
    }

    func test_releaseWithoutACleanPressCannotCompleteTheGesture() {
        var detector = LayoutDoubleShiftDetector()

        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 100))
        detector.recordShiftPress()
        XCTAssertFalse(detector.recordShiftRelease(atNanoseconds: 200_000_000))
        detector.recordShiftPress()
        XCTAssertTrue(detector.recordShiftRelease(atNanoseconds: 300_000_000))
    }
}
