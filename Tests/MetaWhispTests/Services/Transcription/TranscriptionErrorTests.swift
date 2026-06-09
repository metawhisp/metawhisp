import XCTest
@testable import MetaWhisp

/// Pins FREE-3: a missing cloud API key surfaces a KEY-specific message, not the
/// on-device "Download a model first." copy (which sent BYOK users to download a
/// model they don't need).
final class TranscriptionErrorTests: XCTestCase {

    func testNoAPIKeyMessageIsKeySpecific() {
        let msg = TranscriptionError.noAPIKey.errorDescription
        XCTAssertEqual(msg, "No API key set — add one in Settings, or upgrade to Pro.")
        XCTAssertNotEqual(msg, TranscriptionError.modelNotLoaded.errorDescription)
    }

    func testModelNotLoadedMessageUnchanged() {
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded.errorDescription,
            "No model loaded. Download a model first."
        )
    }
}
