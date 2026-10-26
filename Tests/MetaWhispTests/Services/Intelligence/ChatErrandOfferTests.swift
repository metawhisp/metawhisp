import CryptoKit
import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 I-04 — MetaChat offers its model an errand only while one can
/// run (`AgentService.canRunErrands`). With a run: the `runErrand` tool and
/// the capability lines the owner approved on 2026-09-29 (lane B, 0cb3f53).
/// Without one — the app as built today — neither: the tools and the rules
/// are byte for byte those released at 00f9528, so MetaChat answers as it
/// did and never says the browser agent is "not available yet".
@MainActor
final class ChatErrandOfferTests: XCTestCase {

    // SHA-256 of the rules (UTF-8) and of the tools (JSON, sorted keys),
    // computed from the sources at 00f9528 (released) and 0cb3f53 (lane B).
    // ITER-076 I-06 (M2): the rules with errands lose the line that guesses
    // the weather after a refusal (0cb3f53's were e071d86e…); the released
    // rules keep it. ITER-076 stage 7 (text 19): the capabilities line about
    // sending and posting changes (they were f349bfe9…); the test below that
    // rebuilds the rules from the released ones shows nothing else moved.
    // ITER-076 stage 11: the doHere line, pending the owner's approval, follows
    // the errand's (they were 6f548b1c…); the same test shows nothing else moved.
    // Its words revised to what it does — it fills — with two words of the
    // errand block, all pending (they were 4be45873…). 2026-10-12: with a run
    // the screen rule sends a form-fill to doHere, in the owner's words (they
    // were 0cb9a14f…); the same test shows nothing else moved.
    private static let releasedRules = "1c1b764384406b7596b4e468b43253a14b47fdb8687d0844afdee1c41f527e59"
    // 2026-10-15: the errand line also covers "open … in the browser" (live L07); the capabilities block above is
    // compared whole, so the new hash holds only that change.
    private static let approvedRules = "ca260bf95bbef13a5d982df115ec0eee15ddfe322c151e778e7bd2cf50d030fc"
    private static let releasedTools = "9b959120bf4e05465fc77cc943b7af7c52d2e61f4ab100f80cd938066c3f4cb3"
    private static let approvedTools = "d2167ba64b74ef12d297e9eece860fe68010f4ba6b9363f8b2e78f93cf8595e8"

    private static let releasedToolNames = [
        "dismissTask", "completeTask", "dismissMemory", "updateGoalProgress", "addTask", "addMemory",
        "searchTasks", "searchMemories", "searchConversations", "searchScreenHistory",
    ]

    /// The `<capabilities>` block as released at 00f9528.
    private static let releasedCapabilities = """
    <capabilities>
    YOU CAN:
    - Answer questions using the context blocks below.
    - Quote, summarize, list, compare items from those blocks.
    - Resolve short follow-up messages against <previous_messages> (see ELLIPSIS rule).
    - CALL TOOLS to mutate the user's data when they EXPLICITLY ask for an action.
      (dismiss/complete a task, forget a memory, update a goal, add a task/memory.)
      The user must CONFIRM each tool call in the UI before it runs.

    YOU STILL CANNOT:
    - Send messages, emails, DMs, or post anywhere outside this app.
    - Browse the web, fetch URLs, get live weather / news / stock prices.
    - Open apps, run scripts, control the computer.
    - Call multiple tools in one turn (one tool per assistant message).
    - Delete things the user didn't explicitly ask to delete.

    When the user asks for an action you CANNOT do (web, send messages, etc.):
    - Explain in ONE sentence why + what they can do themselves.
    - DO NOT pretend you did it. Claiming an action you didn't take is a SEVERE failure.
    </capabilities>
    """

    /// The `<capabilities>` block the owner approved on 2026-09-29 (0cb3f53), with
    /// the line he approved on 2026-10-06 (ITER-076 stage 7, text 19): a form on
    /// a website goes only through runErrand; and, after the errand's line, the
    /// doHere line of ITER-076 stage 11 in the brief's words, pending his approval.
    private static let approvedCapabilities = """
    <capabilities>
    YOU CAN:
    - Answer questions using the context blocks below.
    - Quote, summarize, list, compare items from those blocks.
    - Resolve short follow-up messages against <previous_messages> (see ELLIPSIS rule).
    - START A BROWSER ERRAND with runErrand when the user asks for something that needs
      the live web or a website, including lookups like weather, news or prices, and whenever
      they ask to open, go to or click something in the browser, even when you know the
      address or the answer. It starts
      at once, without a confirmation bubble; the
      user sees it and can stop it. Say in one short sentence that it has started; never
      claim results before they arrive.
    - FILL IN THE FORM the user is looking at with doHere when they ask to fill this page or this form. Use runErrand for searching or collecting from the web. Never claim it is filled before its result arrives.
    - CALL TOOLS to mutate the user's data when they EXPLICITLY ask for an action.
      (dismiss/complete a task, forget a memory, update a goal, add a task/memory.)
      The user must CONFIRM each of these in the UI before it runs.

    YOU STILL CANNOT:
    - Send messages, emails, DMs, or post anywhere outside this app yourself: a form on a website only through runErrand or doHere.
    - Browse or fetch URLs yourself: only through runErrand.
    - Open apps, run scripts, control the computer.
    - Call multiple tools in one turn (one tool per assistant message).
    - Delete things the user didn't explicitly ask to delete.

    When the user asks for an action you CANNOT do (send messages, etc.):
    - Explain in ONE sentence why + what they can do themselves.
    - DO NOT pretend you did it. Claiming an action you didn't take is a SEVERE failure.
    </capabilities>
    """

    private func container() throws -> ModelContainer {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(tools: [[String: Any]]) throws -> String {
        sha256(try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]))
    }

    private static func names(_ tools: [[String: Any]]) -> [String] {
        tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    /// The block itself, not the role section's "(see <capabilities>)".
    private func capabilities(of rules: String) throws -> String {
        let start = try XCTUnwrap(rules.range(of: "\n<capabilities>\n"))
        let end = try XCTUnwrap(rules.range(of: "\n</capabilities>\n"))
        return String(rules[rules.index(after: start.lowerBound)..<rules.index(before: end.upperBound)])
    }

    /// A MetaChat whose model answers at once, and what it was sent.
    private func answeringChat(_ executor: ChatToolExecutor?) -> (ChatService, () -> [(rules: String, tools: [String])]) {
        let chat = ChatService()
        chat.toolExecutor = executor
        var sent: [(rules: String, tools: [String])] = []
        chat.chatWithTools = { rules, _, tools, _ in
            sent.append((rules, Self.names(tools)))
            return ChatService.NativeChatResponse(text: "Sunny.", toolCall: nil, finishReason: "stop")
        }
        return (chat, { sent })
    }

    // MARK: - Without a run: as released

    func testWithoutARunTheRulesAreThoseReleased() throws {
        let rules = ChatService.systemPrompt(canRunErrands: false)
        XCTAssertEqual(try capabilities(of: rules), Self.releasedCapabilities)
        XCTAssertEqual(sha256(Data(rules.utf8)), Self.releasedRules, "the whole rules, byte for byte")
        XCTAssertFalse(rules.contains("runErrand"))
    }

    func testWithoutARunNoErrandIsOfferedAndEveryOtherToolIsAsReleased() throws {
        let tools = ChatToolExecutor.toolSchemas(canRunErrands: false)
        XCTAssertEqual(Self.names(tools), Self.releasedToolNames)
        XCTAssertEqual(try sha256(tools: tools), Self.releasedTools, "every tool, byte for byte")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: tools), as: UTF8.self)
        XCTAssertFalse(json.contains("runErrand"))
    }

    // MARK: - With a run: as the owner approved

    func testWithARunTheRulesAreTheApprovedOnes() throws {
        let rules = ChatService.systemPrompt(canRunErrands: true)
        XCTAssertEqual(try capabilities(of: rules), Self.approvedCapabilities)
        XCTAssertEqual(sha256(Data(rules.utf8)), Self.approvedRules, "the whole rules, byte for byte")
    }

    /// ITER-076 I-06 (M2): with a run the rules are the released ones with
    /// the approved capabilities and without the one line that guesses the
    /// weather after a refusal, and (2026-10-12) with the screen rule's
    /// form-fill sentence in the owner's words — nothing else differs.
    func testWithARunTheRulesDropOnlyTheWeatherGuessLineAndSendAFormFillToDoHere() throws {
        let released = ChatService.systemPrompt(canRunErrands: false)
        let lines = released.components(separatedBy: "\n")
        let guess = lines.filter { $0.contains("You just refused weather") }
        XCTAssertEqual(guess.count, 1)
        XCTAssertTrue(guess[0].hasSuffix(#"("typically Belgrade in late April is 15-20°C, but I have no live data")."#))
        let expected = lines.filter { !$0.contains("You just refused weather") }.joined(separator: "\n")
            .replacingOccurrences(of: Self.releasedCapabilities, with: Self.approvedCapabilities)
            .replacingOccurrences(
                of: "For form-fill requests, return the values the user should paste, organized field by field.",
                with: "For form-fill requests, call doHere when it is in your tools; only without it, return the values "
                    + "the user should paste, organized field by field.")
        XCTAssertEqual(ChatService.systemPrompt(canRunErrands: true), expected)
    }

    /// The paragraph of `<available_tools>` that spells out the text envelope,
    /// byte for byte as the rules hold it.
    private static let textEnvelopeParagraph = """
    Emit EXACTLY this format when — and ONLY when — the user explicitly asks for an
    action. Put it at the END of your reply (after a plain-text one-line preamble
    explaining what you're about to do). The system strips the block from the
    displayed text, shows the user a confirm dialog, and runs the tool only on YES.

    Format:
    <tool_call>{"tool": "<name>", "args": {...}}</tool_call>


    """

    /// 2026-10-06, the owner's first errand from MetaChat: the Pro proxy carries
    /// native tool calls, but its rules told the model to write the call as text
    /// after a sentence — 8 of 9 live answers did, and an errand starts only from
    /// a call that is the whole answer. With a run, the Pro proxy's rules are the
    /// approved ones without that paragraph (9 of 9 native calls, live); nothing
    /// else differs, and the transports that read calls from text keep it.
    func testWithARunTheProProxysRulesAreTheApprovedOnesWithoutTheTextEnvelope() throws {
        let approved = ChatService.systemPrompt(canRunErrands: true)
        XCTAssertEqual(approved.components(separatedBy: Self.textEnvelopeParagraph).count, 2,
                       "the approved rules hold the paragraph once")
        let native = ChatService.nativeSystemPrompt(canRunErrands: true)
        XCTAssertEqual(native, approved.replacingOccurrences(of: Self.textEnvelopeParagraph, with: ""))
        XCTAssertFalse(native.contains("<tool_call>"))
        XCTAssertEqual(try capabilities(of: native), Self.approvedCapabilities)
    }

    func testWithoutARunTheProProxysRulesAreThoseReleased() {
        let native = ChatService.nativeSystemPrompt(canRunErrands: false)
        XCTAssertEqual(sha256(Data(native.utf8)), Self.releasedRules, "the whole rules, byte for byte")
    }

    /// ITER-076 I-06 (M3): the on-device model's rules without a run are
    /// byte for byte those released; with one they gain only the approved
    /// errand line, in the tools list.
    func testTheOnDeviceRulesGainOnlyTheApprovedErrandLine() {
        let line = #"Web tool (starts at once, no confirm): <runErrand>{"goal": "the user's request in their own words"}</runErrand> — look something up or do a task on the live web; results arrive later in this chat."#
        let without = ChatService.localSystemPrompt(canRunErrands: false)
        XCTAssertEqual(sha256(Data(without.utf8)),
                       "2d37962ce33fc7f08258d3f2ff8bf6b8332364845fed2453eb889df58c2acc23",
                       "as released at e55f534, byte for byte")
        let with = ChatService.localSystemPrompt(canRunErrands: true)
        XCTAssertTrue(with.contains("</updateGoalProgress>\n" + line + "\nRules:"), "the approved line, as it is")
        XCTAssertEqual(with.replacingOccurrences(of: line + "\n", with: ""), without)
    }

    /// With a run, every tool is as the owner approved it on 2026-09-29, byte for byte — but `runErrand`'s
    /// `output`, whose words he approved on 2026-10-06 (ITER-076 stage 6; its words: `ChatErrandToolTests`), and
    /// the five words its description lost with his approval of the same day (stage 8b, 8b-36).
    func testWithARunTheErrandIsOfferedAfterEveryOtherTool() throws {
        let tools = ChatToolExecutor.toolSchemas(canRunErrands: true)
        XCTAssertEqual(Self.names(tools), Self.releasedToolNames + ["runErrand", "doHere"])
        // ITER-076 stage 11: `doHere`, in the brief's words pending the owner's approval (its words:
        // `ChatHereToolTests`), is offered after the errand; every other tool is as before.
        let (approved, output) = Self.withoutOutput(tools.filter { Self.names([$0]) != ["doHere"] })
        XCTAssertNotNil(output, "the Sheet's output is offered")
        let description = try XCTUnwrap(Self.errandDescription(in: approved))
        XCTAssertFalse(description.contains("the user's own browser"), "the five words are gone (8b-36)")
        // …and without the clause of 2026-10-15 ("open … in the browser" starts the errand; live L07).
        let before = description.replacingOccurrences(of: "on the live web, in the background",
                                                      with: "on the live web in the user's own browser, in the background")
            .replacingOccurrences(of: ", and always when the user asks to open, go to or click something in the browser or on a website - even when you already know the address or the answer: they asked for it to be done.",
                                  with: ".")
        XCTAssertEqual(try sha256(tools: Self.withErrandDescription(before, in: approved)), Self.approvedTools,
                       "with those five words back, every byte as approved on 2026-09-29")
    }

    /// `runErrand`'s description in `tools`.
    private static func errandDescription(in tools: [[String: Any]]) -> String? {
        tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "runErrand" }?["description"]
            as? String
    }

    /// `tools` with `runErrand`'s description `description`.
    private static func withErrandDescription(_ description: String, in tools: [[String: Any]]) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            guard var function = tool["function"] as? [String: Any], function["name"] as? String == "runErrand"
            else { return tool }
            function["description"] = description
            var tool = tool
            tool["function"] = function
            return tool
        }
    }

    /// `tools` without `runErrand`'s `output`, and that `output`.
    private static func withoutOutput(_ tools: [[String: Any]]) -> ([[String: Any]], Any?) {
        var removed: Any?
        let kept = tools.map { tool -> [String: Any] in
            guard var function = tool["function"] as? [String: Any], function["name"] as? String == "runErrand",
                  var parameters = function["parameters"] as? [String: Any],
                  var properties = parameters["properties"] as? [String: Any] else { return tool }
            removed = properties.removeValue(forKey: "output")
            parameters["properties"] = properties
            function["parameters"] = parameters
            var tool = tool
            tool["function"] = function
            return tool
        }
        return (kept, removed)
    }

    // MARK: - What MetaChat sends

    /// MetaChat left to its defaults asks the app's own errand service
    /// whether to offer an errand (ITER-076 I-04), whatever this Mac's
    /// settings and licence say; what it sends follows that one gate — here a
    /// service of the test's own, with the agent off (stage 8b): the rules and
    /// tools as released. Never the host's settings or licence.
    func testMetaChatAsksTheAppsServiceAndWithNoErrandToOfferSendsTheReleasedRules() async throws {
        let executor = ChatToolExecutor()
        XCTAssertEqual(executor.canRunErrands(), AgentService.shared.canRunErrands, "the executor asks the app's service")
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.agentOn = false
        let service = h.makeService()
        executor.canRunErrands = { service.canRunErrands }
        let (chat, sent) = answeringChat(executor)
        let outcome = try await chat.runAgenticLoop(userPrompt: "what's the weather tomorrow", licenseKey: "LICENSE-1",
                                                    origin: .chat(messageID: UUID()), maxRounds: 2)
        XCTAssertEqual(outcome.text, "Sunny.")
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first?.rules, ChatService.nativeSystemPrompt(canRunErrands: false))
        XCTAssertEqual(sent().first?.tools, Self.releasedToolNames)
        withExtendedLifetime(executor) {}
    }

    func testWhenAnErrandCanRunMetaChatOffersIt() async throws {
        let executor = ChatToolExecutor()
        executor.canRunErrands = { true }
        let (chat, sent) = answeringChat(executor)
        _ = try await chat.runAgenticLoop(userPrompt: "what's the weather tomorrow", licenseKey: "LICENSE-1",
                                          origin: .chat(messageID: UUID()), maxRounds: 2)
        XCTAssertEqual(sent().first?.rules, ChatService.nativeSystemPrompt(canRunErrands: true))
        XCTAssertEqual(sent().first?.tools, Self.releasedToolNames + ["runErrand", "doHere"])
        withExtendedLifetime(executor) {}
    }

    /// ITER-076 I-06a, changed by stage 8b (owner decision 8.5): with a run,
    /// MetaChat — through `send`, asking the errand service — offers the
    /// errand with or without Pro, and with the agent off it answers as
    /// released. Until 8.5 a user without Pro was never offered one.
    func testWithARunMetaChatOffersTheErrandWithOrWithoutProAndNotWhileTheAgentIsOff() async throws {
        for (pro, on) in [(false, true), (true, true), (true, false), (false, false)] {
            let h = AgentServiceHarness()
            h.pro = pro
            h.agentOn = on
            let service = h.makeService()
            let store = try container()
            let executor = ChatToolExecutor()
            executor.configure(modelContainer: store)
            executor.canRunErrands = { service.canRunErrands }
            let (chat, sent) = answeringChat(executor)
            chat.configure(modelContainer: store)
            chat.hasLLMAccess = { true }
            chat.proLicenseKey = { "LICENSE-1" }
            _ = await chat.send("what's the weather tomorrow")
            let named = "pro=\(pro) on=\(on)"
            XCTAssertEqual(sent().count, 1, named)
            XCTAssertEqual(sent().first?.rules, ChatService.nativeSystemPrompt(canRunErrands: on), named)
            XCTAssertEqual(sent().first?.tools, on ? Self.releasedToolNames + ["runErrand", "doHere"] : Self.releasedToolNames,
                           named)
            withExtendedLifetime(executor) {}
            h.cleanUp()
        }
    }

    /// 8.5: without Pro the errand MetaChat offers is not started, and its
    /// model reads why in the approved words (8b-30) — nothing is asked of
    /// the browser.
    func testWithoutProTheErrandsStartSaysTheBrowserAgentNeedsPro() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.pro = false
        let service = h.makeService()
        let (chat, executor) = try chatOnService(h, service)
        var replies = [Self.errandCall, ChatService.NativeChatResponse(text: "It needs Pro.", toolCall: nil,
                                                                       finishReason: "stop")]
        var results: [String] = []
        chat.chatWithTools = { _, messages, _, _ in
            if let last = messages.last, last["role"] as? String == "tool" { results.append(last["content"] as? String ?? "") }
            return replies.removeFirst()
        }
        _ = try await chat.runAgenticLoop(userPrompt: "find 10 jokes", licenseKey: "LICENSE-1",
                                          origin: .chat(messageID: UUID()), maxRounds: 3)
        XCTAssertEqual(results, ["not started: the browser agent needs Pro"])
        XCTAssertTrue(h.runners.isEmpty)
        XCTAssertEqual(h.link.asked, 0)
        XCTAssertEqual(h.updates, [])
        withExtendedLifetime(executor) {}
    }

    /// A MetaChat whose executor asks `h`'s errand service whether an errand
    /// can run and starts it there.
    private func chatOnService(_ h: AgentServiceHarness, _ service: AgentService) throws -> (ChatService, ChatToolExecutor) {
        let store = try container()
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: store)
        executor.canRunErrands = { service.canRunErrands }
        executor.startErrand = { goal, origin, output, _ in service.start(goal: goal, origin: origin, output: output) }
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.toolExecutor = executor
        return (chat, executor)
    }

    private static let errandCall = ChatService.NativeChatResponse(
        text: "", toolCall: .init(id: "a", tool: "runErrand", args: ["goal": "find 10 jokes"]),
        finishReason: "tool_calls")

    /// ITER-076 stage 6: a table the model says the user asked for goes to the errand service MetaChat starts its
    /// errands on — never another — and its run is made to give a Sheet too; an answer, as an answer.
    func testATableAskedForInMetaChatStartsASheetErrandOnItsOwnService() async throws {
        for (args, output) in [(["goal": "find 10 jokes", "output": "sheet"], ErrandOutput.sheet),
                               (["goal": "find 10 jokes"], .answer)] {
            let h = AgentServiceHarness()
            let service = h.makeService()
            h.link.connect()
            let (chat, executor) = try chatOnService(h, service)
            var replies = [ChatService.NativeChatResponse(text: "", toolCall: .init(id: "a", tool: "runErrand", args: args),
                                                          finishReason: "tool_calls"),
                           ChatService.NativeChatResponse(text: "Started.", toolCall: nil, finishReason: "stop")]
            chat.chatWithTools = { _, _, _, _ in replies.removeFirst() }
            _ = try await chat.runAgenticLoop(userPrompt: "find 10 jokes", licenseKey: "LICENSE-1",
                                              origin: .chat(messageID: UUID()), maxRounds: 3)
            await h.until({ !h.runners.isEmpty }, "the errand's run on MetaChat's service")
            XCTAssertEqual(h.runners.map(\.setup.output), [output], "\(args)")
            withExtendedLifetime(executor) {}
            h.cleanUp()
        }
    }

    /// I-06a review, P2-2: the native loop reads whether an errand can run as
    /// it builds each request. The agent turned off between rounds — right
    /// after the model called `runErrand` — leaves that call unstarted, and
    /// the next request carries the released rules and no errand. (Pro, the
    /// flip here until stage 8b, no longer gates the offer: 8.5.)
    func testTheNativeLoopReadsWhetherAnErrandCanRunForEachRequest() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (chat, executor) = try chatOnService(h, service)
        var sent: [(rules: String, tools: [String])] = []
        chat.chatWithTools = { rules, _, tools, _ in
            sent.append((rules, Self.names(tools)))
            guard sent.count == 1 else {
                return ChatService.NativeChatResponse(text: "Sorry.", toolCall: nil, finishReason: "stop")
            }
            h.agentOn = false
            return Self.errandCall
        }
        _ = try await chat.runAgenticLoop(userPrompt: "find 10 jokes", licenseKey: "LICENSE-1",
                                          origin: .chat(messageID: UUID()), maxRounds: 3)
        XCTAssertEqual(sent.map(\.rules), [ChatService.nativeSystemPrompt(canRunErrands: true),
                                           ChatService.nativeSystemPrompt(canRunErrands: false)])
        XCTAssertEqual(sent.map(\.tools), [Self.releasedToolNames + ["runErrand", "doHere"], Self.releasedToolNames])
        XCTAssertTrue(h.runners.isEmpty, "the call already made started nothing")
        XCTAssertEqual(h.updates, [])
        withExtendedLifetime(executor) {}
    }

    /// I-06a review, P2-2: the text loop reads it as it builds each request
    /// too — the rules it is given, for whether an errand can run then; the
    /// agent turned off between rounds is the flip (stage 8b).
    func testTheTextLoopReadsWhetherAnErrandCanRunForEachRequest() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (chat, executor) = try chatOnService(h, service)
        var systems: [String] = []
        _ = try await chat.runTextAgenticLoop(userPrompt: "find 10 jokes", origin: .chat(messageID: UUID()),
                                              maxRounds: 3, rules: ChatService.systemPrompt(canRunErrands:)) { request in
            systems.append(request.system)
            guard systems.count == 1 else { return "Sorry." }
            h.agentOn = false
            return #"<tool_call>{"tool":"runErrand","args":{"goal":"find 10 jokes"}}</tool_call>"#
        }
        XCTAssertEqual(systems, [ChatService.systemPrompt(canRunErrands: true),
                                 ChatService.systemPrompt(canRunErrands: false)])
        XCTAssertTrue(h.runners.isEmpty, "the call already made started nothing")
        XCTAssertEqual(h.updates, [])

        // The on-device rules, read the same way.
        h.agentOn = true
        var local: [String] = []
        _ = try await chat.runTextAgenticLoop(userPrompt: "find 10 jokes", origin: .chat(messageID: UUID()),
                                              maxRounds: 3, rules: ChatService.localSystemPrompt(canRunErrands:)) { request in
            local.append(request.system)
            guard local.count == 1 else { return "Sorry." }
            h.agentOn = false
            return #"<tool_call>{"tool":"searchTasks","args":{"query":"jokes"}}</tool_call>"#
        }
        XCTAssertEqual(local, [ChatService.localSystemPrompt(canRunErrands: true),
                               ChatService.localSystemPrompt(canRunErrands: false)])
        withExtendedLifetime(executor) {}
    }

    /// Without an executor no tool runs, so no errand either.
    func testAChatWithoutAnExecutorOffersNoErrand() async throws {
        let (chat, sent) = answeringChat(nil)
        _ = try await chat.runAgenticLoop(userPrompt: "what's the weather tomorrow", licenseKey: "LICENSE-1",
                                          origin: .chat(messageID: UUID()), maxRounds: 2)
        XCTAssertEqual(sent().first?.rules, ChatService.nativeSystemPrompt(canRunErrands: false))
        XCTAssertEqual(sent().first?.tools, Self.releasedToolNames)
    }

    /// The follow-up after a confirmed change reads the same rules; it is
    /// never offered the errand either way (review of B2, P1).
    func testTheFollowUpReadsTheRulesForWhetherAnErrandCanRun() async throws {
        for canRun in [false, true] {
            let store = try container()
            let executor = ChatToolExecutor()
            executor.configure(modelContainer: store)
            // The gate the test gives, never the host's settings or licence (stage 8b).
            executor.canRunErrands = { canRun }
            let (chat, sent) = answeringChat(executor)
            chat.configure(modelContainer: store)
            chat.proLicenseKey = { "LICENSE-1" }
            let parent = ChatMessage(sender: "ai", text: "")
            parent.originatingUserPrompt = "add a task to reply to Sam"
            parent.toolCallIdNative = "call-1"
            let context = ModelContext(store)
            context.insert(parent)
            try context.save()

            await chat.continueAfterToolExecution(
                parentMessageId: parent.id,
                toolCall: .init(id: "call-1", tool: "addTask", args: ["description": "Reply to Sam"]),
                toolResult: .init(ok: true, summary: "Added task: Reply to Sam", auditId: nil))

            XCTAssertEqual(sent().count, 1, "canRun=\(canRun)")
            XCTAssertEqual(sent().first?.rules, ChatService.nativeSystemPrompt(canRunErrands: canRun), "canRun=\(canRun)")
            XCTAssertEqual(sent().first?.tools, Self.releasedToolNames, "canRun=\(canRun)")
            withExtendedLifetime(executor) {}
        }
    }
}
