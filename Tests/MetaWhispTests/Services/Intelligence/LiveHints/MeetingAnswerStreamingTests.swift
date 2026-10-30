import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerStreamingTests: XCTestCase {
    func testTypedQuestionTravelsWithItsDraftAndPublishedIdentity() async throws {
        let h = StreamHarness()
        let request = h.service.requestQuestion("  Which milestone comes next?\n")
        await h.waitForRequests(1)
        h.route.send(.delta("**Confirm the next milestone.**"), at: 0)
        await h.wait { h.state.draft != nil }
        let draft = try XCTUnwrap(h.state.draft)
        XCTAssertEqual(draft.question, "Which milestone comes next?")
        XCTAssertEqual(h.state.displayedQuestion, draft.question)

        h.route.end(200, at: 0)
        await request?.value

        let answer = try XCTUnwrap(h.state.answers.first)
        XCTAssertEqual(answer.question, "Which milestone comes next?")
        XCTAssertEqual(h.state.displayedQuestion, answer.question)
        XCTAssertEqual(answer.id, draft.requestID)
        XCTAssertEqual(answer.generation, draft.generation)
    }

    func testSupersessionKeepsOnlyTheCurrentRequestsQuestion() async throws {
        let h = StreamHarness()
        let first = h.service.requestQuestion("Which milestone comes first?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Confirm the first milestone.**"), at: 0)
        await h.wait { h.state.draft != nil }
        let old = try XCTUnwrap(h.state.draft)
        XCTAssertEqual(old.question, "Which milestone comes first?")

        let second = h.service.requestQuestion("Which dependency remains?")
        await h.waitForRequests(2)
        h.route.send(.delta("**Confirm the dependency.**"), at: 1)
        await h.wait { h.state.draft?.requestID != old.requestID && h.state.draft != nil }
        let current = try XCTUnwrap(h.state.draft)
        XCTAssertEqual(current.question, "Which dependency remains?")
        XCTAssertEqual(h.state.displayedQuestion, current.question)
        h.route.send(.delta("Late old content."), at: 0)
        h.route.end(200, at: 0)
        await first?.value
        await h.drain()
        XCTAssertEqual(h.state.draft, current)
        XCTAssertEqual(h.state.displayedQuestion, current.question)

        h.route.end(200, at: 1)
        await second?.value
        let answer = try XCTUnwrap(h.state.answers.first)
        XCTAssertEqual(answer.id, current.requestID)
        XCTAssertEqual(answer.question, "Which dependency remains?")
        XCTAssertEqual(h.state.displayedQuestion, answer.question)
    }

    func testRejectedAndFailedDraftsRestoreThePreviousAnswersQuestion() async throws {
        for rejectsContent in [false, true] {
            let h = StreamHarness()
            let accepted = h.service.requestQuestion("Which milestone is agreed?")
            await h.waitForRequests(1)
            h.route.send(.delta("**The review milestone is agreed.**"), at: 0)
            h.route.end(200, at: 0)
            await accepted?.value
            let previous = try XCTUnwrap(h.state.answers.first)
            XCTAssertEqual(previous.question, "Which milestone is agreed?")

            let rejected = h.service.requestQuestion("Which dependency is unresolved?")
            await h.waitForRequests(2)
            h.route.send(.delta("**Check the dependency.**"), at: 1)
            await h.wait { h.state.draft != nil }
            let draft = try XCTUnwrap(h.state.draft)
            XCTAssertEqual(draft.question, "Which dependency is unresolved?")
            XCTAssertEqual(h.state.displayedQuestion, draft.question)
            if rejectsContent { h.route.send(.delta(String(repeating: "x", count: 901)), at: 1) }
            h.route.end(rejectsContent ? 200 : 500, at: 1)
            await rejected?.value

            XCTAssertNil(h.state.draft)
            XCTAssertEqual(h.state.answers.first, previous)
            XCTAssertEqual(h.state.answers.first?.question, "Which milestone is agreed?")
            XCTAssertEqual(h.state.displayedQuestion, previous.question)
        }
    }

    func testStoppedAndRestartedMeetingNeverShowsTheOldRequestsQuestion() async throws {
        let state = MeetingCoachState()
        let old = StreamHarness(state: state)
        let accepted = old.service.requestQuestion("Which milestone was accepted?")
        await old.waitForRequests(1)
        old.route.send(.delta("**The earlier milestone was accepted.**"), at: 0)
        old.route.end(200, at: 0)
        await accepted?.value
        XCTAssertEqual(state.displayedQuestion, "Which milestone was accepted?")
        let request = old.service.requestQuestion("Which old milestone remains?")
        await old.waitForRequests(2)
        old.route.send(.delta("**The old milestone remains.**"), at: 1)
        await old.wait { state.draft != nil }
        let draft = try XCTUnwrap(state.draft)
        XCTAssertEqual(draft.question, "Which old milestone remains?")
        XCTAssertEqual(state.displayedQuestion, draft.question)

        old.service.stop()
        state.disarm()
        XCTAssertNil(state.draft)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.displayedQuestion)
        let fresh = StreamHarness(state: state, generation: { 2 })
        XCTAssertTrue(state.answers.isEmpty)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.displayedQuestion)
        old.route.end(200, at: 1)
        await request?.value
        await fresh.drain()
        XCTAssertTrue(state.answers.isEmpty)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.displayedQuestion)
        fresh.service.stop()
    }

    func testPublishedAnswerKeepsItsDraftRequestIdentity() async throws {
        let h = StreamHarness(generation: { 37 })
        let request = h.service.requestQuestion("Which milestone comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Confirm the next milestone.**"), at: 0)
        await h.wait { h.state.draft != nil }
        let draft = try XCTUnwrap(h.state.draft)

        h.route.end(200, at: 0)
        await request?.value

        let answer = try XCTUnwrap(h.state.answers.first)
        XCTAssertEqual(answer.id, draft.requestID)
        XCTAssertEqual(answer.generation, draft.generation)
        XCTAssertEqual(draft.generation, 37)
        XCTAssertEqual(answer.requestStartedAt, draft.requestStartedAt)
    }

    func testPublishedActionsKeepTheirSynchronouslyCapturedRequestIdentity() async throws {
        for action in [MeetingAnswerAction.questions, .recap, .more, .screen] {
            let h = StreamHarness(generation: { 41 })
            await h.seed()
            let request = action == .screen ? h.service.requestScreen() : h.service.requestAction(action)
            // Inspect ownership without exposing a production-only testing hook.
            let identity = try XCTUnwrap(Mirror(reflecting: h.service)
                .descendant("runningUserRequest") as? MeetingRequestIdentity)
            await h.waitForRequests(1)
            h.route.send(.delta("A useful response\n- Confirm the next milestone."), at: 0)
            h.route.end(200, at: 0)
            await request?.value

            let answer = try XCTUnwrap(h.state.answers.first)
            XCTAssertEqual(answer.action, action)
            XCTAssertEqual(answer.id, identity.uuid)
            XCTAssertEqual(answer.generation, identity.generation)
            XCTAssertEqual(answer.requestStartedAt, identity.startedAt)
            XCTAssertEqual(identity.generation, 41)
        }
    }

    func testDirectMoreDuringADrawnDraftDoesNotSupersedeItsRequest() async throws {
        let h = StreamHarness()
        await h.seed()
        let request = h.service.requestQuestion("Which milestone comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Confirm the next milestone.**"), at: 0)
        await h.wait { h.state.draft != nil }
        let draft = try XCTUnwrap(h.state.draft)

        let more = h.service.requestAction(.more)

        XCTAssertNil(more)
        XCTAssertEqual(h.state.draft, draft)
        await h.drain()
        XCTAssertEqual(h.route.users.count, 1)
        h.route.end(200, at: 0)
        await request?.value
        if more != nil {
            h.service.stop()
            await more?.value
        }
        XCTAssertEqual(h.state.answers.first?.headline, "**Confirm the next milestone.**")
    }

    func testFirstDeltaDrawsBeforeEndWithoutPublicationSideEffects() async throws {
        let h = StreamHarness()
        await h.seed()
        let cards = h.state.answers
        let boundary = await h.transcript.answeredEndSample
        let request = h.service.requestQuestion("What comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**The next step.**\n- Check the "), at: 0)
        await h.wait { h.state.draft != nil }
        let draft = try XCTUnwrap(h.state.draft)
        XCTAssertEqual(draft.kind, .answer)
        XCTAssertEqual(draft.generation, 1)
        XCTAssertEqual(draft.blocks, [.headline("**The next step.**"), .bullet("Check the")])
        XCTAssertEqual(h.state.answers, cards)
        let currentBoundary = await h.transcript.answeredEndSample
        XCTAssertEqual(currentBoundary, boundary)
        let memo = await h.transcript.memo
        XCTAssertNil(memo)
        h.route.send(.delta("deadline"), at: 0)
        h.route.send(.end(.init(status: 200, retryAfter: nil, text: nil)), at: 0)
        await request?.value
        XCTAssertNil(h.state.draft)
        XCTAssertEqual(h.state.answers.count, cards.count + 1)
        XCTAssertEqual(h.state.answers.first?.bullets, ["Check the deadline"])
        let next = h.service.requestQuestion("Is that agreed?")
        await h.waitForRequests(2)
        XCTAssertTrue(h.route.users[1].contains("The next step."))
        h.route.end(0, at: 1)
        await next?.value
    }

    func testEveryAutomaticSentinelDrawStateStaysEmpty() async {
        for width in 1...5 {
            let h = StreamHarness()
            var snapshots: [MeetingAnswerDraft?] = []
            let observer = h.state.$draft.sink { snapshots.append($0) }
            let line = themLine(text: "Which deadline should we use?", from: 0)
            await h.service.themLineEnded(line)
            await h.waitForRequests(1)
            for chunk in chunks(" **[no-answer]** extra", width: width) {
                h.route.send(.delta(chunk), at: 0)
                await h.drain()
            }
            h.route.end(200, at: 0)
            await h.wait { !h.service.isThinking }
            XCTAssertFalse(snapshots.contains { $0 != nil }, "chunk width \(width)")
            XCTAssertTrue(h.state.answers.isEmpty)
            XCTAssertNil(h.state.status)
            withExtendedLifetime(observer) {}
            h.service.stop()
        }
    }

    func testEveryReasoningDrawStateIsEmptyForOneToFiveCharacterChunks() async {
        for width in 1...5 {
            let h = StreamHarness()
            var snapshots: [MeetingAnswerDraft?] = []
            let observer = h.state.$draft.sink { snapshots.append($0) }
            let request = h.service.requestQuestion("What is the useful insight?")
            await h.waitForRequests(1)
            for chunk in chunks("We need a deep insight. They discuss the roadmap and nothing else.", width: width) {
                h.route.send(.delta(chunk), at: 0)
                await h.drain()
            }
            h.route.end(200, at: 0)
            await request?.value
            XCTAssertFalse(snapshots.contains { $0 != nil }, "chunk width \(width)")
            XCTAssertTrue(h.state.answers.isEmpty)
            XCTAssertEqual(h.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
            withExtendedLifetime(observer) {}
        }
    }

    func testActionsDrawOnlyAfterSuccessfulEnd() async {
        for action in [MeetingAnswerAction.questions, .recap, .more, .screen] {
            let h = StreamHarness()
            await h.seed()
            var snapshots: [MeetingAnswerDraft?] = []
            let observer = h.state.$draft.sink { snapshots.append($0) }
            let request = action == .screen ? h.service.requestScreen() : h.service.requestAction(action)
            await h.waitForRequests(1)
            let before = h.state.answers
            for chunk in chunks("A useful response\n- A supporting detail", width: 3) {
                h.route.send(.delta(chunk), at: 0)
                await h.drain()
            }
            XCTAssertEqual(h.state.answers, before)
            XCTAssertFalse(snapshots.contains { $0 != nil })
            h.route.end(200, at: 0)
            await request?.value
            XCTAssertEqual(h.state.answers.count, before.count + 1)
            XCTAssertEqual(h.state.answers.first?.action, action)
            XCTAssertNil(h.state.draft)
            withExtendedLifetime(observer) {}
        }
    }

    func testActionSentinelCompositionsAndJSONArraysNeverPublish() async {
        let rejected = ["[no-answer] extra", " **[no-answer]**", " \n```text\n[no-answer] extra\n```",
                        "<think>private</think> [no-answer]", "[\"not an action\"]"]
        for raw in rejected {
            let h = StreamHarness()
            await h.seed()
            let prior = h.state.answers
            let request = h.service.requestAction(.questions)
            await h.waitForRequests(1)
            for chunk in chunks(raw, width: 1) { h.route.send(.delta(chunk), at: 0) }
            h.route.end(200, at: 0)
            await request?.value
            XCTAssertEqual(h.state.answers, prior, raw)
            XCTAssertNil(h.state.draft)
        }
    }

    func testFailedTerminalWithValidPartialNeverPublishesOrChangesHistoryBoundary() async {
        for status in [500, 401, 429, 503, 408] {
            let h = StreamHarness()
            await h.seed()
            let cards = h.state.answers
            let boundary = await h.transcript.answeredEndSample
            let request = h.service.requestQuestion("What comes next?")
            await h.waitForRequests(1)
            h.route.send(.delta("**Transient answer.**"), at: 0)
            await h.wait { h.state.draft != nil }
            h.route.send(.end(.init(status: status, retryAfter: 17, text: nil)), at: 0)
            await request?.value
            XCTAssertEqual(h.state.answers, cards, "status \(status)")
            XCTAssertNil(h.state.draft)
            let after = await h.transcript.answeredEndSample
            XCTAssertEqual(after, boundary)
            if status == 401 { XCTAssertEqual(h.state.status, MeetingAnswerStatus.signInAgain) }
            if status == 503 {
                XCTAssertEqual(h.service.automaticPausedUntil, h.clock.now.addingTimeInterval(17))
                XCTAssertEqual(h.state.status, MeetingAnswerStatus.noAnswerInTime)
            }
            if status == 429 { XCTAssertNil(h.service.automaticPausedUntil) }
            let next = h.service.requestQuestion("Which answer was saved?")
            await h.waitForRequests(2)
            XCTAssertTrue(h.route.users[1].contains("Earlier accepted answer"))
            XCTAssertFalse(h.route.users[1].contains("Transient answer"))
            h.route.end(500, at: 1)
            await next?.value
            h.service.stop()
        }
    }

    func testMissingTerminalWithValidPartialPreservesPriorState() async {
        let h = StreamHarness()
        await h.seed()
        let prior = h.state.answers
        let boundary = await h.transcript.answeredEndSample
        let request = h.service.requestQuestion("What comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Incomplete transport.**"), at: 0)
        await h.wait { h.state.draft != nil }
        h.route.finish(at: 0)
        await request?.value
        XCTAssertEqual(h.state.answers, prior)
        XCTAssertNil(h.state.draft)
        let after = await h.transcript.answeredEndSample
        XCTAssertEqual(after, boundary)
        XCTAssertEqual(h.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        await h.verifyHistoryExcludes("Incomplete transport")
    }

    func testTransportExceptionAfterVisiblePartialPreservesPublicationState() async {
        let h = StreamHarness()
        await h.seed()
        let cards = h.state.answers
        let boundary = await h.transcript.answeredEndSample
        let gate = RequestGate()
        let lines = FailingCardLines(gate: gate)
        let client = ProAdviceClient(licenseKey: { "test-license" }, transport: { _ in
            throw URLError(.unsupportedURL)
        }, lineTransport: { _ in
            MeetingAnswerLineResponse(response: HTTPURLResponse(url: URL(string: "https://invalid.test")!,
                                                                 statusCode: 200, httpVersion: nil,
                                                                 headerFields: ["Content-Type": "text/event-stream"])!,
                                      nextLine: { try await lines.next() }, cancel: {})
        })
        h.routes.pro = ProAnswerRoute(client: client)
        let request = h.service.requestQuestion("What comes next?")
        await h.wait { h.state.draft != nil }
        XCTAssertEqual(h.state.draft?.blocks, [.headline("**Transport partial.**")])
        gate.open()
        await request?.value
        XCTAssertEqual(h.state.answers, cards)
        XCTAssertNil(h.state.draft)
        let after = await h.transcript.answeredEndSample
        XCTAssertEqual(after, boundary)
        XCTAssertNil(h.service.automaticPausedUntil)
        XCTAssertEqual(h.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        h.routes.pro = h.route
        let next = h.service.requestQuestion("What was saved?")
        await h.waitForRequests(1)
        XCTAssertTrue(h.route.users[0].contains("Earlier accepted answer"))
        XCTAssertFalse(h.route.users[0].contains("Transport partial"))
        h.route.end(500, at: 0)
        await next?.value
    }

    func testShortcutDraftCarriesTheHeardLineAndSixSecondDeadline() async {
        let h = StreamHarness()
        await appendThemLine(h.transcript, text: "Which deadline should we use?", from: 0)
        let request = h.service.requestShortcut()
        await h.waitForRequests(1)
        h.route.send(.delta("**Use the agreed deadline.**"), at: 0)
        await h.wait { h.state.draft != nil }
        XCTAssertEqual(h.state.draft?.heard, "Which deadline should we use?")
        XCTAssertEqual(h.route.deadlines, [6_000])
        h.route.end(200, at: 0)
        await request?.value
    }

    func testDraftCleanupRequiresBothUUIDAndGeneration() {
        let state = MeetingCoachState()
        let id = UUID()
        let draft = MeetingAnswerDraft(requestID: id, generation: 4, kind: .answer,
                                        heard: nil, blocks: [.headline("**Current answer.**")])
        state.showDraft(draft)
        state.clearDraft(requestID: id, generation: 3)
        XCTAssertEqual(state.draft, draft)
        state.clearDraft(requestID: UUID(), generation: 4)
        XCTAssertEqual(state.draft, draft)
        state.clearDraft(requestID: id, generation: 4)
        XCTAssertNil(state.draft)
        state.showDraft(draft)
        state.arm()
        XCTAssertNil(state.draft)
        state.showDraft(draft)
        state.disarm()
        XCTAssertNil(state.draft)
    }

    func testRejectedEndClearsDraftWithoutSideEffects() async {
        let h = StreamHarness()
        await h.seed()
        let cards = h.state.answers
        let boundary = await h.transcript.answeredEndSample
        let request = h.service.requestQuestion("What comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Valid beginning.**"), at: 0)
        await h.wait { h.state.draft != nil }
        h.route.send(.delta(String(repeating: "x", count: 901)), at: 0)
        h.route.end(200, at: 0)
        await request?.value
        XCTAssertNil(h.state.draft)
        XCTAssertEqual(h.state.answers, cards)
        let after = await h.transcript.answeredEndSample
        XCTAssertEqual(after, boundary)
        await h.verifyHistoryExcludes("Valid beginning")
    }

    func testOwnDeadlinePublishesValidPartialAndCancelsStream() async {
        let h = StreamHarness()
        let request = h.service.requestQuestion("What comes next?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Use the completed partial.**"), at: 0)
        await h.wait { h.state.draft != nil }
        h.deadline.fire()
        await request?.value
        XCTAssertEqual(h.state.answers.first?.headline, "**Use the completed partial.**")
        XCTAssertNil(h.state.draft)
        XCTAssertFalse(h.token.isCancelled)
        await h.wait { h.route.terminated.contains(0) }
        XCTAssertTrue(h.route.terminated.contains(0))
    }

    func testOwnDeadlineRejectsInvalidPartialWithShortcutStatus() async {
        let h = StreamHarness()
        await appendThemLine(h.transcript, text: "What comes next?", from: 0)
        let request = h.service.requestShortcut()
        await h.waitForRequests(1)
        h.route.send(.delta("**Unfinished"), at: 0)
        await h.drain()
        h.deadline.fire()
        await request?.value
        XCTAssertTrue(h.state.answers.isEmpty)
        XCTAssertNil(h.state.draft)
        XCTAssertEqual(h.state.status, MeetingAnswerStatus.noAnswerInTime)
    }

    func testDoneRacingDeadlinePublishesAtMostOnceInBothOrders() async {
        for doneFirst in [true, false] {
            let h = StreamHarness()
            let request = h.service.requestQuestion("What comes next?")
            await h.waitForRequests(1)
            h.route.send(.delta("**One accepted answer.**"), at: 0)
            await h.wait { h.state.draft != nil }
            if doneFirst { h.route.end(200, at: 0); h.deadline.fire() }
            else { h.deadline.fire(); h.route.end(200, at: 0) }
            await request?.value
            await h.drain()
            XCTAssertEqual(h.state.answers.count, 1)
            XCTAssertNil(h.state.draft)
        }
    }

    func testSupersededBufferedEndCannotClearNewDraftOrChangeStatusBackoff() async throws {
        let h = StreamHarness()
        let first = h.service.requestQuestion("First question?")
        await h.waitForRequests(1)
        h.route.send(.delta("**Old draft.**"), at: 0)
        await h.wait { h.state.draft != nil }
        let oldID = try XCTUnwrap(h.state.draft?.requestID)
        h.route.send(.delta("Buffered before supersession"), at: 0)
        h.route.send(.end(.init(status: 503, retryAfter: 100, text: nil)), at: 0)
        let second = h.service.requestQuestion("Second question?")
        await h.waitForRequests(2)
        h.route.send(.delta("**Current draft.**"), at: 1)
        await h.wait { h.state.draft?.requestID != oldID && h.state.draft != nil }
        let current = h.state.draft
        h.state.setStatus("Current request status")
        h.route.send(.delta("old buffered content"), at: 0)
        h.route.send(.end(.init(status: 503, retryAfter: 100, text: nil)), at: 0)
        await first?.value
        await h.drain()
        XCTAssertEqual(h.state.draft, current)
        XCTAssertEqual(h.state.status, "Current request status")
        XCTAssertNil(h.service.automaticPausedUntil)
        h.route.end(200, at: 1)
        await second?.value
        XCTAssertEqual(h.state.answers.count, 1)
    }

    func testStopThenImmediateNewMeetingCannotConsumeOldBufferedEvents() async throws {
        var generation = 1
        let state = MeetingCoachState()
        let old = StreamHarness(state: state, generation: { generation })
        let request = old.service.requestQuestion("Old question?")
        await old.waitForRequests(1)
        old.route.send(.delta("**Old draft.**"), at: 0)
        await old.wait { state.draft != nil }
        let oldDraft = try XCTUnwrap(state.draft)
        old.route.send(.delta("Buffered before restart"), at: 0)
        old.route.send(.end(.init(status: 503, retryAfter: 100, text: nil)), at: 0)
        old.service.stop()
        old.token.stop()
        generation = 2
        state.arm()
        let fresh = StreamHarness(state: state, generation: { generation })
        let next = fresh.service.requestQuestion("Current question?")
        await fresh.waitForRequests(1)
        fresh.route.send(.delta("**Current draft.**"), at: 0)
        await fresh.wait { state.draft != nil }
        let current = try XCTUnwrap(state.draft)
        XCTAssertNotEqual(current.requestID, oldDraft.requestID)
        XCTAssertEqual(current.generation, 2)
        state.setStatus("New meeting status")
        old.route.send(.delta("buffered old text"), at: 0)
        old.route.send(.end(.init(status: 503, retryAfter: 100, text: nil)), at: 0)
        state.clearDraft(requestID: oldDraft.requestID, generation: oldDraft.generation)
        await request?.value
        await old.drain()
        XCTAssertEqual(state.draft, current)
        XCTAssertEqual(state.status, "New meeting status")
        XCTAssertNil(fresh.service.automaticPausedUntil)
        fresh.route.end(200, at: 0)
        await next?.value
        XCTAssertEqual(state.answers.count, 1)
    }

    func testContinuationSupersedesAutomaticDraftAndCancelsItsStream() async {
        let h = StreamHarness()
        await h.service.themLineEnded(themLine(text: "Which deadline?", from: 0))
        await h.waitForRequests(1)
        h.route.send(.delta("**Old automatic.**"), at: 0)
        await h.wait { h.state.draft != nil }
        await h.service.themLineEnded(themLine(text: "Which deadline and owner?", from: 0))
        await h.waitForRequests(2)
        h.route.send(.delta("**New automatic.**"), at: 1)
        h.route.end(200, at: 1)
        h.route.end(500, at: 0)
        await h.wait { h.state.answers.count == 1 }
        XCTAssertEqual(h.state.answers.first?.headline, "**New automatic.**")
        XCTAssertNil(h.state.draft)
        await h.wait { h.route.terminated.contains(0) }
        XCTAssertTrue(h.route.terminated.contains(0))
        h.service.stop()
    }

    func testTokenAndCallerCancellationClearDraftWithoutPublication() async {
        for tokenStop in [false, true] {
            let h = StreamHarness()
            let request = h.service.requestQuestion("What comes next?")
            await h.waitForRequests(1)
            h.route.send(.delta("**Cancelled draft.**"), at: 0)
            await h.wait { h.state.draft != nil }
            if tokenStop { h.token.stop() } else { request?.cancel() }
            await request?.value
            h.route.end(200, at: 0)
            await h.drain()
            XCTAssertTrue(h.state.answers.isEmpty)
            XCTAssertNil(h.state.draft)
            XCTAssertNil(h.state.status)
            XCTAssertNil(h.service.automaticPausedUntil)
        }
    }

    func testCardDeadlinesAndMemoKeepTheirSeparateAPIs() async {
        let h = StreamHarness()
        await h.seed()
        for action in [MeetingAnswerAction.questions, .recap, .more, .screen] {
            h.clock.advance(by: 2)
            let task = action == .screen ? h.service.requestScreen() : h.service.requestAction(action)
            let index = h.route.users.count
            await h.waitForRequests(index + 1)
            XCTAssertEqual(h.route.deadlines[index], 10_000)
            h.route.end(500, at: index)
            await task?.value
        }
        let question = h.service.requestQuestion("Typed question?")
        await h.waitForRequests(5)
        XCTAssertEqual(h.route.deadlines[4], 6_000)
        h.route.end(500, at: 4)
        await question?.value
        await h.service.themLineEnded(themLine(text: "Automatic question?", from: 64_000))
        await h.waitForRequests(6)
        XCTAssertEqual(h.route.deadlines[5], 8_000)
        h.route.end(500, at: 5)
        await h.wait { !h.service.isThinking }
        _ = await h.routes.makeMemoProvider()(nil, [themLine(text: "Meeting detail", from: 0)], h.token)
        XCTAssertEqual(h.route.answerCalls, 1)
        XCTAssertEqual(h.route.users.count, 6)
        h.service.stop()
    }

    func testNoRouteHasNoDraftAndKeepsExistingStatusMapping() async {
        let h = StreamHarness()
        h.route.isAvailable = false
        await h.service.requestQuestion("What comes next?")?.value
        XCTAssertNil(h.state.draft)
        XCTAssertEqual(h.state.status, MeetingAnswerStatus.noRoute)
    }

    private func chunks(_ text: String, width: Int) -> [String] {
        var rest = text[...]
        var result: [String] = []
        while !rest.isEmpty { result.append(String(rest.prefix(width))); rest = rest.dropFirst(width) }
        return result
    }
}

@MainActor
private final class ControlledCardRoute: MeetingAnswerRoute {
    let routeName = "fake-stream"
    var isAvailable = true
    var users: [String] = []
    var deadlines: [Int] = []
    var answerCalls = 0
    var terminated: Set<Int> = []
    private var continuations: [AsyncStream<MeetingAnswerStreamEvent>.Continuation] = []

    func answer(system: String, user: String, deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        answerCalls += 1
        return .init(status: 200, retryAfter: nil, text: "{\"topic\":\"\",\"context\":\"\",\"questions\":[]}")
    }

    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        let index = users.count
        users.append(user)
        deadlines.append(deadlineMs)
        return AsyncStream { continuation in
            continuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.terminated.insert(index) }
            }
        }
    }

    func send(_ event: MeetingAnswerStreamEvent, at index: Int) { continuations[index].yield(event) }
    func end(_ status: Int, at index: Int) {
        send(.end(.init(status: status, retryAfter: nil, text: nil)), at: index)
    }
    func finish(at index: Int) { continuations[index].finish() }
}

@MainActor
private final class ControlledCardDeadline {
    private var pending: [AsyncStream<Void>.Continuation] = []
    func sleep(_ milliseconds: Int) async throws {
        let stream = AsyncStream<Void> { pending.append($0) }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func fire() { for continuation in pending { continuation.yield(()); continuation.finish() } }
}

@MainActor
private final class StreamHarness {
    let state: MeetingCoachState
    let transcript = LiveMeetingTranscript()
    let routes = MeetingAnswerRoutes()
    let route = ControlledCardRoute()
    let clock = FakeClock()
    let token = LiveHintsStopToken()
    let deadline = ControlledCardDeadline()
    let service: MeetingAnswerService

    init(state: MeetingCoachState? = nil, generation: @escaping @MainActor () -> Int = { 1 }) {
        self.state = state ?? MeetingCoachState()
        self.state.arm(generation: generation())
        self.state.autoAnswerOn = true
        routes.pro = route
        service = MeetingAnswerService(transcript: transcript, routes: routes, clock: { [clock] in clock.now },
                                       isAutoOn: { true }, generation: generation, state: self.state,
                                       stopToken: token, screenEnabled: { true }, captureScreen: { "Screen task" },
                                       streamSleep: { [deadline] in try await deadline.sleep($0) })
    }

    func seed() async {
        await appendThemLine(transcript, text: "Earlier question about delivery?", from: 0)
        await service.publish(.init(id: UUID(), heard: "Earlier question", kind: .answer,
                                    provenance: .transcript, action: nil,
                                    blocks: [.headline("**Earlier accepted answer.**")], createdAt: clock.now),
                              heard: .init(text: "Earlier question", endSample: 16_000), boundary: 16_000)
    }
    func verifyHistoryExcludes(_ text: String) async {
        let index = route.users.count
        let next = service.requestQuestion("Which answer was saved?")
        await waitForRequests(index + 1)
        XCTAssertTrue(route.users[index].contains("Earlier accepted answer"))
        XCTAssertFalse(route.users[index].contains(text))
        route.end(500, at: index)
        await next?.value
    }
    func waitForRequests(_ count: Int) async { await wait { self.route.users.count >= count } }
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }
    func drain() async { for _ in 0..<5 { await Task.yield() } }
}

private actor FailingCardLines {
    let gate: RequestGate
    private var first = true
    init(gate: RequestGate) { self.gate = gate }
    func next() async throws -> String? {
        if first {
            first = false
            return "data: {\"delta\":\"**Transport partial.**\"}"
        }
        await gate.wait()
        throw URLError(.networkConnectionLost)
    }
}
