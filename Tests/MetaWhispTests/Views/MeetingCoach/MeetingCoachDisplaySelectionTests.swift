import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachDisplaySelectionTests: XCTestCase {
    func testOlderAndEqualStartDraftsCannotHideANewerPublishedAnswer() {
        for offset in [-1, 0] {
            let state = MeetingCoachState()
            state.arm(generation: 1)
            let answer = answer()
            state.publish(answer)
            let older = MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
                heard: "Stale heard", blocks: [.headline("Stale draft")], question: "Stale question",
                requestStartedAt: answer.requestStartedAt.advanced(by: .seconds(offset)))
            // The request was never published or cleared: exercise selection,
            // independently of the finished-request admission guard.
            state.showDraft(older)
            XCTAssertEqual(state.draft, older)
            XCTAssertEqual(state.displayedBlocks, answer.blocks)
            XCTAssertEqual(state.displayedHeard, answer.heard)
            XCTAssertEqual(state.displayedQuestion, answer.question)
            XCTAssertTrue(state.canExpandLatest)
            let snapshot = MeetingCoachRenderSnapshot(state: state, expanded: false, screenContextEnabled: false)
            XCTAssertEqual(snapshot.requestID, answer.id)
            XCTAssertEqual(snapshot.generation, answer.generation)
            XCTAssertFalse(snapshot.isDraft)
            XCTAssertEqual(snapshot.renderedBlocks.map { String($0.characters) }, ["Published answer"])
        }
    }

    func testNewerDraftOwnsAllDisplayFieldsIncludingNilHeardAndQuestion() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let answer = answer()
        state.publish(answer)
        let newer = MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
            heard: nil, blocks: [.headline("New draft")], question: nil,
            requestStartedAt: answer.requestStartedAt.advanced(by: .seconds(1)))
        state.showDraft(newer)
        XCTAssertEqual(state.displayedBlocks, newer.blocks)
        XCTAssertNil(state.displayedHeard)
        XCTAssertNil(state.displayedQuestion)
        XCTAssertFalse(state.canExpandLatest)
        let snapshot = MeetingCoachRenderSnapshot(state: state, expanded: false, screenContextEnabled: false)
        XCTAssertEqual(snapshot.requestID, newer.requestID)
        XCTAssertTrue(snapshot.isDraft)
    }

    func testLateOlderDraftKeepsThePublishedIdentityInTheInstalledHost() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let answer = answer()
        try await f.publishAndWait(answer)
        f.state.showDraft(.init(requestID: UUID(), generation: 1, kind: .answer,
            heard: "Stale heard", blocks: [.headline("Stale draft")], question: "Stale question",
            requestStartedAt: answer.requestStartedAt.advanced(by: .seconds(-1))))
        f.controller.syncPanelVisibility()
        try f.assertInstalled(answer)
        XCTAssertEqual(try f.installed().displayedHeard, answer.heard)
        XCTAssertEqual(try f.installed().displayedQuestion, answer.question)
    }

    func testIgnoredOlderDraftDoesNotBlockExpandingTheDisplayedAnswer() async {
        let h = makeAnswerHarness(generation: { 1 })
        defer { h.service.stop() }
        h.state.arm(generation: 1)
        let answer = answer()
        h.state.publish(answer)
        h.state.showDraft(.init(requestID: UUID(), generation: 1, kind: .answer,
            heard: nil, blocks: [.headline("Old draft")],
            requestStartedAt: answer.requestStartedAt.advanced(by: .seconds(-1))))
        let request = h.service.requestAction(.more)
        XCTAssertNotNil(request)
        await request?.value
        XCTAssertEqual(h.requestCount, 1)
    }

    private func answer() -> MeetingAnswer {
        MeetingAnswer(id: UUID(), generation: 1, heard: "Published heard", kind: .answer,
            provenance: .transcript, action: nil, blocks: [.headline("Published answer")],
            createdAt: Date(), question: "Published question")
    }
}
