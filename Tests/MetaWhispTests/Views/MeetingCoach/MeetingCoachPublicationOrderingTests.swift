import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachPublicationOrderingTests: XCTestCase {
    private let start = ContinuousClock.now

    func testPublishingFinishesAndClearsItsOwnDraft() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let answer = answer("Final", offset: 0)
        let draft = draft("Partial", id: answer.id, offset: 0)
        state.showDraft(draft)
        state.publish(answer)
        XCTAssertNil(state.draft)
        XCTAssertEqual(state.displayedBlocks, answer.blocks)
        state.showDraft(draft)
        XCTAssertNil(state.draft)
    }

    func testNewerPublicationClearsAndFinishesAnOlderRequestsDraft() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let older = draft("Old", offset: 0)
        state.showDraft(older)
        let newer = answer("New", offset: 1)
        state.publish(newer)
        XCTAssertNil(state.draft)
        XCTAssertEqual(state.displayedBlocks, newer.blocks)
        state.showDraft(older)
        XCTAssertNil(state.draft)
    }

    func testOlderPublicationPreservesANewerRequestsDraft() {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        let newer = draft("New", offset: 1)
        state.showDraft(newer)
        state.publish(answer("Old", offset: 0))
        XCTAssertEqual(state.draft, newer)
        XCTAssertEqual(state.displayedBlocks, newer.blocks)
    }

    func testThreePublicationsEachInstallThroughControllerDespiteLateDrafts() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let answers = [answer("Alpha", offset: 0), answer("Bravo", offset: 1), answer("Charlie", offset: 2)]
        var installed: [UUID] = []
        f.controller.onTransitionCommitted = { _ in
            if let snapshot = try? f.installed(), !snapshot.isDraft, let id = snapshot.requestID,
               installed.last != id { installed.append(id) }
        }
        for (index, answer) in answers.enumerated() {
            f.state.showDraft(draft("Streaming \(index)", id: answer.id, offset: index))
            try await f.waitUntil { try f.installed().isDraft && f.installed().requestID == answer.id }
            f.state.publish(answer)
            try await f.waitUntil { try !f.installed().isDraft && f.installed().requestID == answer.id }
            try f.assertInstalled(answer)
            for retired in 0...index {
                f.state.showDraft(draft("Late \(retired)", id: answers[retired].id, offset: retired))
            }
            f.controller.syncPanelVisibility()
            try f.assertInstalled(answer)
        }
        XCTAssertEqual(installed, answers.map(\.id))
    }

    private func answer(_ text: String, offset: Int) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), generation: 1, heard: "Heard \(text)", kind: .answer,
            provenance: .transcript, action: nil, blocks: [.headline(text)],
            // Deliberately reverse wall-clock times: ordering is by request start.
            createdAt: Date(timeIntervalSince1970: Double(100 - offset)), question: "Question \(text)",
            requestStartedAt: start.advanced(by: .seconds(offset)))
    }

    private func draft(_ text: String, id: UUID = UUID(), offset: Int) -> MeetingAnswerDraft {
        MeetingAnswerDraft(requestID: id, generation: 1, kind: .answer,
            heard: "Heard \(text)", blocks: [.headline(text)], question: "Question \(text)",
            requestStartedAt: start.advanced(by: .seconds(offset)))
    }
}
