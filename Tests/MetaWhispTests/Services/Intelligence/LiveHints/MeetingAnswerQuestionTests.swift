import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerQuestionTests: XCTestCase {
    func testTypedAskUsesTheExactForcedWording() {
        XCTAssertEqual(MeetingAnswerPrompts.typedAsk(text: "What is the delivery date?"),
                       "The user asks: \"What is the delivery date?\"\n\nThe user wants an answer to this: answer it directly: give the answer itself, ready to say out loud, never advice about how to answer.")
    }

    func testTypedQuestionCanSendBeforeAnyTranscriptExists() async throws {
        let harness = makeAnswerHarness(pinnedLanguage: { "en" })
        harness.pro.replies = [reply("**We should confirm the delivery date.**\n- Ask the delivery owner")]

        await harness.service.requestQuestion("What should we confirm?")?.value

        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertEqual(harness.requestCount, 1)
        XCTAssertTrue(request.user.hasSuffix(MeetingAnswerPrompts.typedAsk(text: "What should we confirm?")))
        XCTAssertEqual(request.system, MeetingAnswerPrompts.systemText(language: "en"))
        XCTAssertEqual(request.deadlineMs, MeetingAnswerService.shortcutDeadlineMs)
        let answer = try XCTUnwrap(harness.state.answers.first)
        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.provenance, .transcript)
        XCTAssertNil(answer.action)
        XCTAssertEqual(answer.blocks, [.headline("**We should confirm the delivery date.**"),
                                       .bullet("Ask the delivery owner")])
        XCTAssertNil(harness.state.status)
    }

    func testEmptyAndWhitespaceOnlyQuestionsSendNothing() async {
        for question in ["", " ", "\n\t  \n", "\u{2003}"] {
            let harness = makeAnswerHarness()
            let request = harness.service.requestQuestion(question)
            await request?.value
            XCTAssertNil(request)
            XCTAssertEqual(harness.requestCount, 0)
            XCTAssertTrue(harness.state.answers.isEmpty)
            XCTAssertNil(harness.state.status)
        }
    }

    func testTypedQuestionTrimsSurroundingWhitespace() async throws {
        let harness = makeAnswerHarness()
        await harness.service.requestQuestion(" \n  What is the delivery date? \t ")?.value

        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertTrue(request.user.hasSuffix(MeetingAnswerPrompts.typedAsk(text: "What is the delivery date?")))
    }

    func testTypedQuestionCapsAtFiveHundredCharactersWithoutSplittingGraphemes() async throws {
        XCTAssertEqual(MeetingAnswerService.maxQuestionCharacters, 500)
        let harness = makeAnswerHarness()
        let character = "👩🏽‍💻"
        let accepted = String(repeating: character, count: 500)

        await harness.service.requestQuestion(" \n" + accepted + "DROP_THIS_SUFFIX \n")?.value

        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertTrue(request.user.hasSuffix(MeetingAnswerPrompts.typedAsk(text: accepted)))
        XCTAssertFalse(request.user.contains("DROP_THIS_SUFFIX"))
    }

    func testTypedQuestionUsesTheCallAndPublishesIntoHistoryAndBoundary() async throws {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "the delivery date is Friday", from: 0)
        harness.pro.replies = [reply("**The delivery date is Friday.**")]

        await harness.service.requestQuestion("When is the delivery?")?.value

        let first = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertTrue(first.user.contains("Them: the delivery date is Friday"))
        let boundary = await harness.transcript.answeredEndSample
        XCTAssertEqual(boundary, 16_000)

        harness.pro.replies = [reply("[no-answer]")]
        await harness.service.requestQuestion("Who should confirm it?")?.value

        let second = try XCTUnwrap(harness.pro.requests.last)
        XCTAssertEqual(harness.requestCount, 2)
        XCTAssertTrue(second.user.contains("[Answered] **The delivery date is Friday.**"))
        XCTAssertEqual(harness.state.answers.count, 1)
    }

    func testTypedNoAnswerShowsRetryStatus() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [reply("[no-answer]")]

        await harness.service.requestQuestion("What is the delivery date?")?.value

        XCTAssertTrue(harness.state.answers.isEmpty)
        XCTAssertNil(harness.state.draft)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        harness.clock.advance(by: 4.9)
        XCTAssertEqual(harness.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        harness.clock.advance(by: 0.1)
        XCTAssertNil(harness.state.status)
    }

    func testTypedQuestionUsesTheAnswerOutputContract() async {
        for raw in ["An ordinary unformatted action paragraph.", "{\"answer\":\"invalid\"}",
                    "<think>never closed\n**Do not show this.**"] {
            let harness = makeAnswerHarness()
            harness.pro.replies = [reply(raw)]
            await harness.service.requestQuestion("What was decided?")?.value
            XCTAssertTrue(harness.state.answers.isEmpty)
            XCTAssertEqual(harness.state.status, MeetingAnswerStatus.couldNotGetAnAnswer)
        }
    }

    func testTypedQuestionCapturesItsGenerationBeforeTheTaskStarts() async {
        var generation = 1
        let harness = makeAnswerHarness(generation: { generation })

        let request = harness.service.requestQuestion("What is the delivery date?")
        generation = 2
        await request?.value

        XCTAssertNotNil(request)
        XCTAssertEqual(harness.requestCount, 0)
        XCTAssertTrue(harness.state.answers.isEmpty)
        XCTAssertNil(harness.state.status)
    }

    func testTypedQuestionImmediatelyCancelsAnActionOrShortcut() async throws {
        for isAction in [true, false] {
            let harness = makeAnswerHarness()
            let gate = RequestGate()
            let gates = GateQueue()
            gates.add(gate)
            harness.pro.gate = { await gates.next()?.wait() }
            harness.pro.repliesByIndex = [0: reply("**The superseded answer.**"),
                                         1: reply("**The typed answer.**")]
            await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
            let previous = isAction
                ? harness.service.requestAction(.questions)
                : harness.service.requestShortcut()
            await harness.waitForRequests(1)

            await harness.service.requestQuestion("What is the delivery date?")?.value
            gate.open()
            await previous?.value

            XCTAssertEqual(harness.requestCount, 2,
                           "the typed question was suppressed by another request's repeat guard")
            await harness.waitUntil { harness.pro.requests.first?.wasCancelled == true }
            XCTAssertTrue(try XCTUnwrap(harness.pro.requests.first).wasCancelled)
            XCTAssertEqual(harness.state.answers.map(\.headline), ["**The typed answer.**"])
        }
    }

    func testDistinctTypedQuestionsSupersedeImmediately() async throws {
        let harness = makeAnswerHarness()
        let gate = RequestGate()
        let gates = GateQueue()
        gates.add(gate)
        harness.pro.gate = { await gates.next()?.wait() }
        harness.pro.repliesByIndex = [0: reply("**The older typed answer.**"),
                                     1: reply("**The newest typed answer.**")]
        let previous = harness.service.requestQuestion("What is the first deadline?")
        await harness.waitForRequests(1)

        await harness.service.requestQuestion("What is the delivery date?")?.value
        gate.open()
        await previous?.value

        XCTAssertEqual(harness.requestCount, 2)
        await harness.waitUntil { harness.pro.requests.first?.wasCancelled == true }
        XCTAssertTrue(try XCTUnwrap(harness.pro.requests.first).wasCancelled)
        XCTAssertEqual(harness.state.answers.map(\.headline), ["**The newest typed answer.**"])
    }

    func testTypedQuestionStaysInsideBothBudgetsAfterALongCall() async throws {
        for isLocal in [false, true] {
            let harness = makeAnswerHarness()
            harness.pro.isAvailable = !isLocal
            harness.local.isAvailable = isLocal
            await appendThemLine(harness.transcript,
                                 text: String(repeating: "Earlier meeting detail. ", count: 2_000)
                                    + "The newest delivery date is Friday.", from: 0)
            let question = String(repeating: "q", count: 500)

            await harness.service.requestQuestion(question)?.value

            let request = try XCTUnwrap(isLocal ? harness.local.requests.first : harness.pro.requests.first)
            XCTAssertLessThanOrEqual(request.user.count, isLocal ? 6_000 : 12_000)
            XCTAssertTrue(request.user.contains("The newest delivery date is Friday."))
            XCTAssertTrue(request.user.hasSuffix(MeetingAnswerPrompts.typedAsk(text: question)))
        }
    }

    private func reply(_ text: String) -> MeetingAnswerReply {
        MeetingAnswerReply(status: 200, retryAfter: nil, text: text)
    }
}
