import SwiftData
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
        popupSlotsFree: Int = 4,
        presentedLast24h: Int = 0,
        dailyLimit: Int = .max
    ) -> ScreenAgentDeliveryService.Preflight {
        .init(featureEnabled: featureEnabled, isPaused: isPaused,
              meetingInProgress: meetingInProgress, pauseDuringMeetings: pauseDuringMeetings,
              visitIsStillCurrent: visitIsStillCurrent,
              secondsSinceLastPresented: secondsSinceLastPresented,
              minimumSecondsBetween: minimumSecondsBetween, popupSlotsFree: popupSlotsFree,
              presentedLast24h: presentedLast24h, dailyLimit: dailyLimit)
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

    /// Ported from the reference: a cooldown bounds the gap, the daily ceiling
    /// bounds the day.
    func testTheDailyCeilingSuppressesTheEleventhQuietCard() {
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(preflight(
                secondsSinceLastPresented: 7200,
                presentedLast24h: 10, dailyLimit: 10)),
            .suppress(.dailyBudget))
        XCTAssertEqual(
            ScreenAgentDeliveryService.decide(preflight(
                secondsSinceLastPresented: 7200,
                presentedLast24h: 9, dailyLimit: 10)),
            .present)
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
        XCTAssertEqual(
            Set(ScreenAgentDelivery.SuppressionReason.allCases.map(\.rawValue)).count,
            ScreenAgentDelivery.SuppressionReason.allCases.count,
            "two reasons sharing a code would make the Inbox labels lie")
    }

    // MARK: - the run/delivery journal (plan §4)

    @MainActor
    private func makeService() throws -> (ScreenAgentDeliveryService, ModelContainer) {
        let container = try ModelContainer(
            for: ScreenAgentItem.self, ScreenAgentRun.self, ScreenAgentDeliveryRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ScreenAgentDeliveryService(container: container), container)
    }

    private func makeItem(runID: UUID = UUID()) -> ScreenAgentItem {
        ScreenAgentItem(
            runID: runID, headline: "Presentation due at 16:00",
            body: "Sam is waiting.", sourceApp: "Mail",
            sourceWindowTitle: "Inbox", capturedAt: Date())
    }

    /// «Why did it speak at 15:04 and not 15:02» needs a row, silences
    /// included — a run that leaves no trace cannot be audited, only believed.
    @MainActor
    func testARunIsJournaledFromStartToOutcome() throws {
        let (service, container) = try makeService()
        let runID = try XCTUnwrap(service.beginRun(
            contextID: UUID(), trigger: "contextAccepted",
            deadlineAt: Date().addingTimeInterval(10)))
        service.completeRun(runID: runID, outcomeReason: "echoesTheScreen",
                            evidenceRefs: ["e1", "d0"], modelRoute: "pro")

        let runs = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, "completed")
        XCTAssertEqual(runs.first?.outcomeReason, "echoesTheScreen")
        XCTAssertEqual(runs.first?.evidenceRefs, ["e1", "d0"])
        XCTAssertEqual(runs.first?.modelRoute, "pro")
        XCTAssertNotNil(runs.first?.completedAt)
    }

    /// An item is the thing; a delivery is an event that happened to it.
    @MainActor
    func testADeliveryRecordFollowsTheItemLifecycle() throws {
        let (service, container) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.deliver(item, preflight: preflight()))

        let ctx = ModelContext(container)
        var records = try ctx.fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryOutcome, "pending")
        XCTAssertEqual(records.first?.itemID, item.id)

        service.confirmPresented(itemID: item.id)
        service.recordInteraction(.opened, itemID: item.id)

        records = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.first?.deliveryOutcome, "presented")
        XCTAssertNotNil(records.first?.presentedAt)
        XCTAssertEqual(records.first?.interactionOutcome, "opened")
        XCTAssertNotNil(records.first?.interactionAt)
    }

    @MainActor
    func testASuppressedDeliveryRecordIsTerminal() throws {
        let (service, container) = try makeService()
        XCTAssertNil(service.deliver(makeItem(), preflight: preflight(isPaused: true)))

        let records = try ModelContext(container)
            .fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryOutcome, "suppressed")
        XCTAssertEqual(records.first?.outcomeReason, "paused")
        XCTAssertNotNil(records.first?.terminalAt)
    }

    /// A crash mid-run must not leave the journal claiming an analysis is
    /// still going three relaunches later.
    @MainActor
    func testAStaleRunningRowIsReconciledOnTheNextBegin() throws {
        let (service, container) = try makeService()
        let stale = try XCTUnwrap(service.beginRun(
            contextID: UUID(), trigger: "contextAccepted",
            deadlineAt: Date().addingTimeInterval(-5)))   // already past deadline
        _ = service.beginRun(contextID: UUID(), trigger: "contextAccepted",
                             deadlineAt: Date().addingTimeInterval(10))

        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<ScreenAgentRun>())
        let staleRow = rows.first { $0.id == stale }
        XCTAssertEqual(staleRow?.status, "abandoned")
        XCTAssertNotNil(staleRow?.completedAt)
    }

    /// The watchdog marks only a row still running; a real completion that
    /// already landed — or lands after — is the truer outcome and wins.
    @MainActor
    func testExpireOnlyTouchesARunningRowAndCompletionOverwritesIt() throws {
        let (service, container) = try makeService()
        let runID = try XCTUnwrap(service.beginRun(
            contextID: UUID(), trigger: "contextAccepted",
            deadlineAt: Date().addingTimeInterval(10)))

        service.expireRun(runID: runID)
        var rows = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>())
        XCTAssertEqual(rows.first?.status, "expired")

        service.completeRun(runID: runID, outcomeReason: "item")
        rows = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>())
        XCTAssertEqual(rows.first?.status, "completedLate",
                       "the late truth outranks the timeout — and keeps the violation queryable")

        service.expireRun(runID: runID)
        rows = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>())
        XCTAssertEqual(rows.first?.status, "completedLate", "expire must not resurrect a closed run")
    }

    /// A retried run's attempt is still an event — silence in the table was
    /// the journal lying by omission.
    @MainActor
    func testASecondDeliveryAttemptLeavesARecord() throws {
        let (service, container) = try makeService()
        let runID = UUID()
        XCTAssertNotNil(service.deliver(makeItem(runID: runID), preflight: preflight()))
        XCTAssertNil(service.deliver(makeItem(runID: runID), preflight: preflight()))

        let records = try ModelContext(container)
            .fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.outcomeReason == "duplicateRun" })
    }

    /// An announcement is journaled — but "presented" only becomes true after
    /// the caller pushes the popup and confirms, exactly like every delivery:
    /// a quit between the two must not leave history claiming a card the user
    /// never saw.
    @MainActor
    func testAnAnnouncementIsJournaledAndPendingUntilConfirmed() throws {
        let (service, container) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.announce(item))

        var ctx = ModelContext(container)
        let runs = try ctx.fetch(FetchDescriptor<ScreenAgentRun>())
        XCTAssertEqual(runs.first?.trigger, "taskFulfillment")
        XCTAssertEqual(runs.first?.status, "completed")
        var records = try ctx.fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.first?.deliveryOutcome, "pending")
        XCTAssertNil(records.first?.presentedAt)

        service.confirmPresented(itemID: item.id)
        ctx = ModelContext(container)
        records = try ctx.fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertEqual(records.first?.deliveryOutcome, "presented")
        XCTAssertNotNil(records.first?.presentedAt)
    }

    /// A timeout is not a rejection, and the record has to keep them apart:
    /// a card nobody got to read looks identical to one someone chose to
    /// close unless the reason is stored.
    @MainActor
    func testATimeoutIsRecordedApartFromADismissal() throws {
        let (service, container) = try makeService()
        let timedOut = makeItem()
        let closed = makeItem()
        XCTAssertNotNil(service.deliver(timedOut, preflight: preflight()))
        XCTAssertNotNil(service.deliver(closed, preflight: preflight()))
        service.confirmPresented(itemID: timedOut.id)
        service.confirmPresented(itemID: closed.id)
        service.recordInteraction(.timedOut, itemID: timedOut.id)
        service.recordInteraction(.dismissed, itemID: closed.id)

        let records = try ModelContext(container)
            .fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        let outcomes = Dictionary(
            uniqueKeysWithValues: records.map { ($0.itemID, $0.interactionOutcome) })
        XCTAssertEqual(outcomes[timedOut.id], ScreenAgentDelivery.Interaction.timedOut.rawValue)
        XCTAssertEqual(outcomes[closed.id], ScreenAgentDelivery.Interaction.dismissed.rawValue)
        XCTAssertNotEqual(outcomes[timedOut.id], outcomes[closed.id],
                          "silence and rejection must not collapse into one word")
    }

    /// A prompt is the behaviour of this product. One edit to the wording made
    /// the agent silent, and the journal recorded promptVersion = "" — so
    /// recovering it meant remembering rather than querying.
    @MainActor
    func testARunRecordsWhichPromptTextProducedIt() throws {
        let (service, container) = try makeService()
        _ = service.beginRun(contextID: UUID(), trigger: "contextAccepted",
                             deadlineAt: Date().addingTimeInterval(10))
        let run = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>()).first)
        XCTAssertEqual(run.promptVersion, ScreenAgentPrompts.insight.version)
        XCTAssertTrue(run.promptVersion.hasPrefix("insight.v"))
    }

    /// The signature is derived from the text, so it cannot be forgotten: a
    /// changed word changes it. And it must survive a relaunch — `hashValue`
    /// is seeded per process and would regroup the journal every launch.
    func testThePromptSignatureFollowsTheTextAndIsStable() {
        let a = PromptDescriptor(name: "x", version: 1, text: "say less")
        let b = PromptDescriptor(name: "x", version: 1, text: "say less.")
        XCTAssertNotEqual(a.version, b.version, "a changed word must change the signature")
        XCTAssertEqual(a.version, PromptDescriptor(name: "x", version: 1, text: "say less").version)
        XCTAssertEqual(PromptDescriptor.signature(of: ""),
                       String(PromptDescriptor.signature(of: "")),
                       "the signature is a pure function of the text")
    }

    /// The run that actually happens is the investigation: with screen history
    /// in hand the assistant sends `investigationSystemPrompt`, and that is the
    /// text whose wording decides whether the agent speaks. Signing the
    /// single-pass prompt for both routes meant editing the real production
    /// prompt changed behaviour while every run kept the old signature, so
    /// "after which prompt edit did it get worse?" answered confidently and
    /// wrongly (Codex).
    func testTheInvestigationPromptIsSignedApartFromTheSinglePass() {
        XCTAssertNotEqual(ScreenAgentPrompts.insightInvestigation.version,
                          ScreenAgentPrompts.insight.version,
                          "two different texts cannot share one identity")
        XCTAssertTrue(
            ScreenAgentPrompts.insightInvestigation.version.hasPrefix("insight-investigation.v"))
    }

    /// A run opens before its route is known — history is fetched after the row
    /// exists — so the true prompt identity can only be recorded at completion.
    /// An unmeasured route must not erase a measured one, the same rule
    /// `modelRoute` already follows.
    @MainActor
    func testCompletingARunCorrectsThePromptItRecorded() throws {
        let (service, container) = try makeService()
        let runID = try XCTUnwrap(
            service.beginRun(contextID: UUID(), trigger: "contextAccepted",
                             deadlineAt: Date().addingTimeInterval(10)))
        service.completeRun(runID: runID, outcomeReason: "advice",
                            promptVersion: ScreenAgentPrompts.insightInvestigation.version)
        var run = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>()).first)
        XCTAssertEqual(run.promptVersion, ScreenAgentPrompts.insightInvestigation.version)

        service.completeRun(runID: runID, outcomeReason: "advice")
        run = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ScreenAgentRun>()).first)
        XCTAssertEqual(run.promptVersion, ScreenAgentPrompts.insightInvestigation.version,
                       "not-measured must not overwrite a measurement")
    }

    /// The interaction ends the presentation's lifecycle.
    @MainActor
    func testAnInteractionTerminalizesTheDeliveryRecord() throws {
        let (service, container) = try makeService()
        let item = makeItem()
        XCTAssertNotNil(service.deliver(item, preflight: preflight()))
        service.confirmPresented(itemID: item.id)
        service.recordInteraction(.timedOut, itemID: item.id)

        let records = try ModelContext(container)
            .fetch(FetchDescriptor<ScreenAgentDeliveryRecord>())
        XCTAssertNotNil(records.first?.terminalAt)
    }
}
