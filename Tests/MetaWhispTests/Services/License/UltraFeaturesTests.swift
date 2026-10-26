import SwiftData
import XCTest
@testable import MetaWhisp

/// U1 (owner, 2026-10-25) — screen hints and the browser agent are not part of Pro: one local switch, off unless set
/// by hand and never shown in the app, turns them on (`defaults write com.metawhisp.app ultraPreview -bool true`).
/// Every test of the switch off has its brother on: off, none of it runs or shows (F1); on, all of it works as today
/// (F2); and what the user set for them is never written, so the switch on brings back exactly what they had (F3).
/// MetaChat mentions browsing only while the agent is there (F5). Settings and licences are the test's own, or the
/// app's put back after.
@MainActor
final class UltraFeaturesTests: XCTestCase {

    // MARK: - The switch

    /// Off on every Mac until set: only a stored `true` turns it on; `false` or no key is off.
    func testTheSwitchIsOffUntilSetToTrue() throws {
        let suite = "mw-ultra-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UltraFeatures.key, "ultraPreview", "the key the install writes")
        XCTAssertFalse(UltraFeatures.isOn(in: defaults), "off until set")
        defaults.set(true, forKey: UltraFeatures.key)
        XCTAssertTrue(UltraFeatures.isOn(in: defaults), "on once set")
        defaults.set(false, forKey: UltraFeatures.key)
        XCTAssertFalse(UltraFeatures.isOn(in: defaults))
        defaults.removeObject(forKey: UltraFeatures.key)
        XCTAssertFalse(UltraFeatures.isOn(in: defaults), "off again once removed")
    }

    // MARK: - The browser agent

    /// Off (F1): MetaChat is offered no errand and shows none to try; a start — typed or by voice — is refused as
    /// unavailable, and nothing is asked of the browser.
    func testOffTheAgentIsNotOfferedAndEveryStartIsRefused() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService(settings: h.settings.gated(by: { false }))
        XCTAssertFalse(service.canRunErrands, "no errand offered")
        XCTAssertFalse(service.canStartErrands, "none can start")
        XCTAssertFalse(ChatView.tryLines(errandCanStart: service.canStartErrands).contains(AgentSetup.example))
        XCTAssertEqual(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())), .refused(.unavailable))
        XCTAssertEqual(service.start(goal: "Find 10 jokes", origin: .voice(questionID: UUID())), .refused(.unavailable))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(h.link.asked, 0, "nothing asked of the browser")
        XCTAssertTrue(h.runners.isEmpty, "no run")
        XCTAssertEqual(h.updates, [], "no card, no line")
    }

    /// On (F2): offered, shown to try and started as today.
    func testOnTheAgentIsOfferedAndStartsAsToday() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService(settings: h.settings.gated(by: { true }))
        XCTAssertTrue(service.canRunErrands, "offered")
        XCTAssertTrue(service.canStartErrands, "it can start")
        XCTAssertTrue(ChatView.tryLines(errandCanStart: service.canStartErrands).contains(AgentSetup.example))
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .voice(questionID: UUID())).id)
        let run = await h.runner(for: id)
        XCTAssertNotNil(run, "it runs")
    }

    /// The gate's release: the switch is read at each ask, so turning it on lets the next errand start — no relaunch.
    func testTheSwitchTurnedOnLetsTheNextErrandStart() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        var ultra = false
        let service = h.makeService(settings: h.settings.gated(by: { ultra }))
        XCTAssertEqual(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())), .refused(.unavailable))
        ultra = true
        XCTAssertTrue(service.canRunErrands)
        let id = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        let run = await h.runner(for: id)
        XCTAssertNotNil(run, "it runs")
    }

    /// F3: the gate reads the user's own "Browser agent" switch and never writes it — off, the agent is off whatever
    /// they set; on, it is what they set.
    func testTheUsersOwnSwitchIsReadNeverWritten() {
        let settings = AppSettings.shared
        let saved = settings.browserAgentOn
        defer { settings.browserAgentOn = saved }
        for usersSwitch in [true, false] {
            settings.browserAgentOn = usersSwitch
            XCTAssertFalse(AgentSettings.app.gated(by: { false }).isOn(), "off, whatever the user set: \(usersSwitch)")
            XCTAssertEqual(settings.browserAgentOn, usersSwitch, "kept")
            XCTAssertEqual(AgentSettings.app.gated(by: { true }).isOn(), usersSwitch, "on, what the user set")
            XCTAssertEqual(settings.browserAgentOn, usersSwitch, "kept")
        }
    }

    /// The app's own service reads the switch from the app's defaults at each ask — here the test process's own, put
    /// back after: off by default, no errand is offered; on, as the user set. Nothing here asks for a licence: the
    /// start's Pro check is never reached with the switch off.
    func testTheAppsServiceFollowsTheSwitch() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: UltraFeatures.key)
        let settings = AppSettings.shared
        let savedOn = settings.browserAgentOn
        defer {
            if let saved { defaults.set(saved, forKey: UltraFeatures.key) } else { defaults.removeObject(forKey: UltraFeatures.key) }
            settings.browserAgentOn = savedOn
        }
        settings.browserAgentOn = true
        defaults.removeObject(forKey: UltraFeatures.key)
        XCTAssertFalse(AgentService.shared.canRunErrands, "off by default: no errand offered")
        XCTAssertFalse(AgentService.shared.canStartErrands)
        defaults.set(true, forKey: UltraFeatures.key)
        XCTAssertTrue(AgentService.shared.canRunErrands, "on: offered as today")
        settings.browserAgentOn = false
        XCTAssertFalse(AgentService.shared.canRunErrands, "on, the user's own switch still decides")
    }

    // MARK: - MetaChat, typed or by voice

    /// Off (F1, F5): typed or by voice, MetaChat's rules say nothing of browsing and offer neither the errand nor the
    /// form fill — the rules and tools as released; an errand the model calls anyway is refused as unavailable, and
    /// nothing is asked of the browser.
    func testOffMetaChatSaysNothingOfBrowsingAndStartsNoErrandTypedOrByVoice() async throws {
        for source in [ChatService.Source.typed, .voice(question: UUID())] {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            h.link.connect()
            let service = h.makeService(settings: h.settings.gated(by: { false }))
            let (chat, executor, sent) = try metaChat(on: service)
            _ = await chat.send("find 10 jokes online", source: source)
            let named = "\(source)"
            let first = try XCTUnwrap(sent.requests.first, named)
            XCTAssertEqual(first.rules, ChatService.nativeSystemPrompt(canRunErrands: false), named)
            XCTAssertFalse(first.rules.contains("BROWSER ERRAND"), named)
            XCTAssertFalse(first.rules.contains("runErrand"), named)
            // The lines agent/brain added (2026-10-12, 2026-10-15) come with the agent alone: a form-fill is answered
            // in text, and nothing sends "open … in the browser" to an errand.
            XCTAssertTrue(first.rules.contains("For form-fill requests, return the values the user should paste"), named)
            XCTAssertFalse(first.rules.contains("call doHere"), named)
            XCTAssertFalse(first.rules.contains("open, go to or click something in the browser"), named)
            XCTAssertFalse(first.tools.contains("runErrand"), named)
            XCTAssertFalse(first.tools.contains("doHere"), named)
            XCTAssertEqual(sent.toolResults, ["not started: the browser agent is not available yet"], named)
            XCTAssertEqual(h.link.asked, 0, named)
            XCTAssertTrue(h.runners.isEmpty, named)
            XCTAssertEqual(h.updates, [], named)
            withExtendedLifetime(executor) {}
        }
    }

    /// On (F2, F5): typed or by voice, MetaChat says it can start a browser errand, offers it and the form fill, and
    /// the errand starts — a voice one bound to its question — as today.
    func testOnMetaChatSaysItCanBrowseAndTheErrandStartsTypedOrByVoice() async throws {
        for source in [ChatService.Source.typed, .voice(question: UUID())] {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            h.link.connect()
            let service = h.makeService(settings: h.settings.gated(by: { true }))
            let (chat, executor, sent) = try metaChat(on: service)
            let outcome = await chat.send("find 10 jokes online", source: source)
            let named = "\(source)"
            XCTAssertEqual(outcome, .errandStarted, named)
            let first = try XCTUnwrap(sent.requests.first, named)
            XCTAssertEqual(first.rules, ChatService.nativeSystemPrompt(canRunErrands: true), named)
            XCTAssertTrue(first.rules.contains("START A BROWSER ERRAND with runErrand"), named)
            XCTAssertTrue(first.rules.contains("For form-fill requests, call doHere when it is in your tools"), named)
            XCTAssertTrue(first.rules.contains("they ask to open, go to or click something in the browser"), named)
            XCTAssertTrue(first.tools.contains("runErrand"), named)
            XCTAssertTrue(first.tools.contains("doHere"), named)
            await h.until({ !h.runners.isEmpty }, "the errand's run: \(named)")
            if case .voice(let question) = source {
                XCTAssertEqual(h.updates.first?.origin, .voice(questionID: question), named)
            }
            withExtendedLifetime(executor) {}
        }
    }

    // MARK: - The ways into an errand that agent/brain added

    /// Off (F1): the app's errands think on the brain (agent/brain, 2026-10-20). A service made as the app's is —
    /// its runs the brain's — refuses the errand behind the switch and makes no brain, so none is asked, and nothing
    /// is asked of the browser.
    func testOffNoBrainIsMadeForAnErrand() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        var brains = 0
        let service = brainService(h, ultra: { false }) { brains += 1 }
        defer { service.stopAll() }
        XCTAssertEqual(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())), .refused(.unavailable))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(brains, 0, "no brain")
        XCTAssertEqual(h.link.asked, 0, "nothing asked of the browser")
    }

    /// On (F2): the errand's run is the brain's, as on agent/brain: one is made for it.
    func testOnTheErrandsRunIsTheBrainsAsToday() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        var brains = 0
        let service = brainService(h, ultra: { true }) { brains += 1 }
        defer { service.stopAll() }
        XCTAssertNotNil(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id, "it starts")
        await h.until({ brains == 1 }, "the errand's brain")
    }

    /// Off (F1): the two errands agent/brain added a way into — a table its brain writes to a Sheet (2026-10-20) and
    /// one that begins at the address the user named (2026-10-12) — are refused as unavailable, and nothing is asked
    /// of the browser. On (F2): each starts as on agent/brain, the table with its Sheet, the other at that address.
    func testOffATableOrAnAddressedErrandIsRefusedOnEachStartsAsToday() async throws {
        let errands: [(args: [String: String], words: String)] = [
            (["goal": "Collect 10 competitors", "output": ErrandOutput.sheet.rawValue], "collect 10 competitors into a sheet"),
            (["goal": "Find 10 short jokes using DuckDuckGo"], "Open https://duckduckgo.com/ and find 10 short jokes"),
        ]
        for ultra in [false, true] {
            for errand in errands {
                let h = AgentServiceHarness()
                defer { h.cleanUp() }
                h.link.connect()
                let service = h.makeService(settings: h.settings.gated(by: { ultra }))
                let executor = ChatToolExecutor()
                executor.canRunErrands = { service.canRunErrands }
                executor.readsOutput = true
                executor.startErrand = { goal, origin, output, start in
                    service.start(goal: goal, origin: origin, output: output, start: start)
                }
                let named = "ultra=\(ultra): \(errand.words)"
                let result = executor.runErrand(.init(id: nil, tool: "runErrand", args: errand.args),
                                                origin: .chat(messageID: UUID()), userMessage: errand.words)
                guard ultra else {
                    XCTAssertFalse(result.ok, named)
                    XCTAssertEqual(result.summary, "not started: the browser agent is not available yet", named)
                    try? await Task.sleep(for: .milliseconds(20))
                    XCTAssertEqual(h.link.asked, 0, named)
                    XCTAssertTrue(h.runners.isEmpty, named)
                    continue
                }
                XCTAssertTrue(result.ok, named)
                let id = try XCTUnwrap(result.errandID, named)
                let run = await h.runner(for: id)
                let setup = try XCTUnwrap(run?.setup, named)
                if errand.args["output"] != nil {
                    XCTAssertEqual(setup.output, .sheet, named)
                } else {
                    XCTAssertEqual(setup.start, URL(string: "https://duckduckgo.com/"), named)
                }
            }
        }
    }

    /// Off (F1): "fill this form" — the agent's other tool — fills nothing on the user's page.
    func testOffTheFormFillFillsNothing() async {
        let (executor, fills, h) = formFill(ultra: false)
        defer { h.cleanUp() }
        let result = await executor.doHere(goal: "fill this page", pid: nil) { _ in .none }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.summary, "not started: the browser agent is not available yet")
        XCTAssertEqual(fills(), 0)
    }

    /// On (F2): it fills as today.
    func testOnTheFormFillFillsAsToday() async {
        let (executor, fills, h) = formFill(ultra: true)
        defer { h.cleanUp() }
        let result = await executor.doHere(goal: "fill this page", pid: nil) { _ in .none }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(fills(), 1)
    }

    // MARK: - Off while an admitted errand waits (Codex P2, 1.4.0 merge review)

    /// An errand admitted with the switch on waits before its run is made: for its task to run, the user's Allow, its
    /// browser, its turn in the queue. Off during any of them, the wait's end makes no run — so no brain: the app makes
    /// the brain with the run (`AgentRun.thinking`) — and asks the browser nothing more. The errand ends stopped, the
    /// waiting ones all stopped, as when the agent is turned off. Each wait used to go on to a run made while off.
    func testUltraTurnedOffWhileAnErrandWaitsMakesNoRunAfterAnyWait() async throws {
        for wait in ErrandWait.allCases {
            let (h, service, id, _) = try await errand(heldIn: wait)
            defer { h.cleanUp() }
            let named = wait.rawValue
            XCTAssertFalse(h.runners.contains { $0.setup.id == id }, "no run, so no brain: \(named)")
            XCTAssertEqual(h.link.asked, wait.browserAsks, "nothing more asked of the browser: \(named)")
            XCTAssertEqual(h.events(of: id).last, .finished(wait == .theQueue ? Self.allStopped : Self.stopped), named)
            XCTAssertFalse(service.errandRunning, named)
            XCTAssertNil(service.disclosure, named)
        }
    }

    /// The brothers: after each of those waits, the switch on again — read at the next ask, no relaunch — and a new
    /// errand's run is made and runs; one whose Allow was never given asks for it first.
    func testUltraTurnedBackOnAfterAnyWaitANewErrandRuns() async throws {
        for wait in ErrandWait.allCases {
            let (h, service, _, ultra) = try await errand(heldIn: wait)
            defer { h.cleanUp() }
            ultra.on = true
            let id = try XCTUnwrap(service.start(goal: "On again", origin: .chat(messageID: UUID())).id, wait.rawValue)
            if !h.allowed {
                await h.until({ service.disclosure != nil }, "the disclosure: \(wait.rawValue)")
                service.allow()
            }
            let run = await h.runner(for: id)
            XCTAssertNotNil(run, "it runs: \(wait.rawValue)")
        }
    }

    /// Codex's case with the app's own runs, the brain's: on, an errand waits for the Allow; off; Allow. No brain is
    /// made, so none is asked; on again, the next errand's brain is made.
    func testUltraTurnedOffWhileTheAllowWaitsMakesNoBrainAndOnAgainTheNextErrandsIsMade() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        h.allowed = false
        var ultra = true
        var brains = 0
        let service = brainService(h, ultra: { ultra }) { brains += 1 }
        defer { service.stopAll() }
        XCTAssertNotNil(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
        await h.until({ service.disclosure != nil }, "the disclosure")
        ultra = false
        service.allow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(brains, 0, "no brain")
        XCTAssertEqual(h.link.asked, 0, "nothing asked of the browser")
        ultra = true
        XCTAssertNotNil(service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id)
        await h.until({ brains == 1 }, "the next errand's brain")
    }

    // MARK: - Screen hints and the realtime task reactor

    /// Off (F1): a new screen wakes neither the screen hints nor the realtime task reactor, so neither makes a model
    /// call.
    func testOffANewScreenWakesNeitherTheHintsNorTheTaskReactor() async {
        var woken: [String] = []
        ScreenContextFanout.dispatch(screen(), ultra: false,
                                     toTaskReactor: { _ in woken.append("reactor") },
                                     toProactive: { _ in woken.append("hints") })
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(woken, [], "nothing runs")
    }

    /// On (F2): both are woken, as today.
    func testOnANewScreenWakesTheHintsAndTheTaskReactorAsToday() async {
        let reactor = expectation(description: "the task reactor")
        let hints = expectation(description: "the screen hints")
        ScreenContextFanout.dispatch(screen(), ultra: true,
                                     toTaskReactor: { _ in reactor.fulfill() },
                                     toProactive: { _ in hints.fulfill() })
        await fulfillment(of: [reactor, hints], timeout: 1)
    }

    /// The app hands the fanout the switch itself, for each new screen — never a constant.
    func testTheAppHandsTheFanoutTheSwitch() throws {
        let code = try codeLines(of: "App/AppDelegate.swift").joined(separator: "\n")
            .replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(code.contains("ScreenContextFanout.dispatch("), "the app wakes the hints and the reactor there")
        XCTAssertTrue(code.contains("ultra:UltraFeatures.isOn(),"), "with the switch")
    }

    /// The fanout's gate is the only one the hints and the reactor need: nothing reaches `onNewContext` or
    /// `react(to:)` but the app's two fanout consumers.
    func testTheHintsAndTheReactorAreReachedOnlyThroughTheFanout() throws {
        var calls: [String] = []
        for (path, lines) in try sources(under: ["App", "Models", "Services", "Views", "Helpers"]) {
            for (index, line) in lines.enumerated() where line.contains(".onNewContext(") || line.contains(".react(to:") {
                calls.append("\(path):\(index + 1)")
                XCTAssertTrue(line.contains("toProactive:") || line.contains("toTaskReactor:"),
                              "a way around the fanout: \(path):\(index + 1)")
            }
        }
        XCTAssertEqual(calls.count, 2, "the fanout's two consumers: \(calls)")
    }

    // MARK: - Settings

    /// Off (F1): no Agent tab.
    func testOffSettingsHasNoAgentTab() {
        XCTAssertEqual(MainSettingsView.SettingsTab.shown(ultra: false).map(\.rawValue),
                       ["General", "Dictation", "Meetings", "Second Brain", "Integrations"])
    }

    /// On (F2): the six tabs, as today.
    func testOnSettingsHasTheAgentTabAsToday() {
        XCTAssertEqual(MainSettingsView.SettingsTab.shown(ultra: true), MainSettingsView.SettingsTab.allCases)
        XCTAssertEqual(MainSettingsView.SettingsTab.allCases.last, .agent)
    }

    /// Settings builds its tabs from the switch, and the Screen Agent card and the Realtime task detection row only
    /// behind it — the only controls of those two settings. Read from the source: SwiftUI bodies have no test
    /// harness here.
    func testSettingsBuildsTheHintRowsOnlyBehindTheSwitch() throws {
        let lines = try codeLines(of: "Views/Windows/MainSettingsView.swift")
        XCTAssertTrue(lines.contains { $0.contains("ForEach(SettingsTab.shown(ultra: UltraFeatures.isOn()))") },
                      "the tab picker shows the tabs the switch allows")
        XCTAssertFalse(lines.contains { $0.contains("ForEach(SettingsTab.allCases)") }, "never every tab")
        for (part, binding) in [("proactiveSection", "$settings.proactiveEnabled"),
                                ("realtimeTaskDetectionRow", "$settings.realtimeScreenReactionEnabled")] {
            let declaration = "private var \(part): some View"
            let uses = lines.filter { $0.contains(part) && !$0.contains(declaration) }
            XCTAssertFalse(uses.isEmpty, "\(part) is built somewhere")
            for use in uses {
                XCTAssertTrue(use.contains("if UltraFeatures.isOn() { \(part) }"), "\(part) built without the switch: \(use)")
            }
            XCTAssertEqual(lines.filter { $0.contains(binding) }.count, 1, "\(binding): one control")
            XCTAssertTrue(body(of: declaration, in: lines).contains { $0.contains(binding) }, "\(binding) in \(part)")
        }
    }

    // MARK: - What the user set (F3)

    /// A user who had the hints, the reactor and the agent on in 1.3.37: the switch off stops all three and writes
    /// none of their settings; the switch on brings back exactly what they had.
    func testWhatTheUserSetIsKeptThroughOffAndOn() async {
        let s = AppSettings.shared
        let saved = (s.proactiveEnabled, s.realtimeScreenReactionEnabled, s.browserAgentOn)
        defer { (s.proactiveEnabled, s.realtimeScreenReactionEnabled, s.browserAgentOn) = saved }
        (s.proactiveEnabled, s.realtimeScreenReactionEnabled, s.browserAgentOn) = (true, true, true)
        for ultra in [false, true] {
            var woken: Set<String> = []
            ScreenContextFanout.dispatch(screen(), ultra: ultra,
                                         toTaskReactor: { _ in _ = woken.insert("reactor") },
                                         toProactive: { _ in _ = woken.insert("hints") })
            try? await Task.sleep(for: .milliseconds(200))
            let named = "ultra=\(ultra)"
            XCTAssertEqual(woken, ultra ? ["reactor", "hints"] : [], named)
            XCTAssertEqual(AgentSettings.app.gated(by: { ultra }).isOn(), ultra, named)
            XCTAssertEqual(MainSettingsView.SettingsTab.shown(ultra: ultra).contains(.agent), ultra, named)
            XCTAssertTrue(s.proactiveEnabled, "the hints' setting is kept: \(named)")
            XCTAssertTrue(s.realtimeScreenReactionEnabled, "the reactor's setting is kept: \(named)")
            XCTAssertTrue(s.browserAgentOn, "the agent's setting is kept: \(named)")
        }
    }

    /// F3, in the source: no code writes the hints', the reactor's, the agent's or AI Advice's setting — only their
    /// Settings controls do, through bindings — so no change of plan takes them from the user.
    func testNoCodeWritesTheirSettings() throws {
        for (path, lines) in try sources(under: ["App", "Models", "Services", "Views", "Helpers"]) {
            for (index, line) in lines.enumerated() {
                for setting in ["proactiveEnabled", "realtimeScreenReactionEnabled", "browserAgentOn", "adviceEnabled"]
                where line.contains(setting) {
                    let assigns = line.range(of: #"\b\#(setting)\s*=[^=]"#, options: .regularExpression) != nil
                    let writesDefaults = (line.contains(".set(") || line.contains("removeObject("))
                        && line.contains("\"\(setting)\"")
                    XCTAssertFalse(assigns || writesDefaults, "\(path):\(index + 1) writes \(setting)")
                }
            }
        }
    }

    // MARK: - AI Advice (U1b)

    /// Off (U1b): AI Advice makes model calls from activity, like the hints, so it does not run — whatever its own
    /// toggle says — and a request to generate comes back with nothing.
    func testOffAIAdviceDoesNotRunWhateverItsToggle() async {
        let settings = AppSettings.shared
        let saved = settings.adviceEnabled
        defer { settings.adviceEnabled = saved }
        let advice = AdviceService(ultra: { false })
        for toggle in [true, false] {
            settings.adviceEnabled = toggle
            XCTAssertFalse(advice.isOn, "off, whatever the toggle: \(toggle)")
            let generated = await advice.generateAdvice()
            XCTAssertNil(generated)
            XCTAssertFalse(advice.isGenerating)
        }
    }

    /// On (U1b): it runs as its toggle says, as today.
    func testOnAIAdviceRunsAsItsToggleSays() {
        let settings = AppSettings.shared
        let saved = settings.adviceEnabled
        defer { settings.adviceEnabled = saved }
        let advice = AdviceService(ultra: { true })
        for toggle in [true, false] {
            settings.adviceEnabled = toggle
            XCTAssertEqual(advice.isOn, toggle, "on: the toggle decides")
        }
    }

    /// The gate's release: the switch is read at each ask, so turning it on lets advice run — no relaunch — and the
    /// toggle the user set is kept through off and on (F3).
    func testTheSwitchTurnedOnLetsAIAdviceRunWithTheToggleKept() {
        let settings = AppSettings.shared
        let saved = settings.adviceEnabled
        defer { settings.adviceEnabled = saved }
        settings.adviceEnabled = true
        var ultra = false
        let advice = AdviceService(ultra: { ultra })
        XCTAssertFalse(advice.isOn)
        XCTAssertTrue(settings.adviceEnabled, "the toggle is kept")
        ultra = true
        XCTAssertTrue(advice.isOn)
        XCTAssertTrue(settings.adviceEnabled)
    }

    /// Off while it waits (Codex P1, 1.4.0 review): Ultra turned off while the memories' embeddings are out — no
    /// relevance gate and no model is asked after it, nothing is saved and nothing shown. The switch used to be read
    /// once, at the start.
    func testUltraTurnedOffWhileTheEmbeddingsAreOutStopsBeforeTheGate() async throws {
        let run = try adviceRun()
        run.onEmbed = { run.ultra = false }
        let made = await run.advice.generate(contexts: [adviceScreen()], extraContext: nil)
        XCTAssertNil(made)
        XCTAssertEqual(run.asked, ["embeddings"], "nothing asked after the switch went off")
        try assertNothingKept(run)
    }

    /// …while the relevance gate is out: the gate's answer is not followed by a model request.
    func testUltraTurnedOffWhileTheGateIsOutSendsNoModelRequest() async throws {
        let run = try adviceRun()
        run.onGate = { run.ultra = false }
        let made = await run.advice.generate(contexts: [adviceScreen()], extraContext: nil)
        XCTAssertNil(made)
        XCTAssertEqual(run.asked, ["embeddings", "gate"])
        try assertNothingKept(run)
    }

    /// …while the model is answering — a request already sent ends — nothing is saved and nothing shown.
    func testUltraTurnedOffWhileTheModelAnswersKeepsAndShowsNothing() async throws {
        let run = try adviceRun()
        run.onModel = { run.ultra = false }
        let made = await run.advice.generate(contexts: [adviceScreen()], extraContext: nil)
        XCTAssertNil(made)
        XCTAssertEqual(run.asked, ["embeddings", "gate", "model"])
        try assertNothingKept(run)
    }

    /// The brother: off, a run asks nothing; Ultra turned back on, the next run goes all the way as today — gate,
    /// model, saved and shown.
    func testUltraTurnedBackOnAdviceRunsAllTheWayAgain() async throws {
        let run = try adviceRun()
        run.ultra = false
        let off = await run.advice.generate(contexts: [adviceScreen()], extraContext: nil)
        XCTAssertNil(off)
        XCTAssertTrue(run.asked.isEmpty)
        run.ultra = true
        let made = await run.advice.generate(contexts: [adviceScreen()], extraContext: nil)
        XCTAssertEqual(made?.content, "You dated the invoice 2025 - check the year")
        XCTAssertEqual(run.asked, ["embeddings", "gate", "model"])
        XCTAssertEqual(run.shown.map(\.content), ["You dated the invoice 2025 - check the year"])
        XCTAssertEqual(try run.store.mainContext.fetch(FetchDescriptor<AdviceItem>()).count, 1, "saved")
    }

    /// Both ways into the service ask the gate before anything else, and the app's service reads the real switch.
    func testAIAdviceAsksTheGateFirstAndTheAppReadsTheSwitch() throws {
        let lines = try codeLines(of: "Services/Intelligence/AdviceService.swift")
        for entry in ["func triggerOnTranscription(", "func generateAdvice("] {
            let statements = body(of: entry, in: lines).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            XCTAssertTrue(statements.first?.hasPrefix("guard isOn") == true, "\(entry) starts elsewhere: \(statements.first ?? "-")")
        }
        XCTAssertTrue(lines.contains { $0.contains("ultra: @escaping () -> Bool = { UltraFeatures.isOn() }") },
                      "the switch by default")
        for (path, code) in try sources(under: ["App", "Models", "Services", "Views", "Helpers"]) {
            for (index, line) in code.enumerated() where line.contains("AdviceService(") && !path.hasSuffix("AdviceService.swift") {
                XCTAssertFalse(line.contains("ultra:"), "\(path):\(index + 1) gives the app's service a switch of its own")
            }
        }
    }

    /// Off (U1b): Settings builds the AI Advice card only behind the switch; it holds the toggle's one control.
    func testSettingsBuildsAIAdviceOnlyBehindTheSwitch() throws {
        let lines = try codeLines(of: "Views/Windows/MainSettingsView.swift")
        let declaration = "private var adviceSection: some View"
        let uses = lines.indices.filter { lines[$0].contains("adviceSection") && !lines[$0].contains(declaration) }
        XCTAssertFalse(uses.isEmpty, "adviceSection is built somewhere")
        for index in uses {
            XCTAssertTrue(lines[index - 1].contains("if UltraFeatures.isOn() {"), "adviceSection built without the switch: \(lines[index])")
        }
        XCTAssertEqual(lines.filter { $0.contains("$settings.adviceEnabled") }.count, 1, "one control")
        XCTAssertTrue(body(of: declaration, in: lines).contains { $0.contains("$settings.adviceEnabled") })
    }

    // MARK: - Helpers

    /// One AI Advice run on Pro behind a switch of the test's own, the user's toggle on, its routes the test's —
    /// nothing reaches the network or the screen — and its store in memory. `on…` runs while that wait is out.
    @MainActor
    private final class AdviceRun {
        var ultra = true
        var asked: [String] = []
        var shown: [AdviceItem] = []
        var onEmbed: () -> Void = {}
        var onGate: () -> Void = {}
        var onModel: () -> Void = {}
        var advice: AdviceService!
        var store: ModelContainer!
    }

    private func adviceRun() throws -> AdviceRun {
        let settings = AppSettings.shared
        let savedToggle = settings.adviceEnabled
        addTeardownBlock { @MainActor in settings.adviceEnabled = savedToggle }
        settings.adviceEnabled = true
        let run = AdviceRun()
        let store = try container()
        let advice = AdviceService(ultra: { run.ultra })
        advice.configure(screenContext: ScreenContextService(), modelContainer: store)
        advice.routes = AdviceService.Routes(
            isPro: { true },
            licenseKey: { "LICENSE-1" },
            embed: { _ in run.asked.append("embeddings"); run.onEmbed(); return [1, 0] },
            gate: { _, _ in run.asked.append("gate"); run.onGate(); return (true, 0.9, "relevant", false) },
            proModel: { _, _, _ in
                run.asked.append("model")
                run.onModel()
                return #"{"type":"advice","headline":"Wrong year","content":"You dated the invoice 2025 - check the year","category":"productivity","confidence":0.9}"#
            },
            show: { run.shown.append($0) })
        run.advice = advice
        run.store = store
        return run
    }

    private func adviceScreen() -> ScreenContextService.ScreenContextSnapshot {
        .init(timestamp: Date(), appName: "Numbers", windowTitle: "Invoice 104", ocrText: "Invoice date 2025-10-25",
              bundleID: "test.numbers", windowID: nil, windowFrame: nil)
    }

    private func assertNothingKept(_ run: AdviceRun, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(run.shown.isEmpty, "nothing shown", file: file, line: line)
        XCTAssertNil(run.advice.latestAdvice, file: file, line: line)
        XCTAssertEqual(try run.store.mainContext.fetch(FetchDescriptor<AdviceItem>()).count, 0, "nothing saved",
                       file: file, line: line)
    }

    private func screen() -> ScreenContext {
        ScreenContext(appName: "Slack", windowTitle: "#launch", ocrText: "hello")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// What MetaChat sent its model, and what each tool call came back with.
    private final class Sent {
        var requests: [(rules: String, tools: [String])] = []
        var toolResults: [String] = []
    }

    /// MetaChat on `service`, wired as the app wires it — the executor asks the service whether an errand can run
    /// and starts it there — whose model calls `runErrand` first, then answers.
    private func metaChat(on service: AgentService) throws -> (ChatService, ChatToolExecutor, Sent) {
        let store = try container()
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: store)
        executor.canRunErrands = { service.canRunErrands }
        executor.startErrand = { goal, origin, output, start in
            service.start(goal: goal, origin: origin, output: output, start: start)
        }
        let chat = ChatService()
        chat.configure(modelContainer: store)
        chat.toolExecutor = executor
        chat.hasLLMAccess = { true }
        chat.proLicenseKey = { "LICENSE-1" }
        let sent = Sent()
        var replies = [ChatService.NativeChatResponse(
            text: "", toolCall: .init(id: "a", tool: "runErrand", args: ["goal": "find 10 jokes online"]),
            finishReason: "tool_calls")]
        chat.chatWithTools = { rules, messages, tools, _ in
            sent.requests.append((rules, tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }))
            if let last = messages.last, last["role"] as? String == "tool" {
                sent.toolResults.append(last["content"] as? String ?? "")
            }
            guard !replies.isEmpty else {
                return ChatService.NativeChatResponse(text: "Done.", toolCall: nil, finishReason: "stop")
            }
            return replies.removeFirst()
        }
        return (chat, executor, sent)
    }

    /// A service made as the app's is — its runs the brain's (`AgentRun.thinking`), Jev a recorded one — on the
    /// harness's browser, behind the switch, read at each ask; `made` hears each brain made for a run.
    private func brainService(_ h: AgentServiceHarness, ultra: @escaping @MainActor () -> Bool,
                              made: @escaping @MainActor () -> Void) -> AgentService {
        let jev = RecordedJev { _, _ in .answers() }
        return AgentService(link: h.link, keepAwake: KeepAwake(create: { 1 }, release: { _ in }),
                            store: ErrandRecordStore(directory: h.folder), notificationCenter: h.center,
                            isPro: { true },
                            makeRunner: AgentRun.thinking(brain: { made(); return SilentBrain() }, engine: jev.engine),
                            schedule: { _, _ in }, settings: h.settings.gated(by: ultra))
    }

    private static let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)
    private static let allStopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0,
                                                  notRun: .stoppedAll)

    /// The waits of an errand admitted with the switch on, before its run is made — and how many times the browser
    /// was asked by the switch's going off in each: never before its task ran or the Allow; once, by the errand
    /// itself, waiting for its browser; once, by the errand ahead of it, in the queue. Before its task ran no Allow is
    /// kept yet, so off then not even the disclosure shows.
    private enum ErrandWait: String, CaseIterable {
        case itsTask = "its task", theAllow = "the Allow", itsBrowser = "its browser", theQueue = "the queue"

        var browserAsks: Int { self == .itsTask || self == .theAllow ? 0 : 1 }
        var allowKept: Bool { self != .itsTask && self != .theAllow }
    }

    /// The switch, as a test turns it.
    private final class Ultra {
        var on = true
    }

    /// An errand admitted with the switch on and held in `wait`; there the switch goes off, then the wait ends: its
    /// task runs, the user allows, the browser connects, or the errand ahead of it finishes. The harness's runs stand
    /// for the app's — one made is a brain made.
    private func errand(heldIn wait: ErrandWait) async throws
        -> (h: AgentServiceHarness, service: AgentService, id: UUID, ultra: Ultra) {
        let h = AgentServiceHarness()
        let ultra = Ultra()
        if wait != .itsBrowser { h.link.connect() }
        h.allowed = wait.allowKept
        let service = h.makeService(settings: h.settings.gated(by: { ultra.on }))
        var ahead: FakeErrandRunner?
        if wait == .theQueue {
            let first = try XCTUnwrap(service.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id)
            ahead = await h.runner(for: first)
        }
        let id = try XCTUnwrap(service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id)
        switch wait {
        case .itsTask, .theQueue: break                  // its task has not run yet; it waits its turn
        case .theAllow: await h.until({ service.disclosure != nil }, "the disclosure")
        case .itsBrowser: await h.until({ h.link.waiting == 1 }, "the errand asking for its browser")
        }
        ultra.on = false
        switch wait {
        case .itsTask: break
        case .theAllow: service.allow()
        case .itsBrowser: h.link.connect()
        case .theQueue: ahead?.finish(ErrandOutcome(ending: .done, answer: "Ten jokes", sources: [], sheet: nil, rows: 0))
        }
        try await Task.sleep(for: .milliseconds(50))
        return (h, service, id, ultra)
    }

    /// A brain that answers nothing: whatever it is asked, it refuses.
    private final class SilentBrain: Brain, @unchecked Sendable {
        func think(_ messages: [CDPValue], tools: [CDPValue]) async throws -> ProLLMClient.Outcome {
            throw CancellationError()
        }
    }

    /// The form fill on a service of the test's own behind the switch, and how many times it filled.
    private func formFill(ultra: Bool) -> (ChatToolExecutor, () -> Int, AgentServiceHarness) {
        let h = AgentServiceHarness()
        let service = h.makeService(settings: h.settings.gated(by: { ultra }))
        let executor = ChatToolExecutor()
        executor.canRunErrands = { service.canRunErrands }
        var fills = 0
        executor.runHere = { _, _, _ in
            fills += 1
            return HereResult(filled: ["First Name"])
        }
        return (executor, { fills }, h)
    }

    /// …/Tests/MetaWhispTests/Services/License/UltraFeaturesTests.swift → the repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A source file's lines with line comments stripped: only code counts.
    private func codeLines(of path: String) throws -> [String] {
        try codeLines(String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    private func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }

    /// Every Swift file under `folders`, as code lines, by its path from the root.
    private func sources(under folders: [String]) throws -> [(path: String, lines: [String])] {
        var out: [(String, [String])] = []
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                out.append(("\(folder)/" + url.path.dropFirst(base.path.count + 1),
                            codeLines(try String(contentsOf: url, encoding: .utf8))))
            }
        }
        XCTAssertFalse(out.isEmpty, "the guard reads the sources")
        return out
    }

    /// A declaration's lines, from the one that declares it to the brace that closes it; braces in strings don't
    /// count.
    private func body(of declaration: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return [] }
        var depth = 0
        var opened = false
        var out: [String] = []
        for line in lines[start...] {
            out.append(line)
            var inString = false
            var escaped = false
            for character in line {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth == 0 { break }
        }
        return out
    }
}
