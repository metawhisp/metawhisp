import XCTest
@testable import MetaWhisp

/// The triggers and the concurrency of the answer service (T8, T9).
///
/// The shortcut answers at once, even beside an automatic check; the automatic
/// check runs alone, and the lines that arrive meanwhile wait for it. Only the
/// newest result is shown.
@MainActor
final class MeetingAnswerServiceTests: XCTestCase {

    // MARK: - The triggers

    /// With the automatic answers off, a line of the other side calls nobody.
    func testWithTheAutomaticAnswersOffALineCallsNobody() async {
        let harness = makeAnswerHarness(isAutoOn: { false })
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.settle()

        XCTAssertEqual(harness.requestCount, 0, "a model was called although the automatic answers are off")
    }

    /// A line with fewer than four letters or digits calls nobody.
    func testALineWithFewerThanFourLettersCallsNobody() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "ok", from: 0)

        await harness.service.themLineEnded(themLine(text: "ok", from: 0))
        await harness.settle()

        XCTAssertEqual(harness.requestCount, 0, "a model was called for a line of two letters")
    }

    /// A line of the other side is checked with the gated ask.
    func testALineOfTheOtherSideIsCheckedWithTheGatedAsk() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        let request = harness.pro.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.user.contains("If this asks the user something"),
                      "the automatic check did not use the gated ask")
        XCTAssertTrue(request!.user.contains("Heard in the meeting: \"shall we ship on Friday?\""),
                      "the gated ask did not quote the line")
        XCTAssertEqual(request!.deadlineMs, MeetingAnswerService.automaticDeadlineMs)
    }

    /// The shortcut answers the line of the other side when it is unanswered.
    func testTheShortcutAnswersTheLineWhenItIsUnanswered() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        let request = harness.pro.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.user.contains("The user wants an answer to this:"),
                      "the shortcut did not use the forced ask")
        XCTAssertEqual(request!.deadlineMs, MeetingAnswerService.shortcutDeadlineMs)
    }

    /// The user's own speech of a second and a half answers the line, so the
    /// shortcut asks what to say next.
    func testTheUsersOwnSpeechAnswersTheLineSoTheShortcutAsksWhatToSayNext() async {
        let harness = makeAnswerHarness(meSpeechSeconds: { _ in 2.0 })
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        let request = harness.pro.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.user.contains(MeetingAnswerPrompts.whatShouldISayPrompt),
                      "the shortcut did not ask what to say next")
        XCTAssertFalse(request!.user.contains("The user wants an answer to this:"),
                       "the shortcut answered a line that was already answered")
    }

    /// An empty transcript gives the status and calls nobody.
    func testAnEmptyTranscriptGivesTheStatusAndCallsNobody() async {
        let harness = makeAnswerHarness()

        await harness.service.shortcutPressed()
        await harness.settle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.nothingHeard)
        XCTAssertEqual(harness.requestCount, 0, "a model was called although nothing was heard")
    }

    /// A shortcut press that repeats within a second is ignored.
    func testAShortcutPressThatRepeatsWithinASecondIsIgnored() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 1, "the repeated press called the model again")
    }

    /// A shortcut press after a second is a new request.
    func testAShortcutPressAfterASecondIsANewRequest() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        harness.clock.advance(by: 1.1)
        await harness.service.shortcutPressed()
        await harness.waitForRequests(2)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 2)
    }

    // MARK: - The switch

    /// One automatic check at a time: the line that waits does not start
    /// while another check is running, and the running check keeps its
    /// result (§3.4).
    func testOnlyOneAutomaticCheckRunsAtATime() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [
            MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The first answer.**"),
            MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The joined answer.**"),
            MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The third answer.**"),
        ]
        let gates = GateQueue()
        let gateA = RequestGate()
        let gateB = RequestGate()
        let gateC = RequestGate()
        gates.add(gateA)
        gates.add(gateB)
        gates.add(gateC)
        harness.pro.gate = { [gates] in await gates.next()?.wait() }

        // The first question starts a check at t=0.
        await appendThemLine(harness.transcript, text: "shall we ship", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship", from: 0))
        await harness.waitForRequests(1)

        // At t=1 the other side goes on: the check is superseded and the
        // joined line is checked at once.
        harness.clock.advance(by: 1)
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0, isContinuation: true)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(2)

        // At t=2 an unrelated question arrives: it waits for the check.
        harness.clock.advance(by: 1)
        await appendThemLine(harness.transcript, text: "what about the budget?", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "what about the budget?", from: 32_000))

        // At t=7 the superseded check comes back. The waiting line must not
        // start: the second check runs until t=9.
        harness.clock.advance(by: 5)
        gateA.open()
        await harness.settle(0.4)

        XCTAssertEqual(harness.requestCount, 2, "a third check started while another one was running")

        // At t=9 the second check comes back: its result is not thrown away.
        gateB.open()
        await harness.waitUntil { harness.service.answers.count >= 1 }

        XCTAssertEqual(harness.service.answers.count, 1,
                       "the running check's result was thrown away")
        XCTAssertEqual(harness.service.answers.first?.headline, "**The joined answer.**",
                       "the running check's result was thrown away")
    }

    /// A line that waits for the spacing is not checked after the automatic
    /// answers were turned off (§6.16).
    func testALineThatWaitsIsNotCheckedAfterTheAutomaticAnswersAreTurnedOff() async {
        let auto = LiveValueBox(true)
        let harness = makeAnswerHarness(isAutoOn: { auto.value })
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "the first question", from: 0)
        await harness.service.themLineEnded(themLine(text: "the first question", from: 0))
        await harness.waitForRequests(1)

        // A second line arrives while the first check runs: it waits.
        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "the second question", from: 32_000))

        // The user turns the automatic answers off, and the spacing passes
        // while the first check is still running.
        auto.value = false
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)

        harness.latch.open()
        await harness.waitUntilIdle()
        await harness.settle(0.6)

        XCTAssertEqual(harness.requestCount, 1,
                       "the waiting line was checked although the automatic answers are off")

        // The automatic answers come back: the line that was waiting went
        // away with the switch, so it is not checked now either (§6.16).
        auto.value = true
        await harness.settle(0.6)

        XCTAssertEqual(harness.requestCount, 1,
                       "the line that waited came back with the switch")
    }

    /// The automatic answers go off and come back while a check runs: the
    /// line that waited goes away with the switch (§6.16).
    func testALineThatWaitsGoesAwayWhenTheAutomaticAnswersAreTurnedOffAndOnAgain() async {
        let auto = LiveValueBox(true)
        let harness = makeAnswerHarness(isAutoOn: { auto.value })
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "the first question", from: 0)
        await harness.service.themLineEnded(themLine(text: "the first question", from: 0))
        await harness.waitForRequests(1)

        // A second line arrives while the first check runs: it waits.
        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "the second question", from: 32_000))

        // The switch goes off, and it comes back before the check is over:
        // the switch must still be seen.
        auto.value = false
        harness.service.automaticTurnedOff()
        auto.value = true
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)

        harness.latch.open()
        await harness.waitUntilIdle()
        await harness.settle(0.6)

        XCTAssertEqual(harness.requestCount, 1,
                       "the waiting line was checked although the automatic answers went off")
    }

    // MARK: - The concurrency

    /// The shortcut runs at once beside an automatic check, and the check's
    /// late result is thrown away.
    func testTheShortcutRunsBesideAnAutomaticCheckAndTheLateResultIsThrownAway() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The automatic answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The shortcut answer.**"),
        ]
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)

        let shortcut = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(2)

        harness.latch.open()
        await shortcut.value
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1)
        XCTAssertEqual(harness.service.answers.first?.headline, "**The shortcut answer.**",
                       "the late result of the automatic check was published")
    }

    /// A continuation supersedes the running check, and the joined line is
    /// checked on its own.
    func testAContinuationSupersedesTheRunningCheckAndTheJoinedLineIsChecked() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The first answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The joined answer.**"),
        ]
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "shall we ship", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship", from: 0))
        await harness.waitForRequests(1)

        // The other side went on: the same utterance, longer.
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0, isContinuation: true)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(2)

        harness.latch.open()
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1)
        XCTAssertEqual(harness.service.answers.first?.headline, "**The joined answer.**",
                       "the superseded check was published")
        XCTAssertTrue(harness.pro.requests[1].user.contains("shall we ship on Friday?"),
                      "the joined line was not the one that was checked")
    }

    /// The lines that arrive while a check runs wait for it.
    func testTheLinesThatArriveWhileACheckRunsWaitForIt() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "the first question", from: 0)
        await harness.service.themLineEnded(themLine(text: "the first question", from: 0))
        await harness.waitForRequests(1)

        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "the second question", from: 32_000))

        harness.latch.open()
        await harness.waitUntilIdle()

        // The second line waited for the first check; the spacing then held it
        // back until the clock moved on.
        XCTAssertEqual(harness.requestCount, 1)
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
        await harness.waitForRequests(2)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 2)
        XCTAssertTrue(harness.pro.requests[1].user.contains("the second question"),
                      "the waiting line was not the one that was checked")
    }

    /// The service is stopped while a line waits for a check: the line goes
    /// away with the meeting, and it is never checked (§6.15).
    func testTheStoppedServiceDropsTheLineThatWasWaitingForACheck() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "the first question", from: 0)
        await harness.service.themLineEnded(themLine(text: "the first question", from: 0))
        await harness.waitForRequests(1)

        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "the second question", from: 32_000))

        // The meeting ends: the waiting line goes away with it.
        harness.service.stop()
        harness.latch.open()
        await harness.waitUntilIdle()
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
        await harness.settle(0.5)

        XCTAssertEqual(harness.requestCount, 1,
                       "the stopped service answered the line that was waiting")
    }

    /// The service is stopped while an answer is on its way: the answer
    /// belongs to a meeting that is over, so it is not published (§6.15).
    func testTheStoppedServiceDoesNotPublishTheAnswerThatComesBack() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "a question", from: 0)

        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        harness.service.stop()
        harness.latch.open()
        await press.value
        await harness.waitUntilIdle()

        XCTAssertTrue(harness.service.answers.isEmpty,
                      "the stopped service published an answer")
    }

    /// Only the newest result is shown.
    func testOnlyTheNewestResultIsShown() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The first answer.**"),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The second answer.**"),
        ]
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        let first = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        harness.clock.advance(by: 1.1)
        let second = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(2)

        harness.latch.open()
        await first.value
        await second.value
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1)
        XCTAssertEqual(harness.service.answers.first?.headline, "**The second answer.**",
                       "the older result was published")
    }

    /// The answers are kept newest first, and at most three of them.
    func testTheAnswersAreKeptNewestFirstAndAtMostThree() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        for index in 0..<5 {
            harness.pro.replies = [MeetingAnswerReply(status: 200,
                                                      retryAfter: nil,
                                                      text: "**Answer \(index).**")]
            await harness.service.shortcutPressed()
            await harness.waitUntilIdle()
            harness.clock.advance(by: 1.1)
        }

        XCTAssertEqual(harness.service.answers.count, 3)
        XCTAssertEqual(harness.service.answers.first?.headline, "**Answer 4.**")
        XCTAssertEqual(harness.service.answers.last?.headline, "**Answer 2.**")
    }

    // MARK: - The status lines

    /// A shortcut that got no answer in time says so.
    func testAShortcutThatGotNoAnswerInTimeSaysSo() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [MeetingAnswerReply(status: 408, retryAfter: nil, text: nil)]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.noAnswerInTime)
    }

    /// A shortcut whose answer was malformed says it could not get one.
    func testAShortcutWhoseAnswerWasMalformedSaysItCouldNotGetOne() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [MeetingAnswerReply(status: 200, retryAfter: nil, text: "{\"answer\": 1}")]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.couldNotGetAnAnswer)
    }

    // MARK: - The status lines

    /// An answer takes the line away that said nothing was heard.
    func testAnAnswerTakesTheLineAwayThatNothingWasHeard() async {
        let harness = makeAnswerHarness()
        await harness.service.shortcutPressed()
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.nothingHeard)

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1, "no answer was published")
        XCTAssertNil(harness.service.status,
                     "the line that nothing was heard stayed under the answer")
    }

    /// An answer takes the line away that the shortcut could not answer.
    func testAnAnswerTakesTheLineAwayThatTheShortcutCouldNotAnswer() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [MeetingAnswerReply(status: 408, retryAfter: nil, text: nil)]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.noAnswerInTime)

        // The next answer comes.
        harness.pro.replies = [MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The answer.**")]
        harness.clock.advance(by: 1.1)
        await harness.service.shortcutPressed()
        await harness.waitForRequests(2)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1, "no answer was published")
        XCTAssertNil(harness.service.status,
                     "the line that the shortcut could not answer stayed under the answer")
    }

    /// An answer takes the line away that said the sign-in is needed: the
    /// answer came through, so the line under it is stale.
    func testAnAnswerTakesTheLineAwayThatTheSignInIsNeeded() async {
        let harness = makeAnswerHarness()
        harness.pro.repliesByIndex = [
            0: MeetingAnswerReply(status: 401, retryAfter: nil, text: nil),
            1: MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The answer.**"),
        ]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.signInAgain)

        // The next answer comes.
        await harness.service.shortcutPressed()
        await harness.waitForRequests(2)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1, "no answer was published")
        XCTAssertNil(harness.service.status,
                     "the line that the sign-in is needed stayed under the answer")
    }

    /// An answer takes the line away that said there is no route: the route
    /// came back, and the line under the answer is stale.
    func testAnAnswerTakesTheLineAwayThatThereIsNoRoute() async {
        let harness = makeAnswerHarness()
        harness.pro.isAvailable = false
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitUntilIdle()
        // There is no route: nobody is asked, and the line says so.
        await harness.settle(0.3)
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.noRoute)

        // The route comes back, and the answer comes with it.
        harness.pro.isAvailable = true
        await harness.service.shortcutPressed()
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1, "no answer was published")
        XCTAssertNil(harness.service.status,
                     "the line about the missing route stayed under the answer")
    }

    /// The status of the spent balance stays for the meeting: an answer does
    /// not take it away.
    func testTheStatusOfTheSpentBalanceStaysForTheMeeting() async {
        let harness = makeAnswerHarness()
        harness.state.setStatus(MeetingAnswerStatus.balanceSpent)

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.answers.count, 1, "no answer was published")
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.balanceSpent,
                       "the status of the spent balance was taken away by an answer")
    }

    // MARK: - The generation

    /// An answer marks the transcript it used — not the lines that came in
    /// while it was on its way.
    func testAnAnswerMarksTheTranscriptItUsedAndNotTheLinesThatCameAfter() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "the first question", from: 0)

        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        // A second question arrives while the answer is on its way.
        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)

        harness.latch.open()
        await press.value
        await harness.waitUntilIdle()

        // The next render puts the divider before the second question: it
        // came after the answer.
        let rendered = await harness.transcript.renderedLines()
        XCTAssertEqual(rendered.answeredIndex, 1,
                       "the divider is not before the line that came after the answer")
    }

    /// The answer was given from the line that was still being transcribed,
    /// and the transcript was empty when the request was built: the answer
    /// marks the end of that line — not the end of the transcript as it is
    /// when the answer comes back (§3.4).
    func testAnAnswerFromThePendingTextMarksTheLineItUsedAndNotTheLinesThatCameAfter() async {
        let harness = makeAnswerHarness(pendingThemText: {
            LivePendingText(text: "When can you send the proposal?", endSample: 16_000)
        })
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        // The transcript is empty: the answer is given from the line that is
        // still being transcribed.
        let press = Task { await harness.service.shortcutPressed() }
        await harness.waitForRequests(1)

        // While the answer is on its way, the other side says something else.
        await appendThemLine(harness.transcript, text: "And the budget?", from: 32_000)

        harness.latch.open()
        await press.value
        await harness.waitUntilIdle()

        let answered = await harness.transcript.answeredEndSample
        XCTAssertEqual(answered, 16_000,
                       "the answer marked the lines that came after it")
    }

    /// A result of an older meeting is dropped.
    func testAResultOfAnOlderMeetingIsDropped() async {
        var generation = 1
        let harness = makeAnswerHarness(generation: { generation })
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)

        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)

        generation = 2
        harness.latch.open()
        await harness.waitUntilIdle()

        XCTAssertTrue(harness.service.answers.isEmpty, "the result of an older meeting was published")
    }

    // MARK: - The memo

    /// The memo asks for the summary with the summary prompt, over the same
    /// routes the answers use.
    func testTheMemoAsksWithTheSummaryPromptOverTheSameRoutes() async {
        let harness = makeAnswerHarness()
        let provider = harness.routes.makeMemoProvider()
        let line = LiveMeetingTranscript.Line(speaker: .them,
                                              text: "the decision about Friday",
                                              startSample: 0,
                                              endSample: 16_000)

        let memo = await provider("the summary so far", [line], LiveHintsStopToken())

        XCTAssertEqual(memo, "**The answer.**")
        XCTAssertEqual(harness.pro.requests.first?.system, MeetingCoachService.summaryPrompt)
        XCTAssertTrue(harness.pro.requests.first?.user.contains("the decision about Friday") ?? false,
                      "the memo did not carry the lines that fell out of the window")
        XCTAssertTrue(harness.pro.requests.first?.user.contains("the summary so far") ?? false,
                      "the memo did not carry the summary it had")
    }
}
