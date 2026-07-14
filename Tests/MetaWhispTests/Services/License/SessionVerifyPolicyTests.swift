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

    // MARK: - ITER-052 — session-token 401 must not de-subscribe a cached Pro

    /// The every-relaunch logout bug: `verify()` sent the stored session token
    /// on launch, the server returned 401 (the one-time deep-link token had
    /// expired), and the app called `signOut()` — wiping a PAYING user's
    /// license every single launch. A 401/403 proves only that the TOKEN can't
    /// authenticate, NOT that the subscription lapsed (that's a 200 + inactive).
    /// So a token rejection while a trusted cached license exists must KEEP Pro.
    func test_rejectionAction_authRejectionWithCachedPro_keepsLicense() {
        XCTAssertEqual(LicenseService.rejectionAction(httpStatus: 401, hasTrustedCachedLicense: true), .keepCachedPro)
        XCTAssertEqual(LicenseService.rejectionAction(httpStatus: 403, hasTrustedCachedLicense: true), .keepCachedPro)
    }

    /// A token rejection with NOTHING cached to fall back on (fresh install, a
    /// planted/garbage token) still signs out — we genuinely need re-auth.
    func test_rejectionAction_authRejectionWithoutCache_signsOut() {
        XCTAssertEqual(LicenseService.rejectionAction(httpStatus: 401, hasTrustedCachedLicense: false), .signOut)
        XCTAssertEqual(LicenseService.rejectionAction(httpStatus: 403, hasTrustedCachedLicense: false), .signOut)
    }

    /// Transient / non-authoritative statuses never act on the license,
    /// regardless of cache — same posture as the offline catch branch.
    func test_rejectionAction_transientNeverActs() {
        for status in [500, 502, 503, 504, 429, 404, 408, -1] {
            XCTAssertEqual(LicenseService.rejectionAction(httpStatus: status, hasTrustedCachedLicense: true), .keepQuiet)
            XCTAssertEqual(LicenseService.rejectionAction(httpStatus: status, hasTrustedCachedLicense: false), .keepQuiet)
        }
    }
}
