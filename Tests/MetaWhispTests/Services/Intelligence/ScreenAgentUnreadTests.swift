import XCTest
import SwiftData
@testable import MetaWhisp

/// A card that timed out is a message that was delivered and not read. Until
/// now that fact went into the journal and nowhere the user could see it, so
/// the only way back to a missed comment was to have caught it live. The
/// count is derived from the delivery journal against a "last time you
/// looked" mark — no new column, no migration.
@MainActor
final class ScreenAgentUnreadTests: XCTestCase {

    private func makeService() throws -> (ScreenAgentDeliveryService, ModelContainer) {
        let container = try ModelContainer(
            for: ScreenAgentItem.self, ScreenAgentRun.self, ScreenAgentDeliveryRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ScreenAgentDeliveryService(container: container), container)
    }

    private func makeItem() -> ScreenAgentItem {
        ScreenAgentItem(
            runID: UUID(), headline: "Ads payment declined",
            body: "The card was refused", sourceApp: "Chrome",
            sourceWindowTitle: "Billing", capturedAt: Date())
    }

    private func preflight() -> ScreenAgentDeliveryService.Preflight {
        .init(featureEnabled: true, isPaused: false, meetingInProgress: false,
              pauseDuringMeetings: true, visitIsStillCurrent: true,
              secondsSinceLastPresented: nil, minimumSecondsBetween: 0,
              popupSlotsFree: 4, presentedLast24h: 0, dailyLimit: .max)
    }

    /// A card nobody got to read is exactly what the count is for.
    func testATimedOutCardCountsAsUnread() throws {
        let (service, _) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.deliver(item, preflight: preflight()))
        service.confirmPresented(itemID: item.id)
        service.recordInteraction(.timedOut, itemID: item.id)

        XCTAssertEqual(service.unreadCount(since: .distantPast), 1)
    }

    /// Opening it is reading it, and closing it on purpose is a decision. Both
    /// mean the message reached a person, so neither is waiting for one.
    func testHandledCardsDoNotCount() throws {
        let (service, _) = try makeService()
        let opened = makeItem()
        let closed = makeItem()
        for item in [opened, closed] {
            XCTAssertNotNil(service.deliver(item, preflight: preflight()))
            service.confirmPresented(itemID: item.id)
        }
        service.recordInteraction(.opened, itemID: opened.id)
        service.recordInteraction(.dismissed, itemID: closed.id)

        XCTAssertEqual(service.unreadCount(since: .distantPast), 0)
    }

    /// The mark is what makes the badge clearable without a schema change:
    /// anything queued before the last visit to the Inbox has been looked at,
    /// whatever the journal says happened to the card.
    func testNothingBeforeTheLastLookCounts() throws {
        let (service, _) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.deliver(item, preflight: preflight()))
        service.confirmPresented(itemID: item.id)
        service.recordInteraction(.timedOut, itemID: item.id)

        XCTAssertEqual(service.unreadCount(since: Date().addingTimeInterval(60)), 0,
                       "a card older than the last look is not waiting for anyone")
    }

    /// A card that was pushed off the stack by newer ones was shown but may
    /// never have been read — the journal records `replaced` precisely so this
    /// case does not get filed as handled.
    func testACardPushedOffTheStackStillCounts() throws {
        let (service, _) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.deliver(item, preflight: preflight()))
        service.confirmPresented(itemID: item.id)
        service.recordInteraction(.replaced, itemID: item.id)

        XCTAssertEqual(service.unreadCount(since: .distantPast), 1)
    }
}
