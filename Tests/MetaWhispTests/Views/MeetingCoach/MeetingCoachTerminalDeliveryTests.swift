import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachTerminalDeliveryTests: XCTestCase {
    func testPublishedRequestCannotInstallItsAlreadyMeasuredDraft() async throws {
        try await verifyTerminalDuringMeasurement(publishes: true)
    }

    func testCancelledRequestCannotInstallItsAlreadyMeasuredDraft() async throws {
        try await verifyTerminalDuringMeasurement(publishes: false)
    }

    private func verifyTerminalDuringMeasurement(publishes: Bool) async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let previous = f.answer("Previous")
        try await f.publishAndWait(previous)
        let pending = f.answer("Pending", extraLines: 8)
        var terminalReached = false
        var lateDraftCommits = 0
        f.controller.onTransitionCommitted = { _ in
            if terminalReached, (try? f.installed().isDraft) == true { lateDraftCommits += 1 }
        }
        f.controller.onTargetMeasured = { _ in
            f.controller.onTargetMeasured = nil
            terminalReached = true
            if publishes { f.state.publish(pending) }
            else { f.state.clearDraft(requestID: pending.id, generation: 1) }
            // Only the normal R17 coalesced invalidation runs. A synchronous
            // controller refresh here would conceal the queued-delivery race.
        }
        f.state.showDraft(.init(requestID: pending.id, generation: 1, kind: .answer,
            heard: nil, blocks: pending.blocks))

        try await f.waitUntil {
            guard terminalReached else { return false }
            return try !f.installed().isDraft
        }
        try f.assertInstalled(publishes ? pending : previous)
        XCTAssertEqual(lateDraftCommits, 0, "A terminal request must retire its captured draft before the coalesced update.")
    }
}
