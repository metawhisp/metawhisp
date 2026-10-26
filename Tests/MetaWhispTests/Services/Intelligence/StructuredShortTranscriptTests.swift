import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.6) — a transcript too short to structure never
/// overwrites a real title with the placeholder.
final class StructuredShortTranscriptTests: XCTestCase {

    func testARealTitleStays() {
        XCTAssertTrue(StructuredFieldSet.keepsFieldsOnShortTranscript(title: "Weekly sync"))
    }

    func testNoTitleOrThePlaceholderGetsThePlaceholder() {
        XCTAssertFalse(StructuredFieldSet.keepsFieldsOnShortTranscript(title: nil))
        XCTAssertFalse(StructuredFieldSet.keepsFieldsOnShortTranscript(title: ""))
        XCTAssertFalse(StructuredFieldSet.keepsFieldsOnShortTranscript(title: "Quick note"))
    }
}
