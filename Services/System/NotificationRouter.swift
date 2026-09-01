import Foundation

/// Where a notification the user clicked should take them.
///
/// The day recap posted a notification carrying `userInfo["target"]` and the app
/// had no `UNUserNotificationCenterDelegate` at all, so nothing ever read that
/// key: the announcement arrived, the click did nothing, and the best thing this
/// app produces sat behind a window the user had to know to go and find.
///
/// The decision lives here as a pure function rather than inside the delegate so
/// the agreement between whoever posts a notification and whoever answers the
/// click is something a test can hold. A key one side writes and the other does
/// not read is invisible until a person clicks it.
enum NotificationRouter {

    enum Destination: Equatable {
        case mainWindow(tab: MainWindowView.SidebarTab)
        case screenAgentInbox(itemID: UUID?)
        /// Nothing recognisable. Opening an arbitrary window is worse than doing
        /// nothing: the user clicked expecting one specific thing.
        case none
    }

    static let targetKey = "target"
    static let itemIDKey = "itemID"

    static func route(userInfo: [AnyHashable: Any]) -> Destination {
        guard let target = userInfo[targetKey] as? String else { return .none }
        switch target {
        case "dashboard":
            return .mainWindow(tab: .dashboard)
        case "screenAgentItem":
            // A broken id still opens the inbox: the card is in there, and
            // swallowing the click would be the worse failure.
            let raw = userInfo[itemIDKey] as? String
            return .screenAgentInbox(itemID: raw.flatMap(UUID.init(uuidString:)))
        default:
            return .none
        }
    }
}
