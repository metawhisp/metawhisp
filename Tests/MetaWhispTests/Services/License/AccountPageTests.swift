import AppKit
import XCTest
@testable import MetaWhisp

/// The site's account page — every "Get Pro" and "Sign in" in the app opens it (PLAN-v6 §1): sign in, which also
/// creates the account, then the plans, then "Open in MetaWhisp". When the browser does not open, the caller shows
/// the link with Copy (DOD D2). No browser is opened here.
@MainActor
final class AccountPageTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "mw-account-page-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheAccountPageIsTheSitesAccountAddress() {
        XCTAssertEqual(AccountPage.url.absoluteString, "https://metawhisp.com/account/")
    }

    func testOpenSaysWhetherTheBrowserOpenedTheAccountPage() {
        var asked: [URL] = []
        XCTAssertTrue(AccountPage.open(defaults: defaults, with: { asked.append($0); return true }))
        XCTAssertFalse(AccountPage.open(defaults: defaults, with: { asked.append($0); return false }))
        XCTAssertEqual(asked, [AccountPage.url, AccountPage.url])
    }

    /// A3 — Get Pro and Sign in mark the sign-in as expected before the site opens, so the link it sends back signs
    /// in without a question; also when the browser did not open and the user opens the shown link by hand.
    func testOpeningMarksTheSignInAsExpectedFirst() {
        XCTAssertFalse(SignInExpectation.isExpected(defaults: defaults), "nothing pressed yet")
        var expectedWhenOpened = false
        _ = AccountPage.open(defaults: defaults, with: { [defaults] _ in
            expectedWhenOpened = SignInExpectation.isExpected(defaults: defaults!)
            return false
        })
        XCTAssertTrue(expectedWhenOpened, "marked before the browser is asked")
        XCTAssertTrue(SignInExpectation.isExpected(defaults: defaults), "and kept when it did not open")
    }

    /// Copy writes the address on the click alone — the user asked for it.
    func testCopyWritesTheAddressOnTheClickAlone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mw-account-page-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's own", forType: .string)
        _ = AccountPage.url
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own", "nothing but the click writes")
        AccountPage.copy(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "https://metawhisp.com/account/")
    }
}
