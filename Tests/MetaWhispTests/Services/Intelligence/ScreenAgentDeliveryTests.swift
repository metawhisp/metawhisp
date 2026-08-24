import XCTest
@testable import MetaWhisp

/// The last gate before something interrupts the user.
///
/// A Screen Agent comment used to go straight onto the notification stack,
/// bypassing the meeting quiet-hours and pacing that every other notification
/// respects, with nothing recording that it had happened. "We generated an
/// insight" and "the user saw an insight" were the same number, which is how a
/// feature convinces itself it is working.
final class ScreenAgentDeliveryTests: XCTestCase {

    private func preflight(
        featureEnabled: Bool = true,
        isPaused: Bool = false,
        meetingInProgress: Bool = false,
        pauseDuringMeetings: Bool = true,
        visitIsStillCurrent: Bool = true,
        secondsSinceLastPresented: TimeInterval? = nil,
        minimumSecondsBetween: TimeInterval = 300,
        popupSlotsFree: Int = 4
    ) -> ScreenAgentDeliveryService.Preflight {
        .init(featureEnabled: featureEnabled, isPaused: isPaused,
              meetingInProgress: meetingInProgress, pauseDuringMeetings: pauseDuringMeetings,
              visitIsStillCurrent: visitIsStillCurrent,
              secondsSinceLastPresented: secondsSinceLastPresented,
              minimumSecondsBetween: minimumSecondsBetween, popupSlotsFree: popupSlotsFree)
    }

    func testAGoodCommentIsPresented() {
        XCTAssertEqual(ScreenAgentDeliveryService.decide(preflight()), .present)
    }

    /// Being told to be quiet outranks anything the agent believes about its
    /// own usefulness.
    func testPauseBeatsEverything() {
        XCTAssertEqual(ScreenAgentDeliveryService.decide(preflight(isPaused: true)),
                       .suppress(.paused))
    }

    func testFeatureOffBeatsPause() {
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(preflight(featureEnabled: false, isPaused: true)),
            .suppress(.featureOff))
    }

    /// Interrupting someone mid-call is the most expensive possible moment.
    func testAMeetingSuppressesByDefault() {
        XCTAssertEqual(ScreenAgentDeliveryService.decide(preflight(meetingInProgress: true)),
                       .suppress(.meetingInProgress))
    }

    func testAMeetingCanBeAllowedIfTheUserSaysSo() {
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(
                preflight(meetingInProgress: true, pauseDuringMeetings: false)),
            .present)
    }

    /// The reason this whole iteration exists: the user moved on while the
    /// model was thinking, and freshness is re-checked here rather than only
    /// when the work started.
    func testAStaleVisitIsNotPresented() {
        XCTAssertEqual(ScreenAgentDeliveryService.decide(preflight(visitIsStillCurrent: false)),
                       .suppress(.staleVisit))
    }

    func testPacingHoldsBackARapidSecondComment() {
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(
                preflight(secondsSinceLastPresented: 30, minimumSecondsBetween: 300)),
            .suppress(.pacing))
    }

    func testPacingAllowsOneOnceEnoughTimeHasPassed() {
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(
                preflight(secondsSinceLastPresented: 301, minimumSecondsBetween: 300)),
            .present)
    }

    func testAFullStackSuppressesRatherThanShoving() {
        XCTAssertEqual(ScreenAgentDeliveryService.decide(preflight(popupSlotsFree: 0)),
                       .suppress(.stackFull))
    }

    /// A quiet reason must never be reported as a presentation. The whole
    /// point of separating them is that suppressed work is still findable.
    func testEverySuppressionIsDistinguishableFromAPresentation() {
        let suppressing = [
            preflight(featureEnabled: false),
            preflight(isPaused: true),
            preflight(meetingInProgress: true),
            preflight(visitIsStillCurrent: false),
            preflight(secondsSinceLastPresented: 1),
            preflight(popupSlotsFree: 0),
        ]
        for p in suppressing {
            XCTAssertNotEqual(ScreenAgentDeliveryService.decide(p), .present)
        }
    }

    /// Closing a popup is not feedback, and a timeout is not a judgement.
    /// Interaction is a separate axis from whether it was shown at all.
    func testInteractionIsSeparateFromDelivery() {
        XCTAssertNotEqual(ScreenAgentDelivery.Outcome.presented.rawValue,
                          ScreenAgentDelivery.Interaction.timedOut.rawValue)
        XCTAssertEqual(ScreenAgentDelivery.Interaction.none.rawValue, "none")
        XCTAssertTrue(ScreenAgentDelivery.Interaction.allCases.contains(.later))
    }
}

/// The Codex review of ITER-067 called two things critical, and both were about
/// the record telling the truth rather than about anything the user clicks.
extension ScreenAgentDeliveryTests {

    /// `presented` used to be written before the popup was built. A quit or a
    /// render failure in between left durable history claiming the user saw
    /// something that never appeared — the one number the whole feature is
    /// judged on, quietly inflated.
    func testAnItemStartsPendingRatherThanClaimingItWasShown() {
        let item = ScreenAgentItem(
            runID: UUID(), headline: "h", body: "b",
            sourceApp: "Slack", sourceWindowTitle: "#launch", capturedAt: Date())
        XCTAssertEqual(item.deliveryOutcome, ScreenAgentDelivery.Outcome.pending.rawValue)
        XCTAssertNil(item.deliveredAt)
    }

    /// A card can be opened and then also time out. Letting the later event win
    /// would turn something the user acted on into something they ignored.
    func testTheVocabularySeparatesActingFromIgnoring() {
        XCTAssertNotEqual(ScreenAgentDelivery.Interaction.opened,
                          ScreenAgentDelivery.Interaction.timedOut)
        XCTAssertNotEqual(ScreenAgentDelivery.Interaction.dismissed,
                          ScreenAgentDelivery.Interaction.timedOut)
        // Pushed off the stack by newer cards: shown, possibly unread. Not the
        // same as the user closing it.
        XCTAssertNotEqual(ScreenAgentDelivery.Interaction.replaced,
                          ScreenAgentDelivery.Interaction.dismissed)
    }

    /// Suppression reasons are what the Inbox shows instead of leaving the user
    /// wondering whether they missed something.
    func testEverySuppressionReasonIsNameable() {
        for reason in ScreenAgentDelivery.SuppressionReason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
        }
        XCTAssertEqual(ScreenAgentDelivery.SuppressionReason.allCases.count, 7)
    }
}
