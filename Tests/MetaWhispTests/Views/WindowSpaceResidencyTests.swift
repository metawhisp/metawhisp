import XCTest
@testable import MetaWhisp

/// The recurring "I click a button and it scrolls me to another desktop" bug.
///
/// The main window parks with `[.fullScreenAuxiliary]` — it belongs to exactly
/// one Space and stays visible there. Anything that ACTIVATES the app from a
/// different Space (a popover button, a card, the Dock icon) makes macOS bring
/// that window forward, which means taking the user to its Space.
///
/// The one guard that existed lived inside `MainWindowController.open()`, and
/// the app's own SpaceTrace log proves that branch never ran: two `create:`
/// entries across two launches, no `reuse:` at all. Activation goes around it
/// (2026-09-08, log evidence).
///
/// A window nobody is looking at, sitting on a Space the user has left, is
/// what gives macOS something to drag them to. So it is unbound — and comes
/// back on the Space the user is actually on the next time they open it.
final class WindowSpaceResidencyTests: XCTestCase {

    func testAWindowLeftOnAnotherSpaceIsUnbound() {
        XCTAssertEqual(WindowSpaceResidency.decide(isVisible: true, isOnActiveSpace: false, appIsActive: false),
                       .unbind,
                       "this is the window macOS would drag the user to")
    }

    func testAWindowOnTheUsersOwnSpaceIsLeftAlone() {
        XCTAssertEqual(WindowSpaceResidency.decide(isVisible: true, isOnActiveSpace: true, appIsActive: false),
                       .leaveAlone)
    }

    /// While the user is actually IN the app, the window must not be pulled
    /// out from under them — a Space change with MetaWhisp active is the user
    /// swiping away from a window they are using, and it should still be there
    /// when they swipe back.
    func testAWindowIsNotTakenFromAUserWhoIsUsingIt() {
        XCTAssertEqual(WindowSpaceResidency.decide(isVisible: true, isOnActiveSpace: false, appIsActive: true),
                       .leaveAlone)
    }

    func testAHiddenWindowNeedsNothing() {
        XCTAssertEqual(WindowSpaceResidency.decide(isVisible: false, isOnActiveSpace: false, appIsActive: false),
                       .leaveAlone)
    }

    /// Unbinding is not closing: the window was open, so the next open must
    /// bring it back rather than starting from a blank one.
    func testUnbindingRemembersThatTheWindowWasOpen() {
        XCTAssertTrue(WindowSpaceResidency.Decision.unbind.shouldReopenOnNextActivation)
        XCTAssertFalse(WindowSpaceResidency.Decision.leaveAlone.shouldReopenOnNextActivation)
    }
}
