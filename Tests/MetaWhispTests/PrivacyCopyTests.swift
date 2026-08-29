import XCTest
@testable import MetaWhisp

/// The permission dialog is where the user decides, so it is the one string
/// that has to be true.
///
/// It said: "Screenshots are processed locally and never sent to the cloud."
/// `ScreenAgentProVisionTransport` POSTs `image_b64` — the screenshot, base64 —
/// to `api.metawhisp.com/api/pro/vision` whenever Visual mode is on. The claim
/// was false in the exact dialog where the user grants screen access.
final class PrivacyCopyTests: XCTestCase {

    private func screenCaptureUsageDescription() throws -> String {
        // Repo-relative: Tests/MetaWhispTests/… → Resources/Info.plist
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaWhispTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])
        return try XCTUnwrap(plist["NSScreenCaptureUsageDescription"] as? String)
    }

    /// The specific sentence that was untrue, pinned so it cannot come back.
    func testThePermissionDialogDoesNotPromiseTheImageStaysOnTheMac() throws {
        let copy = try screenCaptureUsageDescription().lowercased()
        XCTAssertFalse(copy.contains("never sent to the cloud"),
                       "Visual mode sends the screenshot to our proxy")
        XCTAssertFalse(copy.contains("never leave"),
                       "same claim, different words")
    }

    /// Saying less is not the fix either. The dialog has to name the two things
    /// that actually leave: recognised text always, the image only behind a
    /// second switch.
    func testThePermissionDialogNamesWhatLeavesAndWhatDoesNot() throws {
        let copy = try screenCaptureUsageDescription().lowercased()
        XCTAssertTrue(copy.contains("visual mode"),
                      "the image only leaves behind a separate opt-in — say which")
        XCTAssertTrue(copy.contains("text"),
                      "recognised text is what leaves in the ordinary case")
        XCTAssertTrue(copy.contains("saved") || copy.contains("stored"),
                      "screenshots are not kept, and that is worth saying")
    }
}
