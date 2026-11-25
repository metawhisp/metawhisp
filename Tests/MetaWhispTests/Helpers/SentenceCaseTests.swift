import XCTest
@testable import MetaWhisp

/// ITER-087 — chips and tabs read in sentence case. Labels that come from an enum's raw value ("THIS WEEK") or from
/// data ("microphone") are shown through `sentenceCased`; the values themselves stay as they are, since code keys on
/// them.
final class SentenceCaseTests: XCTestCase {
    func testCapsBecomeSentenceCase() {
        XCTAssertEqual("THIS WEEK".sentenceCased, "This week")
        XCTAssertEqual("LIVE".sentenceCased, "Live")
    }

    func testLowercaseDataGetsItsFirstLetterRaised() {
        XCTAssertEqual("microphone".sentenceCased, "Microphone")
        XCTAssertEqual("work".sentenceCased, "Work")
    }

    func testAnEmptyLabelStaysEmpty() {
        XCTAssertEqual("".sentenceCased, "")
    }
}
