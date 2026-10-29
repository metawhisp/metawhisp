import XCTest
@testable import MetaWhisp

/// The two cancellation scopes, the identity of a request, the kinds of an
/// answer and the rule that the transcript is content (§3.0).
///
/// The session's token stops everything when the meeting ends. Every request
/// has its own handle beside it: one request can be called off without the
/// meeting's work — the speech recognition, the batches, the memo, the manual
/// answers — stopping with it.
@MainActor
final class MeetingAnswerScopeTests: XCTestCase {

    // MARK: - The handle

    /// The handle cancels the task of its request and invalidates its id.
    func testTheHandleCancelsTheTaskOfItsRequestAndInvalidatesIt() {
        let handle = LiveHintsRequestHandle()
        var wasCancelled = false
        handle.attach { wasCancelled = true }

        XCTAssertFalse(handle.isCancelled, "a fresh handle is cancelled")
        XCTAssertFalse(wasCancelled, "the task of a fresh request was cancelled")

        handle.cancel()

        XCTAssertTrue(handle.isCancelled, "the handle did not invalidate its id")
        XCTAssertTrue(wasCancelled, "the handle did not cancel the task of its request")
    }

    /// A task that is given to a handle that is already cancelled is
    /// cancelled at once: it must not go on after the request was called off.
    func testATaskThatIsGivenToACancelledHandleIsCancelledAtOnce() {
        let handle = LiveHintsRequestHandle()
        handle.cancel()
        var wasCancelled = false

        handle.attach { wasCancelled = true }

        XCTAssertTrue(wasCancelled, "the task of a called-off request went on")
    }

    /// Cancelling a request does not stop the session: the manual answers,
    /// the speech recognition, the batches and the memo keep running.
    func testCancellingARequestDoesNotStopTheSession() {
        let token = LiveHintsStopToken()
        var wasSessionCancelled = false
        token.retain { wasSessionCancelled = true }

        let handle = LiveHintsRequestHandle()
        handle.cancel()

        XCTAssertFalse(token.isCancelled, "the session was stopped by one request")
        XCTAssertFalse(wasSessionCancelled, "the session's work was stopped by one request")
    }

    // MARK: - The identity

    /// The generation is taken when the user acts — before the request waits
    /// for anything. A meeting that ended while the request waited owns no
    /// answer.
    func testTheGenerationIsTakenWhenTheUserActsAndNotAfterTheWait() async {
        var generation = 1
        let pendingGate = RequestGate()
        let harness = makeAnswerHarness(
            pendingThemText: { await pendingGate.wait(); return nil },
            generation: { generation })
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitUntil { pendingGate.waiterCount > 0 }

        // The meeting ended while the request waited for the line.
        generation = 2
        pendingGate.open()
        await press.value
        await harness.settle()

        XCTAssertEqual(harness.requestCount, 0,
                       "the request went out with the generation of the meeting that came after it")
    }

    func testTheShortcutCapturesItsGenerationBeforeItsTaskStarts() async {
        var generation = 1
        let harness = makeAnswerHarness(generation: { generation })
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        let request = harness.service.requestShortcut()
        generation = 2
        await request?.value

        XCTAssertNotNil(request)
        XCTAssertEqual(harness.requestCount, 0,
                       "the scheduled task captured a later recording generation")
        XCTAssertTrue(harness.state.answers.isEmpty)
        XCTAssertNil(harness.state.status)
    }

    /// A new user request calls off the one that is running: its task ends,
    /// and its result never reaches the card.
    func testANewUserRequestCallsOffTheOneThatIsRunning() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The first answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The second answer.**"),
        ]
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        let first = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        // The user acts again: the first request is called off.
        harness.clock.advance(by: 1.1)
        let second = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(2)

        harness.latch.open()
        await first.value
        await second.value
        await harness.waitUntilIdle()

        await harness.waitUntil { harness.pro.requests[0].wasCancelled }
        XCTAssertTrue(harness.pro.requests[0].wasCancelled,
                      "the first request went on after the second one started")
        XCTAssertEqual(harness.service.answers.count, 1)
        XCTAssertEqual(harness.service.answers.first?.headline, "**The second answer.**",
                       "the called-off request reached the card")
    }

    /// A press supersedes the automatic check that is running: its result is
    /// thrown away.
    func testAPressSupersedesTheAutomaticCheckThatIsRunning() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The automatic answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The shortcut answer.**"),
        ]
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)

        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(2)

        harness.latch.open()
        await press.value
        await harness.waitUntilIdle()

        await harness.waitUntil { harness.pro.requests[0].wasCancelled }
        XCTAssertTrue(harness.pro.requests[0].wasCancelled,
                      "the superseded automatic request was not cancelled by its handle")
        XCTAssertEqual(harness.service.answers.count, 1)
        XCTAssertEqual(harness.service.answers.first?.headline, "**The shortcut answer.**",
                       "the superseded automatic check reached the card")
    }

    func testAutomaticOffCancelsItsRequestAndLeavesManualAnswersAvailable() async throws {
        var automaticIsOn = true
        let token = LiveHintsStopToken()
        var sessionWorkWasCancelled = false
        token.retain { sessionWorkWasCancelled = true }
        let harness = makeAnswerHarness(isAutoOn: { automaticIsOn }, stopToken: token)
        let automaticGate = RequestGate()
        harness.pro.gate = { await automaticGate.wait() }
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The automatic answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The manual answer.**"),
        ]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)

        automaticIsOn = false
        harness.service.automaticTurnedOff()
        automaticGate.open()
        await harness.waitUntilIdle()

        await harness.waitUntil { harness.pro.requests.first?.wasCancelled == true }
        XCTAssertTrue(try XCTUnwrap(harness.pro.requests.first).wasCancelled)
        XCTAssertFalse(token.isCancelled)
        XCTAssertFalse(sessionWorkWasCancelled)
        XCTAssertTrue(harness.service.answers.isEmpty)

        harness.pro.gate = nil
        await harness.service.shortcutPressed()

        XCTAssertEqual(harness.requestCount, 2)
        XCTAssertEqual(harness.service.answers.map(\.headline), ["**The manual answer.**"])
        XCTAssertFalse(token.isCancelled)
    }

    func testAnOldRequestFinishingCannotClearTheNewMeetingsThinkingState() async {
        let oldToken = LiveHintsStopToken()
        let old = makeAnswerHarness(stopToken: oldToken)
        let oldGate = RequestGate()
        old.pro.gate = { await oldGate.wait() }
        old.pro.replies = [MeetingAnswerReply(status: 200, retryAfter: nil,
                                              text: "**The old answer.**")]
        await appendThemLine(old.transcript, text: "shall we ship on Friday?", from: 0)
        let oldRequest = old.service.requestShortcut()
        await old.waitForRequests(1)

        oldToken.stop()
        old.service.stop()
        old.state.disarm()

        let current = makeAnswerHarness(generation: { 2 })
        let currentGate = RequestGate()
        current.pro.gate = { await currentGate.wait() }
        current.pro.replies = [MeetingAnswerReply(status: 200, retryAfter: nil,
                                                  text: "**The current answer.**")]
        await appendThemLine(current.transcript, text: "what is the delivery date?", from: 0)
        let currentService = MeetingAnswerService(transcript: current.transcript,
                                                  routes: current.routes,
                                                  clock: { current.clock.now },
                                                  generation: { 2 },
                                                  state: old.state)
        old.state.arm()
        let currentRequest = currentService.requestShortcut()
        await current.waitForRequests(1)
        XCTAssertTrue(old.state.isThinking)

        oldGate.open()
        await oldRequest?.value

        XCTAssertTrue(old.state.isThinking,
                      "the old request changed the thinking state of the current meeting")
        XCTAssertTrue(old.state.answers.isEmpty)
        XCTAssertNil(old.state.status)

        currentGate.open()
        await currentRequest?.value
        XCTAssertFalse(old.state.isThinking)
        XCTAssertEqual(old.state.answers.map(\.headline), ["**The current answer.**"])
    }

    /// No automatic check starts while a user request runs: the press owns
    /// the card until it is done.
    func testNoAutomaticCheckStartsWhileAUserRequestRuns() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        // The other side asks something while the user's request runs.
        await harness.service.themLineEnded(themLine(text: "and the budget?", from: 32_000))
        await harness.settle(0.4)

        XCTAssertEqual(harness.requestCount, 1,
                       "an automatic check started beside the user's request")

        harness.latch.open()
        await press.value
        await harness.waitUntilIdle()

        // The line that waited is checked now that the user's request is done.
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
        await harness.waitForRequests(2)
        XCTAssertEqual(harness.requestCount, 2,
                       "the line that waited was not checked after the user's request")
    }

    // MARK: - The kinds of an answer

    /// A plain answer joins the history and advances the answered boundary.
    func testAPlainAnswerJoinsTheHistoryAndAdvancesTheAnsweredBoundary() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        let answered = await harness.transcript.answeredEndSample
        XCTAssertNotNil(answered, "the answer did not mark the transcript it used")

        // The next request carries the answer in its history.
        harness.clock.advance(by: 1.1)
        await harness.service.shortcutPressed()
        await harness.waitForRequests(2)
        XCTAssertTrue(harness.pro.requests[1].user.contains("[Answered] **The answer.**"),
                      "the plain answer did not join the history")
    }

    /// An answer about the screen never joins the history: it reaches no
    /// later request.
    func testAnAnswerAboutTheScreenNeverJoinsTheHistory() async throws {
        for kind in [MeetingAnswerKind.answer, .action] {
            let harness = makeAnswerHarness()
            await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
            await harness.service.publish(MeetingAnswer(id: UUID(),
                                                        heard: nil,
                                                        kind: kind,
                                                        provenance: .screen,
                                                        action: kind == .action ? .screen : nil,
                                                        blocks: [.headline("**The screen answer.**")],
                                                        createdAt: harness.clock.now),
                                          heard: nil,
                                          boundary: 16_000)

            let answered = await harness.transcript.answeredEndSample
            XCTAssertNil(answered, "the screen answer advanced the answered boundary")
            XCTAssertEqual(harness.service.answers.count, 1)
            XCTAssertFalse(try XCTUnwrap(harness.service.answers.first).mayBeExpanded)

            await harness.service.shortcutPressed()

            let request = try XCTUnwrap(harness.pro.requests.first)
            XCTAssertFalse(request.user.contains("The screen answer."),
                           "the screen answer reached a later request")
        }
    }

    /// An action never joins the history and never advances the answered
    /// boundary: the table of §3.0.
    func testAnActionNeverJoinsTheHistoryAndNeverAdvancesTheBoundary() async throws {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.publish(MeetingAnswer(id: UUID(),
                                                    heard: nil,
                                                    kind: .action,
                                                    provenance: .transcript,
                                                    action: .questions,
                                                    blocks: [.paragraph("What is the deadline?")],
                                                    createdAt: harness.clock.now),
                                      heard: nil,
                                      boundary: 16_000)

        let answered = await harness.transcript.answeredEndSample
        XCTAssertNil(answered, "the action advanced the answered boundary")

        await harness.service.shortcutPressed()

        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertFalse(request.user.contains("What is the deadline?"),
                       "the action reached a later request")
    }

    /// The table of §3.0 says what the *More* button may expand.
    func testTheTableSaysWhatMoreMayExpand() {
        func answer(kind: MeetingAnswerKind,
                    provenance: MeetingAnswerProvenance,
                    action: MeetingAnswerAction?) -> MeetingAnswer {
            MeetingAnswer(id: UUID(),
                          heard: nil,
                          kind: kind,
                          provenance: provenance,
                          action: action,
                          blocks: [],
                          createdAt: Date())
        }

        XCTAssertTrue(answer(kind: .answer, provenance: .transcript, action: nil).mayBeExpanded,
                      "a plain answer may not be expanded")
        XCTAssertTrue(answer(kind: .action, provenance: .transcript, action: .questions).mayBeExpanded,
                      "the questions may not be expanded")
        XCTAssertTrue(answer(kind: .action, provenance: .transcript, action: .more).mayBeExpanded,
                      "the more may not be expanded")
        XCTAssertFalse(answer(kind: .action, provenance: .transcript, action: .recap).mayBeExpanded,
                       "the recap may be expanded")
        XCTAssertFalse(answer(kind: .action, provenance: .screen, action: .screen).mayBeExpanded,
                       "the answer about the screen may be expanded")
        XCTAssertFalse(answer(kind: .answer, provenance: .screen, action: nil).mayBeExpanded,
                       "an ordinary screen answer may be expanded")
    }

    func testAnswerAndActionKindsChangeNextRequestHistory() async throws {
        let displayedText = "What is the delivery deadline?"
        for kind in [MeetingAnswerKind.answer, .action] {
            let harness = makeAnswerHarness()
            await appendThemLine(harness.transcript, text: "We are planning delivery.", from: 0)
            let card = MeetingAnswer(
                id: UUID(), heard: nil, kind: kind, provenance: .transcript,
                action: kind == .action ? .questions : nil,
                blocks: [kind == .answer ? .headline(displayedText) : .paragraph(displayedText)],
                createdAt: harness.clock.now)
            await harness.service.publish(card, heard: nil, boundary: 16_000)

            XCTAssertEqual(harness.state.answers, [card])
            XCTAssertTrue(try XCTUnwrap(harness.state.answers.first).mayBeExpanded)
            XCTAssertTrue(harness.state.canExpandLatest,
                          "the Questions card must stay eligible for More")

            await harness.service.shortcutPressed()

            let request = try XCTUnwrap(harness.pro.requests.first)
            let expectedHistoryCount = kind == .answer ? 1 : 0
            XCTAssertEqual(request.user.components(separatedBy: "[Answered] ").count - 1,
                           expectedHistoryCount)
            XCTAssertEqual(request.user.contains("[Answered] " + displayedText), kind == .answer)
            if kind == .action {
                XCTAssertFalse(request.user.contains(displayedText),
                               "the Questions card leaked into the following request")
            }
        }
    }

    /// The blocks of a plain answer are the headline and the catch points, in
    /// that order: the card draws the same thing as before.
    func testTheBlocksOfAPlainAnswerAreTheHeadlineAndTheCatchPoints() {
        let text = MeetingAnswerText(headline: "**We should ship on Friday.**",
                                     bullets: ["The freeze starts on Monday"])

        XCTAssertEqual(text.blocks,
                       [.headline("**We should ship on Friday.**"),
                        .bullet("The freeze starts on Monday")])
    }
}
