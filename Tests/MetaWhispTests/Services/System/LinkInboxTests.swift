import XCTest
@testable import MetaWhisp

/// The links macOS hands the app (Codex, 1.4.0 review): a sign-in link that opens the app is delivered while it
/// launches, before the app can act on it. The inbox holds such links in the order they came, hands them on once the
/// app can act, and tells the launch it was opened by a link — so the move to Applications, which would end the launch
/// and the link with it, is put off.
@MainActor
final class LinkInboxTests: XCTestCase {
    private let first = URL(string: "metawhisp://auth?token=first")!
    private let second = URL(string: "metawhisp://auth?token=second")!

    /// Links that come before the app can act are held, in order, and handed on when it can.
    func testLinksBeforeTheAppCanActAreHeldThenHandedOnInOrder() {
        let inbox = LinkInbox()
        var handled: [URL] = []
        inbox.receive(first)
        inbox.receive(second)
        XCTAssertTrue(handled.isEmpty, "held")
        inbox.open { handled.append($0) }
        XCTAssertEqual(handled, [first, second])
    }

    /// Once the app can act, a link goes straight on.
    func testALinkAfterTheAppCanActGoesStraightOn() {
        let inbox = LinkInbox()
        var handled: [URL] = []
        inbox.open { handled.append($0) }
        inbox.receive(first)
        XCTAssertEqual(handled, [first])
    }

    /// A link held during the launch means the launch was opened by one; a launch with none, or a link that comes
    /// once the app can act, does not.
    func testOnlyALinkHeldDuringTheLaunchMakesItOneALinkOpened() {
        let held = LinkInbox()
        XCTAssertFalse(held.openedByLink)
        held.receive(first)
        XCTAssertTrue(held.openedByLink)

        let later = LinkInbox()
        later.open { _ in }
        later.receive(first)
        XCTAssertFalse(later.openedByLink)
    }
}
