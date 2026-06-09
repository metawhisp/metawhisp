import XCTest
@testable import MetaWhisp

/// Pins the truthful wording of the post-sign-in banner (the one that replaced
/// the Space-throwing force-activate). The banner must never claim "Pro
/// activated" unless Pro was actually granted (Rule 13 — no fabricated state),
/// and must stay silent when there's nothing real to report.
final class SignInBannerDecisionTests: XCTestCase {

    func testProActivated_withEmail() {
        let b = SignInBannerDecision.resolve(isPro: true, lastError: nil, email: "sam@example.com")
        XCTAssertEqual(b, .init(title: "Pro activated", body: "Signed in as sam@example.com"))
    }

    func testProActivated_withoutEmail_usesGenericBody() {
        let b = SignInBannerDecision.resolve(isPro: true, lastError: nil, email: nil)
        XCTAssertEqual(b?.title, "Pro activated")
        XCTAssertEqual(b?.body, "Your Pro subscription is now active.")
    }

    func testProActivated_winsOverAStaleError() {
        // isPro is authoritative; a leftover error string must not downgrade it.
        let b = SignInBannerDecision.resolve(isPro: true, lastError: "Connection error", email: "sam@example.com")
        XCTAssertEqual(b?.title, "Pro activated")
    }

    func testFailure_surfacesTheError() {
        let b = SignInBannerDecision.resolve(isPro: false, lastError: "Activation failed. Try signing in again.", email: nil)
        XCTAssertEqual(b, .init(title: "Sign-in failed", body: "Activation failed. Try signing in again."))
    }

    func testSignedInNoSubscription() {
        let b = SignInBannerDecision.resolve(isPro: false, lastError: nil, email: "sam@example.com")
        XCTAssertEqual(b, .init(title: "Signed in", body: "sam@example.com — no active subscription."))
    }

    func testBlankErrorIsIgnored_fallsThroughToSignedIn() {
        let b = SignInBannerDecision.resolve(isPro: false, lastError: "   ", email: "sam@example.com")
        XCTAssertEqual(b?.title, "Signed in")
    }

    func testNothingToReport_returnsNil() {
        // No Pro, no error, no email → handler stays silent (no empty banner).
        XCTAssertNil(SignInBannerDecision.resolve(isPro: false, lastError: nil, email: nil))
        XCTAssertNil(SignInBannerDecision.resolve(isPro: false, lastError: "  ", email: "   "))
    }
}
