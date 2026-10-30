import XCTest
@testable import MetaWhisp

/// Replays late draft deliveries against the real, offscreen controller hosts.
@MainActor
final class MeetingCoachDisplayRetainedDraftTests: XCTestCase {
    func testPublishedBReplacesAWhileADraftIsStillStreaming() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Bravo")
        try await f.publishAndWait(a)
        f.state.showDraft(.init(requestID: a.id, generation: 1, kind: .answer,
                               heard: nil, blocks: [.headline("Alpha still streaming.")]))
        f.state.publish(b)
        try await Task.sleep(for: .milliseconds(300))
        // Read the actual installed root, not state.answers (which contains B).
        XCTAssertEqual(try f.installed().displayedBlocks, b.blocks)
    }

    func testLateDraftAfterBothPublicationsKeepsBInstalled() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Bravo")
        try await f.publishAndWait(a)
        try await f.publishAndWait(b)
        f.state.showDraft(.init(requestID: a.id, generation: 1, kind: .answer,
                               heard: nil, blocks: [.headline("Late Alpha.")]))
        f.controller.syncPanelVisibility()
        try f.assertInstalled(b)
        XCTAssertNil(f.state.draft)
    }

    func testClearBeforeFirstDeltaPreventsResurrection() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let id = UUID()
        state.clearDraft(requestID: id, generation: 1)
        state.showDraft(.init(requestID: id, generation: 1, kind: .answer,
                             heard: nil, blocks: [.headline("Cancelled request.")]))
        XCTAssertNil(state.draft)
        XCTAssertTrue(state.displayedBlocks.isEmpty)
    }

    func testClearFinishesOnlyItsGenerationAndArmResetsFinishedRequests() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let draft = MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
                                       heard: nil, blocks: [.headline("Current request.")])
        state.clearDraft(requestID: draft.requestID, generation: 2)
        state.showDraft(draft)
        XCTAssertEqual(state.draft, draft)
        state.clearDraft(requestID: draft.requestID, generation: 1)
        state.showDraft(draft)
        XCTAssertNil(state.draft)
        state.arm(generation: 1)
        state.showDraft(draft)
        XCTAssertEqual(state.draft, draft)
        state.arm(generation: 2)
        state.showDraft(draft)
        XCTAssertNil(state.draft)
    }

    func testFinishedRequestsStayBoundedWithoutAllowingAnEvictedDraftBack() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let old = MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
                                     heard: nil, blocks: [.headline("Evicted request.")])
        state.clearDraft(requestID: old.requestID, generation: 1, requestStartedAt: old.requestStartedAt)
        for _ in 0..<MeetingCoachState.maxFinishedRequests {
            state.clearDraft(requestID: UUID(), generation: 1)
        }
        XCTAssertEqual(state.finishedRequestCount, MeetingCoachState.maxFinishedRequests)
        state.showDraft(old)
        XCTAssertNil(state.draft)
        state.arm(generation: 2)
        XCTAssertEqual(state.finishedRequestCount, 0)
    }

    func testClearAnswersAndDisarmFinishTheirDraft() {
        for disarms in [false, true] {
            let state = MeetingCoachState()
            state.arm(generation: 1)
            let draft = MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
                                           heard: nil, blocks: [.headline("Retired request.")])
            state.showDraft(draft)
            if disarms { state.disarm() } else { state.clearAnswers() }
            state.showDraft(draft)
            XCTAssertNil(state.draft)
        }
    }

    func testDisarmRefusesTheFirstLateAutomaticDelta() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.disarm()
        state.showDraft(.init(requestID: UUID(), generation: 1, kind: .answer,
                             heard: nil, blocks: [.headline("Late automatic request.")]))
        XCTAssertNil(state.draft)
    }
}
