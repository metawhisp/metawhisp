import XCTest
@testable import MetaWhisp

/// The status-to-permission mapping is a pinned contract: the numbers come
/// from the Apple Events SDK header, and a wrong mapping would either send
/// events after a refusal or never ask when macOS requires consent.
final class AutomationPermissionTests: XCTestCase {
    func testNoErrorMeansAllowed() {
        XCTAssertEqual(AutomationPermission.classify(0), .allowed)
    }

    func testWouldRequireConsentMeansAskTheUser() {
        XCTAssertEqual(AutomationPermission.classify(-1744), .needsConsent)
    }

    func testNotPermittedMeansDenied() {
        XCTAssertEqual(AutomationPermission.classify(-1743), .denied)
    }

    func testProcessNotFoundMeansTheBrowserIsNotRunning() {
        XCTAssertEqual(AutomationPermission.classify(-600), .targetNotRunning)
    }

    func testAnyOtherStatusIsKeptAsAFailure() {
        XCTAssertEqual(AutomationPermission.classify(-1712), .failed(-1712))
    }
}
