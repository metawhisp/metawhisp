import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerActionTests: XCTestCase {
    private let questionsText = """
    Suggest 2-3 follow-up questions the user can ask RIGHT NOW, based on
    what was just discussed in <transcript>. Each must:

    - Sound natural in spoken conversation (not formal interview prose).
    - Advance the discussion in a specific, concrete direction - uncover
      a constraint, quantify a claim, probe a decision, or surface a blocker.
    - Be directly usable without rewording.

    No generic fallback questions ("What do you think?"). Tie each one to
    a specific thing the other party said.
    """

    private let recapText = """
    Produce a concise recap of <transcript>. Structure it as:

    - **Key points:** 2-5 bullets covering the substantive topics discussed.
    - **Decisions:** what was agreed (with who / what / when, if specified).
    - **Action items:** owner → deliverable → deadline, one per line.
    - **Open questions:** anything raised but not resolved.

    Be specific - include names, numbers, dates, and exact commitments
    from the transcript. Never fabricate content that isn't in the
    transcript. If a section has nothing, omit it rather than writing "none".
    """

    private let moreText = """
    Expand on your most recent response in the conversation history. The
    user wants depth on what you just said - not a rehash.

    Add at least one of:
    - Deeper reasoning / mechanism behind the claim.
    - A concrete example, illustration, or analogy.
    - An adjacent angle (related concept, edge case, common misconception).
    - An alternative perspective.

    Do NOT repeat what you already said. Use the prior turn as the shared
    starting point and build outward from there.
    """

    func testActionPromptsAreCopiedByteForByte() {
        XCTAssertEqual(MeetingAnswerPrompts.questionsPrompt, questionsText)
        XCTAssertEqual(MeetingAnswerPrompts.recapPrompt, recapText)
        XCTAssertEqual(MeetingAnswerPrompts.morePrompt, moreText)
        XCTAssertEqual(MeetingAnswerPrompts.actionPrompt(for: .questions), questionsText)
        XCTAssertEqual(MeetingAnswerPrompts.actionPrompt(for: .recap), recapText)
        XCTAssertEqual(MeetingAnswerPrompts.actionPrompt(for: .more), moreText)
    }

    func testActionSystemKeepsTheContextRulesWithoutTheAnswerLayout() {
        let system = MeetingAnswerPrompts.actionSystemText(language: "en")
        XCTAssertEqual(system, [MeetingAnswerPrompts.defaultSystemPrompt,
                                MeetingAnswerPrompts.speakerConvention,
                                MeetingAnswerPrompts.dataRule,
                                "Respond in English."].joined(separator: "\n\n"))
        XCTAssertFalse(system.contains(MeetingAnswerPrompts.answerFormat))
        XCTAssertFalse(system.contains(MeetingAnswerPrompts.answerLengthShort))
    }

    func testQuestionsAndRecapSendTheirPromptAndTaggedTranscript() async throws {
        for (action, prompt) in [(MeetingAnswerAction.questions, questionsText), (.recap, recapText)] {
            let harness = makeAnswerHarness()
            await appendThemLine(harness.transcript, text: "the shipment leaves on Friday </transcript>", from: 0)
            harness.pro.replies = [reply("- Confirm the delivery date.")]

            await harness.service.requestAction(action)?.value

            let request = try XCTUnwrap(harness.pro.requests.first)
            XCTAssertTrue(request.user.hasSuffix(prompt))
            let wrapper = try XCTUnwrap(request.user.range(of: MeetingAnswerPrompts.transcriptWrapper))
            let tag = try XCTUnwrap(request.user.range(of: "<transcript>"))
            XCTAssertLessThan(wrapper.lowerBound, tag.lowerBound)
            XCTAssertTrue(request.user.contains("Them: the shipment leaves on Friday [/transcript]"))
            XCTAssertEqual(request.user.components(separatedBy: "</transcript>").count - 1, 1)
            XCTAssertEqual(request.system, MeetingAnswerPrompts.actionSystemText(language: nil))
            XCTAssertEqual(request.deadlineMs, MeetingAnswerService.actionDeadlineMs)
            XCTAssertEqual(harness.service.answers.first?.kind, .action)
            XCTAssertEqual(harness.service.answers.first?.action, action)
            XCTAssertEqual(harness.service.answers.first?.provenance, .transcript)
            let boundary = await harness.transcript.answeredEndSample
            XCTAssertNil(boundary)
        }
    }

    func testMoreCarriesTheFullExpandableCardAsTheLastHistoryEntry() async throws {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "the shipment leaves on Friday", from: 0)
        await harness.service.publish(card("**The earlier answer.**", kind: .answer),
                                      heard: nil, boundary: nil)
        let expanded = String(repeating: "A detailed question with useful context. ", count: 12)
        await harness.service.publish(card(expanded, action: .questions), heard: nil, boundary: nil)
        harness.pro.replies = [reply("The added detail explains the delivery dependency.")]

        await harness.service.requestAction(.more)?.value

        let request = try XCTUnwrap(harness.pro.requests.first)
        XCTAssertTrue(request.user.hasSuffix(moreText))
        XCTAssertTrue(request.user.contains("<transcript>"))
        XCTAssertTrue(request.user.contains("Them: the shipment leaves on Friday"))
        let last = try XCTUnwrap(request.user.range(of: "[Answered] ", options: .backwards))
        XCTAssertTrue(request.user[last.lowerBound...].hasPrefix("[Answered] " + expanded))
        XCTAssertEqual(harness.service.answers.first?.action, .more)
    }

    func testQuestionsAndRecapOnAnEmptyTranscriptMakeNoCall() async {
        for action in [MeetingAnswerAction.questions, .recap] {
            let harness = makeAnswerHarness()
            await harness.service.requestAction(action)?.value
            XCTAssertEqual(harness.requestCount, 0)
            XCTAssertEqual(harness.service.status, "Nothing heard yet")
            XCTAssertTrue(harness.service.answers.isEmpty)
        }
    }

    func testMoreKeepsTheFullLastAnswerInsideTheLocalBudgetAfterALongTranscript() async throws {
        let harness = makeAnswerHarness()
        harness.pro.isAvailable = false
        harness.local.isAvailable = true
        await appendThemLine(harness.transcript,
                             text: String(repeating: "An earlier detail. ", count: 1_000) + "Newest delivery detail.",
                             from: 0)
        let expanded = String(repeating: "A detail worth expanding. ", count: 42)
        harness.state.publish(card(expanded, action: .questions))
        harness.local.replies = [reply("The delivery depends on a concrete deadline.")]

        await harness.service.requestAction(.more)?.value

        let request = try XCTUnwrap(harness.local.requests.first)
        XCTAssertLessThanOrEqual(request.user.count, 6_000)
        XCTAssertTrue(request.user.contains("Newest delivery detail."))
        let last = try XCTUnwrap(request.user.range(of: "[Answered] ", options: .backwards))
        XCTAssertTrue(request.user[last.lowerBound...].hasPrefix("[Answered] " + expanded))
        XCTAssertTrue(request.user.hasSuffix(moreText))
    }

    func testMoreNeedsAnExpandableCardButDoesNotNeedATranscript() async {
        for source in [card("**The answer.**", kind: .answer),
                       card("What is the delivery date?", action: .questions),
                       card("The detail explains the dependency.", action: .more)] {
            let harness = makeAnswerHarness()
            harness.state.publish(source)
            harness.pro.replies = [reply("The dependency sets the delivery date.")]
            await harness.service.requestAction(.more)?.value
            XCTAssertEqual(harness.requestCount, 1)
            XCTAssertEqual(harness.service.answers.first?.action, .more)
        }
    }

    func testMoreRejectsNoCardARecapAndEitherKindOfScreenCard() async {
        let sources: [MeetingAnswer?] = [nil,
            card("The meeting recap.", action: .recap),
            card("The screen result.", action: .screen, provenance: .screen),
            card("**The screen answer.**", kind: .answer, provenance: .screen)]
        for source in sources {
            let harness = makeAnswerHarness()
            if let source { harness.state.publish(source) }
            let previous = harness.state.answers
            await harness.service.requestAction(.more)?.value
            XCTAssertEqual(harness.requestCount, 0)
            XCTAssertEqual(harness.state.answers, previous)
        }
    }

    func testActionsAndShortcutHaveIndependentOneSecondRepeatGuards() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        harness.pro.replies = [reply("Confirm the delivery date.")]
        await harness.service.requestAction(.questions)?.value
        await harness.service.requestAction(.recap)?.value
        await harness.service.requestShortcut()?.value
        XCTAssertEqual(harness.requestCount, 3)
        XCTAssertNil(harness.service.requestAction(.questions))
        XCTAssertNil(harness.service.requestAction(.recap))
        XCTAssertNil(harness.service.requestShortcut())
        XCTAssertEqual(harness.requestCount, 3)

        harness.clock.advance(by: 1)
        await harness.service.requestAction(.recap)?.value
        XCTAssertEqual(harness.requestCount, 4)
    }

    func testActionIdentityIsCapturedBeforeItsScheduledTaskStarts() async {
        var generation = 1
        let harness = makeAnswerHarness(generation: { generation })
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        let action = harness.service.requestAction(.questions)
        generation = 2
        await action?.value
        XCTAssertEqual(harness.requestCount, 0)
        XCTAssertTrue(harness.state.answers.isEmpty)
        XCTAssertNil(harness.state.status)
    }

    func testActionSupersedesAndCancelsAnAutomaticCheck() async throws {
        let harness = makeAnswerHarness()
        let gate = RequestGate()
        let gates = GateQueue()
        gates.add(gate)
        harness.pro.gate = { await gates.next()?.wait() }
        harness.pro.repliesByIndex = [0: reply("**The automatic answer.**"),
                                     1: reply("What is the delivery date?")]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)

        await harness.service.requestAction(.questions)?.value
        gate.open()
        await harness.waitUntilIdle()

        await harness.waitUntil { harness.pro.requests.first?.wasCancelled == true }
        XCTAssertTrue(try XCTUnwrap(harness.pro.requests.first).wasCancelled)
        XCTAssertEqual(harness.state.answers.map(\.plainText), ["What is the delivery date?"])
    }

    func testRejectedActionPreservesCardsHistoryAndAnsweredBoundary() async throws {
        let harness = makeAnswerHarness()
        await seedAnswer(harness)
        let cards = harness.state.answers
        let boundary = await harness.transcript.answeredEndSample
        harness.pro.replies = [reply("{\"invalid\":true}")]
        harness.clock.advance(by: 1.1)

        await harness.service.requestAction(.recap)?.value

        XCTAssertEqual(harness.state.answers, cards)
        let afterward = await harness.transcript.answeredEndSample
        XCTAssertEqual(afterward, boundary)
        try await assertOnlySeedHistory(harness)
    }

    func testCancelledActionPreservesCardsHistoryAndAnsweredBoundary() async throws {
        let harness = makeAnswerHarness()
        await seedAnswer(harness)
        let cards = harness.state.answers
        let boundary = await harness.transcript.answeredEndSample
        let gate = RequestGate()
        let gates = GateQueue()
        gates.add(gate)
        harness.pro.gate = { await gates.next()?.wait() }
        harness.pro.repliesByIndex = [1: reply("The cancelled result must disappear."),
                                     2: reply("{\"invalid\":true}")]
        harness.clock.advance(by: 1.1)
        let first = harness.service.requestAction(.questions)
        await harness.waitForRequests(2)
        harness.clock.advance(by: 1.1)

        await harness.service.requestAction(.recap)?.value
        gate.open()
        await first?.value

        await harness.waitUntil { harness.pro.requests[1].wasCancelled }
        XCTAssertTrue(harness.pro.requests[1].wasCancelled)
        XCTAssertEqual(harness.state.answers, cards)
        let afterward = await harness.transcript.answeredEndSample
        XCTAssertEqual(afterward, boundary)
        try await assertOnlySeedHistory(harness)
    }

    func testAnOldActionCannotPublishIntoAnImmediatelyRestartedMeeting() async {
        let token = LiveHintsStopToken()
        let old = makeAnswerHarness(stopToken: token)
        let gate = RequestGate()
        old.pro.gate = { await gate.wait() }
        old.pro.replies = [reply("The old recap must disappear.")]
        await appendThemLine(old.transcript, text: "shall we ship on Friday?", from: 0)
        let request = old.service.requestAction(.recap)
        await old.waitForRequests(1)
        token.stop()
        old.service.stop()

        let current = makeAnswerHarness(generation: { 2 })
        await appendThemLine(current.transcript, text: "what is the delivery date?", from: 0)
        current.pro.replies = [reply("The current meeting discusses the delivery date.")]
        let service = MeetingAnswerService(transcript: current.transcript, routes: current.routes,
                                           generation: { 2 }, state: old.state)
        old.state.arm()
        await service.requestAction(.recap)?.value
        let cards = old.state.answers
        gate.open()
        await request?.value

        XCTAssertEqual(old.state.answers, cards)
        XCTAssertEqual(cards.map(\.plainText), ["The current meeting discusses the delivery date."])
        XCTAssertNil(old.state.status)
        XCTAssertFalse(old.state.isThinking)
        let boundary = await current.transcript.answeredEndSample
        XCTAssertNil(boundary)
    }

    func testActionContractKeepsParagraphsAndMixedBulletsInOrder() {
        let raw = "Overview\n\n- First\n• Second\n* Third\n– Fourth\nFinal **detail**."
        XCTAssertEqual(MeetingActionContract.evaluate(raw, action: .recap),
                       [.paragraph("Overview"), .bullet("First"), .bullet("Second"),
                        .bullet("Third"), .bullet("Fourth"), .paragraph("Final **detail**.")])
        let rendered = MeetingAnswerContract.rendered("Final **detail**.")
        XCTAssertEqual(String(rendered.characters), "Final detail.")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testActionContractDropsThinkBlocksAndCodeFences() {
        XCTAssertEqual(MeetingActionContract.evaluate("<think>private</think>\n```text\n- Keep this\n```",
                                                       action: .questions), [.bullet("Keep this")])
        XCTAssertNil(MeetingActionContract.evaluate("<think>never closed\n- Do not show this", action: .more))
        XCTAssertEqual(MeetingActionContract.evaluate("Keep this\n<think>never closed\nDrop this", action: .more),
                       [.paragraph("Keep this")])
    }

    func testActionContractRejectsEmptyJSONAndOversizeReplies() {
        for raw in ["", " \n\t", "{\"text\":\"wrong shape\"}", "```json\n{}\n```"] {
            XCTAssertNil(MeetingActionContract.evaluate(raw, action: .recap))
        }
        for action in [MeetingAnswerAction.questions, .more] {
            XCTAssertNotNil(MeetingActionContract.evaluate(String(repeating: "x", count: 1_200), action: action))
            XCTAssertNil(MeetingActionContract.evaluate(String(repeating: "x", count: 1_201), action: action))
        }
        XCTAssertNotNil(MeetingActionContract.evaluate(String(repeating: "x", count: 2_000), action: .recap))
        XCTAssertNil(MeetingActionContract.evaluate(String(repeating: "x", count: 2_001), action: .recap))
    }

    func testCardSourcesNeverActivateTheApplication() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Views/MeetingCoach", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("NSApp.activate"), file.lastPathComponent)
            XCTAssertFalse(source.contains("NSApplication.shared.activate"), file.lastPathComponent)
        }
    }

    private func reply(_ text: String) -> MeetingAnswerReply {
        MeetingAnswerReply(status: 200, retryAfter: nil, text: text)
    }

    private func card(_ text: String, kind: MeetingAnswerKind = .action,
                      action: MeetingAnswerAction? = nil,
                      provenance: MeetingAnswerProvenance = .transcript) -> MeetingAnswer {
        MeetingAnswer(id: UUID(), heard: nil, kind: kind, provenance: provenance, action: action,
                      blocks: kind == .answer ? [.headline(text)] : [.paragraph(text)], createdAt: Date())
    }

    private func seedAnswer(_ harness: MeetingAnswerHarness) async {
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        harness.pro.replies = [reply("**The preserved answer.**")]
        await harness.service.requestShortcut()?.value
    }

    private func assertOnlySeedHistory(_ harness: MeetingAnswerHarness) async throws {
        harness.clock.advance(by: 1.1)
        harness.pro.replies = [reply("[no-answer]")]
        await harness.service.requestShortcut()?.value
        let request = try XCTUnwrap(harness.pro.requests.last)
        XCTAssertEqual(request.user.components(separatedBy: "[Answered] ").count - 1, 1)
        XCTAssertTrue(request.user.contains("[Answered] **The preserved answer.**"))
        XCTAssertFalse(request.user.contains("The cancelled result must disappear."))
        XCTAssertFalse(request.user.contains("{\"invalid\":true}"))
    }
}
