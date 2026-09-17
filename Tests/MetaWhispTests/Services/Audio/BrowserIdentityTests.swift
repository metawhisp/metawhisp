import XCTest
@testable import MetaWhisp

/// What counts as a browser.
///
/// Call detection recognised browsers from a list of seven bundle ids. Dia
/// (`company.thebrowser.dia`) was not on it — Arc, from the same makers, was —
/// so a Google Meet call held in Dia was invisible to auto-start: the window
/// was never a "call window", the streak never advanced, and only a calendar
/// event could ever start a recording (owner's report, 2026-09-17).
///
/// A hardcoded list is the defect, not the missing line in it: the next
/// browser would be missing too. The system already knows which applications
/// open web pages, so that is what decides.
final class BrowserIdentityTests: XCTestCase {

    func testAnApplicationTheSystemOpensWebPagesWithIsABrowser() {
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "company.thebrowser.dia",
                                                systemHandlers: ["company.thebrowser.dia"]))
    }

    /// The browser that shipped after this code was written is recognised
    /// without anyone editing a list.
    func testABrowserNobodyHasHeardOfYetIsABrowser() {
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "com.example.somethingnew",
                                                systemHandlers: ["com.example.somethingnew"]))
    }

    func testAnApplicationThatIsNotAWebHandlerIsNotABrowser() {
        XCTAssertFalse(BrowserIdentity.isBrowser(bundleID: "com.apple.finder",
                                                 systemHandlers: ["com.apple.Safari"]))
    }

    /// The known names still hold when the system answers nothing at all —
    /// a LaunchServices query that comes back empty must not make Safari stop
    /// being a browser.
    func testTheKnownBrowsersHoldWithoutTheSystemsHelp() {
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "com.apple.Safari", systemHandlers: []))
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "com.google.Chrome", systemHandlers: []))
    }
}
