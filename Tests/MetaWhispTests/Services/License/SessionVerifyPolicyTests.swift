import XCTest
@testable import MetaWhisp

/// ITER-050 B1.2 — pins the sign-out policy for session verification.
/// History: `verify()` signed the user out on ANY non-200, so a transient
/// worker 5xx at launch logged a paying user out, dropped LLM access and let
/// the project backfill wipe 196 conversation titles.
final class SessionVerifyPolicyTests: XCTestCase {

    func testAuthoritativeRejectionsSignOut() {
        XCTAssertTrue(LicenseService.shouldSignOutOnVerify(httpStatus: 401))
        XCTAssertTrue(LicenseService.shouldSignOutOnVerify(httpStatus: 403))
    }

    func testTransientFailuresKeepCachedState() {
        for status in [500, 502, 503, 504, 429, 404, 408, -1] {
            XCTAssertFalse(LicenseService.shouldSignOutOnVerify(httpStatus: status),
                           "HTTP \(status) is not an authoritative auth rejection — must keep cached Pro")
        }
    }
}
