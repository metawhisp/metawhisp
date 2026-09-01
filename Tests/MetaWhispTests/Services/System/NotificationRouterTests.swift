import XCTest
@testable import MetaWhisp

/// The day recap is the best thing this app produces — 105 of 130 recaps carry
/// real "what you learned", 99 carry real "what you decided". It announces
/// itself with a notification, and clicking that notification did nothing at
/// all: the poster wrote `userInfo["target"]` and no reader existed, because
/// the app had no notification delegate.
///
/// These pin the contract between the two halves. A key one side writes and the
/// other does not read is invisible until someone clicks.
final class NotificationRouterTests: XCTestCase {

    func testTheDayRecapNotificationOpensTheDayRecap() {
        XCTAssertEqual(
            NotificationRouter.route(userInfo: ["target": "dashboard"]),
            .mainWindow(tab: .dashboard))
    }

    /// The exact payload `DailySummaryService` posts, read by the router that
    /// has to understand it. This is the test that would have failed on the day
    /// the notification was written.
    func testThePosterAndTheReaderAgree() {
        XCTAssertEqual(
            NotificationRouter.route(userInfo: DailySummaryService.recapNotificationInfo),
            .mainWindow(tab: .dashboard))
    }

    /// A notification from somewhere else must not throw a window at the user.
    /// Opening something arbitrary is worse than doing nothing, because the user
    /// clicked expecting one specific thing.
    func testAnUnknownNotificationOpensNothing() {
        XCTAssertEqual(NotificationRouter.route(userInfo: [:]), .none)
        XCTAssertEqual(NotificationRouter.route(userInfo: ["target": "wat"]), .none)
        XCTAssertEqual(NotificationRouter.route(userInfo: ["other": "dashboard"]), .none)
    }

    /// The screen agent's own cards already have a route into the Inbox; the
    /// router has to carry which card, or the click lands on a list and the user
    /// has to find the one they were just shown.
    func testAScreenAgentCardCarriesItsOwnIdentity() {
        let id = UUID()
        XCTAssertEqual(
            NotificationRouter.route(userInfo: ["target": "screenAgentItem",
                                               "itemID": id.uuidString]),
            .screenAgentInbox(itemID: id))
        XCTAssertEqual(
            NotificationRouter.route(userInfo: ["target": "screenAgentItem",
                                               "itemID": "not-a-uuid"]),
            .screenAgentInbox(itemID: nil),
            "a broken id still opens the inbox rather than swallowing the click")
    }
}
