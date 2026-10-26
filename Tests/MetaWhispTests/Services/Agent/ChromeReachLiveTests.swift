import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-10 — the agent's hands, part 4, in a real Chrome (headless, a
/// profile of its own, the fixture pages served from inside Chrome): links
/// that act through the page's own script are clicked, a window a click opens
/// is opened in the agent's own tab and never as a window, BACK goes through
/// the tab's own history, a page's text cut by a limit is kept as far as it
/// was read, a tall panel scrolls when the page cannot, the controls on screen
/// are kept first, twins are told apart by their rows for Jev, a select in a
/// POST form asks the user, and a start page that lands on another site is
/// read. Stop during each new act ends the errand within its limit, and
/// nothing is done after it. Ported from a reference browser agent (MIT).
/// Skipped without Chrome.
final class ChromeReachLiveTests: XCTestCase {

    // MARK: - Helpers

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look", terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds, then DONE, keeping every request.
    private static func engine(_ picks: [@Sendable (Candidate) -> Bool]) -> (ScriptedEngine, Requests) {
        let requests = Requests()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            _ = requests.add(request)
            if turn.value < picks.count, let chosen = request.candidates.first(where: picks[turn.value]) {
                turn.add()
                return ScriptedEngine.pick(chosen)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        return (engine, requests)
    }

    private static func on(_ operation: AgentOperation, _ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == operation && $0.action.target?.name == name }
    }

    private static func page(_ operation: AgentOperation) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == operation && $0.action.target == nil }
    }

    @MainActor
    private func errand(_ world: ChromeWorld, from start: String, engine: ScriptedEngine,
                        bridge: (any BrowserBridge)? = nil,
                        confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                            = { _ in .no }) throws -> AgentRun {
        AgentRun(plan: try plan(start), errandID: UUID(),
                 collaborators: .init(bridge: bridge ?? world.bridge, engine: engine, writer: FakeWriter(),
                                      sheet: FixtureSheet(), confirm: confirm))
    }

    /// What the page shows, read in its own world.
    @MainActor
    private func inPage(_ script: String, _ tab: BrowserTab, _ world: ChromeWorld) async throws -> String {
        try await world.bridge.runInPage(script, in: tab)
    }

    /// Every window a page opened while the test ran: Chrome tells each new
    /// target, and a window has an opener.
    @MainActor
    private final class Windows {
        private(set) var opened: [String] = []
        private var listener: Task<Void, Never>?

        static func watch(_ world: ChromeWorld) async throws -> Windows {
            let windows = Windows()
            let events = await world.connection.events()
            windows.listener = Task { @MainActor [weak windows] in
                for await event in events where event.method == "Target.targetCreated" {
                    if let opener = event.params["targetInfo"]?["openerId"]?.string { windows?.opened.append(opener) }
                }
            }
            _ = try await world.connection.send("Target.setDiscoverTargets", params: ["discover": true])
            return windows
        }

        deinit { listener?.cancel() }
    }

    // MARK: - 1. Links that act through the page's script (critic 12)

    /// `href="#"`, `href="javascript:void(0)"` and `href=""` are clicked — the
    /// page's own script runs — never opened by their address; a link with a
    /// real address is still opened by it.
    @MainActor
    func testALinkThatActsThroughThePagesScriptIsClickedAndNeverOpened() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Load more"), Self.on(.click, "Show all"),
                                              Self.on(.click, "Refresh list")])
        let record = await (try errand(world, from: "https://site-231.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.filter { $0.operation == "click" }.count, 3, "\(record.eventLines)")
        let first = try XCTUnwrap(requests.all.first)
        let next = first.candidates.first { $0.action.target?.name == "Next page" }?.action
        XCTAssertEqual(next?.operation, .open)
        XCTAssertEqual(next?.destination, "https://site-231.test/next")
        XCTAssertFalse(first.candidates.contains { $0.action.operation == .open && $0.action.target?.name != "Next page" },
                       "no script link is opened by its address")
        let tab = try XCTUnwrap(hands.kept.first)
        let log = try await inPage("document.getElementById('log').textContent", tab, world)
        XCTAssertEqual(log, "more;all;again;", "the page's own script ran for each")
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-231.test/", "never sent to its address, not even with '#'")
    }

    // MARK: - 2. A window a click opens (critic 19)

    /// A click that opens a window: no window is opened at all — so it never
    /// asks for anything of its own — and the agent's tab opens its address
    /// instead; the step changed the page.
    @MainActor
    func testAWindowAClickOpensIsOpenedInTheAgentsOwnTabAndNeverAsAWindow() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let windows = try await Windows.watch(world)
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Open details")])
        let record = await (try errand(world, from: "https://site-230.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .acted, "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-230.test/details")
        XCTAssertEqual(requests.all.last?.page.url, "https://site-230.test/details", "the next look is there")
        XCTAssertEqual(windows.opened, [], "no window was ever opened")
        XCTAssertEqual(world.fixtures.served.filter { $0.path == "/details" }.count, 1, "asked for once: by the agent's tab")
    }

    /// A window to an address on the user's own machine or network: no
    /// window, no request anywhere, the agent's tab stays, the refusal is on
    /// record and the step failed.
    @MainActor
    func testAWindowToAPrivateAddressIsNeverOpenedAnywhere() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let windows = try await Windows.watch(world)
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Open router")])
        let record = await (try errand(world, from: "https://site-230.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.addressRefused), "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-230.test/")
        XCTAssertEqual(windows.opened, [], "no window was ever opened")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("127.0.0.1") }, "\(world.fixtures.blocked)")
    }

    /// A window with no address: none is opened, the tab stays, and the step
    /// is on record as having changed nothing.
    @MainActor
    func testAWindowWithNoAddressIsNeverOpenedAndTheStepChangedNothing() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let windows = try await Windows.watch(world)
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Open blank")])
        let record = await (try errand(world, from: "https://site-230.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertFalse(record.events.contains(.addressRefused), "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-230.test/")
        XCTAssertEqual(windows.opened, [])
    }

    /// A click that asks for a window and then shows a question of its own:
    /// the question is answered Cancel — asked without a Yes, or naming a
    /// payment, Cancel whatever the Yes — and the window's address is never
    /// opened: the click failed, or the errand ends at the user's part, before
    /// the agent does anything more (ITER-076 I-10 merged onto I-09's
    /// dialogs).
    @MainActor
    func testAWindowAskedForByAClickWhoseQuestionWasAnsweredCancelIsNeverOpened() async throws {
        for (button, log) in [("Open with a question", "blocked;stayed;"), ("Open offer", "blocked;not paid;")] {
            let world = try await ChromeWorld.start()
            defer { world.stop() }
            let windows = try await Windows.watch(world)
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, button)])
            let record = await (try errand(world, from: "https://site-230.test/", engine: engine, bridge: hands)).run()
            let tab = try XCTUnwrap(hands.kept.first)
            let shown = try await inPage("document.getElementById('log').textContent", tab, world)
            XCTAssertEqual(shown, log, "\(button): the premise — the window asked for, the question answered Cancel")
            let now = try await inPage("location.href", tab, world)
            XCTAssertEqual(now, "https://site-230.test/", button)
            XCTAssertEqual(world.fixtures.served.filter { $0.path == "/details" }.count, 0,
                           "\(button): never asked for: \(record.eventLines)")
            XCTAssertEqual(windows.opened, [], button)
            // A question naming a payment is Cancel as any other, and no one's part (owner decision of 2026-10-19).
            XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } },
                           "\(button): \(record.eventLines)")
            XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .failed, "\(button): \(record.eventLines)")
        }
    }

    /// A page cannot start a download of its own (ITER-076 I-10): the usual
    /// export — a file made in the page on a person's click, saved through a
    /// download link the page clicks itself — never begins, and nothing is
    /// saved.
    @MainActor
    func testAFileAPageMakesAndSavesItselfIsNeverDownloaded() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let began = Counter()
        let stream = await world.connection.events()
        let watching = Task {
            for await event in stream where event.method == "Page.downloadWillBegin" { began.add() }
        }
        defer { watching.cancel() }
        let (tab, page) = try await world.open("https://site-249.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Export the list"), on: page),
                                          in: tab)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        try await Task.sleep(for: .milliseconds(1_000))
        let log = try await inPage("document.getElementById('log').textContent", tab, world)
        XCTAssertEqual(log, "exported;", "the premise: the page tried")
        XCTAssertEqual(began.value, 0, "no download began")
        XCTAssertEqual(world.bridge.events(in: tab), [], "nothing to refuse")
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertEqual(saved, [])
    }

    /// A frame of the page that hands itself to another app through a custom
    /// scheme, on a person's click in it, goes nowhere: Chrome refuses it for
    /// the policy the agent's tab draws every document with, and never tries
    /// to open the app (ITER-076 I-10). Chrome's own words are read in the
    /// logs of the page and its frame: the only place it says which it did.
    @MainActor
    func testAFrameThatHandsItselfToAnotherAppThroughACustomSchemeGoesNowhere() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let stream = await world.connection.events()
        var entries: [String] = []
        var frameSession: String?
        let watching = Task { @MainActor in
            for await event in stream {
                if event.method == "Target.attachedToTarget", event.params["targetInfo"]?["type"]?.string == "iframe",
                   let session = event.params["sessionId"]?.string, frameSession == nil {
                    frameSession = session
                    _ = try? await world.connection.send("Log.enable", params: [:], sessionID: session)
                }
                if event.method == "Log.entryAdded", let text = event.params["entry"]?["text"]?.string {
                    entries.append(text)
                }
            }
        }
        defer { watching.cancel() }
        let (tab, _) = try await world.open("https://site-247.test/")
        _ = try await world.connection.send("Log.enable", params: [:], sessionID: tab.tabID)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(frameSession, "the premise: the frame is in a process of its own")
        let page = try await world.look(tab)
        let join = try XCTUnwrap(page.elements.first { $0.name == "Join in the app" })
        let place = tab.inFrame(join.frame)
        let action = AgentAction(operation: .click, target: join, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: place)
        let reached = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
        let at = try XCTUnwrap(reached)
        try await world.bridge.click(x: at.x, y: at.y, in: tab)
        try await Task.sleep(for: .milliseconds(1_500))
        let frame = try await world.bridge.run("location.href + ' ' + document.getElementById('log').textContent", in: place)
        XCTAssertEqual(frame, "https://site-246.test/ asked;", "the premise: the frame asked, and stayed")
        XCTAssertTrue(entries.contains { $0.contains("external protocol blocked by sandbox") }, "\(entries)")
        XCTAssertFalse(entries.contains { $0.contains("Failed to launch") }, "never tried to open an app: \(entries)")
    }

    /// A page that already sends a `Content-Security-Policy` of its own keeps
    /// it whole and gains the agent's tab's (ITER-076 I-10): its own policy
    /// still keeps its picture from loading, its scripts still run, and it
    /// still opens no window — even one that grants itself windows in a
    /// policy of its own, for the stricter of two policies holds.
    @MainActor
    func testAPagesOwnPolicyIsKeptWholeBesideTheTabs() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        func visit(_ query: String) async throws -> (picture: String, log: String) {
            let (tab, page) = try await world.open("https://site-248.test/" + query)
            let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Share this"), on: page),
                                              in: tab)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
            let picture = try await inPage("String(document.getElementById('pic').naturalWidth)", tab, world)
            let log = try await inPage("document.getElementById('log').textContent", tab, world)
            try await world.bridge.closeTab(tab)
            return (picture, log)
        }
        let plain = try await visit("")
        XCTAssertEqual(plain.picture, "1", "the premise: the picture loads with no policy of the page's own")
        XCTAssertEqual(plain.log, "ran;blocked;")
        let own = try await visit("?csp=img-src%20%27none%27")
        XCTAssertEqual(own.picture, "0", "the page's own policy holds")
        XCTAssertEqual(own.log, "ran;blocked;", "its scripts run, and it opens no window")
        let grants = try await visit("?csp=sandbox%20allow-scripts%20allow-same-origin%20allow-popups")
        XCTAssertEqual(grants.log, "ran;blocked;", "a page that grants itself windows still opens none")
        let tabs = try await world.agentTabCount()
        XCTAssertEqual(tabs, 0)
    }

    // MARK: - 3. Back through the tab's own history (critic 22)

    /// Text typed into a form, the next page, BACK: the form is back as it
    /// was left — the tab's own history kept it. On the first page there was
    /// nothing to go back to, and BACK was not offered.
    @MainActor
    func testBackGoesThroughTheTabsHistoryAndTheFormKeepsWhatWasTyped() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = FillsAtTheFirstLook(world.bridge, "document.getElementById('name').value = 'Alex'; ''")
        let (engine, requests) = Self.engine([Self.on(.open, "Next page"), Self.page(.back)])
        let record = await (try errand(world, from: "https://site-232.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.map(\.operation), ["open", "back", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertFalse(requests.all[0].candidates.contains { $0.action.operation == .back }, "the first page")
        XCTAssertTrue(requests.all[1].candidates.contains { $0.action.operation == .back })
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-232.test/")
        let typed = try await inPage("document.getElementById('name').value", tab, world)
        XCTAssertEqual(typed, "Alex", "what was typed is still there")
    }

    /// A page that rewrote its own history entry to an address it was never
    /// loaded from: BACK is not offered to it, and that address is never
    /// asked for (ITER-076 2.2, S1).
    @MainActor
    func testBackNeverGoesToAnAddressAPageWroteIntoItsHistory() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.on(.open, "Next site"), Self.page(.back)])
        let record = await (try errand(world, from: "https://site-233.test/", engine: engine)).run()
        XCTAssertEqual(record.steps.map(\.operation), ["open", "done"], "\(record.eventLines)")
        XCTAssertFalse(requests.all[1].candidates.contains { $0.action.operation == .back })
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/delete-account" })
    }

    /// An entry a form's sending made — a sort form that sends itself as its
    /// select changes — is never gone back to: going back may ask for its
    /// answer again. BACK goes to the entry before it.
    @MainActor
    func testBackPassesOverAnEntryAFormsSendingMade() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([{ $0.action.operation == .select && $0.action.payload == "Oldest" },
                                       Self.on(.open, "Next site"), Self.page(.back)])
        let record = await (try errand(world, from: "https://site-244.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.map(\.operation), ["select", "open", "back", "done"], "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let history = try await world.bridge.history(of: tab)
        XCTAssertTrue(history.entries.contains { $0.sentForm && $0.url == "https://site-244.test/?sort=Oldest" },
                      "the premise: the sent form made an entry: \(history)")
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-244.test/", "the entry before the sent form")
    }

    /// The page a step with the user's Yes led to is never gone back to:
    /// going back there may ask for it again. BACK goes to the entry before.
    @MainActor
    func testBackPassesOverThePageAYesLedTo() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Delete list"), Self.on(.open, "Next site"), Self.page(.back)])
        let record = await (try errand(world, from: "https://site-245.test/", engine: engine, bridge: hands,
                                       confirm: { _ in .yes })).run()
        XCTAssertEqual(record.steps.map(\.operation), ["click", "open", "back", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await inPage("location.href", tab, world)
        XCTAssertEqual(now, "https://site-245.test/", "the entry before the page the Yes led to")
    }

    // MARK: - 4. A page's text cut by a limit (critic 14)

    /// Far more words than a look carries: the first part is kept, up to the
    /// limit, and the look says the text was cut.
    @MainActor
    func testAPagesTextCutBySizeIsKeptAndSaysSo() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-234.test/")
        // The page's first words, read up to the limit and never past it (no
        // margin past it since I-09 round 5): of what was read, only
        // whitespace is squeezed out — the layout's line breaks and indents
        // around the heading, a space at the cut, 10 characters at most.
        let notes = "Notes " + (0..<2000).map { "Line \($0) of the notes." }.joined(separator: " ")
        XCTAssertTrue(notes.hasPrefix(page.text), String(page.text.suffix(40)))
        XCTAssertLessThanOrEqual(page.text.count, ObservedPage.maxText)
        XCTAssertGreaterThanOrEqual(page.text.count, ObservedPage.maxText - 10)
        XCTAssertTrue(page.text.hasPrefix("Notes Line 0 of the notes."), String(page.text.prefix(40)))
        XCTAssertTrue(page.textCut)
    }

    // MARK: - 5. A tall panel when the page cannot scroll (critic 16)

    /// SCROLL_DOWN on a page that cannot scroll moves its tall results panel
    /// — not the small list beside it — and the step took.
    @MainActor
    func testScrollMovesATallPanelWhenThePageCannotScroll() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.page(.scroll)])
        let record = await (try errand(world, from: "https://site-235.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.first?.outcome, .acted, "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let moved = try await inPage("[window.scrollY, document.getElementById('results').scrollTop > 0, "
                                     + "document.getElementById('tiny').scrollTop].join(' ')", tab, world)
        XCTAssertEqual(moved, "0 true 0")
    }

    /// A page that scrolls scrolls as before; its own panel stays.
    @MainActor
    func testScrollMovesThePageWhenItCan() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.page(.scroll)])
        let record = await (try errand(world, from: "https://site-236.test/", engine: engine, bridge: hands)).run()
        XCTAssertEqual(record.steps.first?.outcome, .acted, "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let moved = try await inPage("[window.scrollY > 0, document.getElementById('results').scrollTop].join(' ')",
                                     tab, world)
        XCTAssertEqual(moved, "true 0")
    }

    // MARK: - 6. Controls on screen first (critic 17)

    /// More controls than a look reports, the page scrolled to its end: the
    /// ones on screen are kept, and offered — in page order, with as many of
    /// the rest as fit (ITER-076 stage 3, № 65).
    @MainActor
    func testTheControlsOnScreenAreKeptAndOfferedOnAPageWithMoreThanALookReports() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-237.test/")
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.elements.count, ObserverScript.maxElements)
        XCTAssertEqual(page.elements.first { $0.name == "Item 600" }?.inViewport, true)
        let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
        let offered = set.candidates.compactMap(\.action.target)
        let onScreen = page.elements.filter(\.inViewport)
        XCTAssertFalse(onScreen.isEmpty)
        XCTAssertTrue(onScreen.allSatisfy { shown in offered.contains { $0.index == shown.index } },
                      "\(offered.map(\.name))")
        XCTAssertEqual(offered.count, CandidateBuilder.maxActions)
        let places = offered.compactMap { target in page.elements.firstIndex { $0.index == target.index } }
        XCTAssertEqual(places, places.sorted(), "in page order")
    }

    // MARK: - 7. Twins told apart for Jev (plan stage 4, item 10)

    /// Three "Add to cart" in three rows: each one's target, for Jev, carries
    /// its row — with the row context on, as it will be once the owner
    /// approves it; a control alone with its label carries nothing more, here
    /// and on a page with a single "Add to cart". Until then an errand's step
    /// goes out without it.
    @MainActor
    func testThreeAddToCartButtonsAreToldApartByTheirRowsForJev() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        func contexts(_ address: String) async throws -> [String: [String?]] {
            let (_, page) = try await world.open(address)
            let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
            let request = ChooseRequest(candidates: set.candidates, subgoal: .init(description: "Buy", terms: []),
                                        rowsCollected: 0, rowsWanted: 1, goal: "Buy a green mug",
                                        page: PageSummary(url: page.url, title: page.title, text: page.text),
                                        recentActions: [])
            let step = try JevDecisionEngine.step(for: request, rowContext: true)
            guard case .choice(let clicks)? = step.questions["click_target"]?.kind else { return [:] }
            var found: [String: [String?]] = [:]
            for option in clicks {
                guard case .object(let fields)? = option.description, case .string(let element)? = fields["element"]
                else { continue }
                let label = String(element.drop { $0 != " " }.dropFirst())
                var context: String?
                if case .string(let row)? = fields["context"] { context = row }
                found[label, default: []].append(context)
            }
            return found
        }
        let mugs = try await contexts("https://site-238.test/")
        XCTAssertEqual(mugs["Add to cart"], ["Blue mug", "Green mug", "Red mug"])
        XCTAssertEqual(mugs["Buy the gift card"], [nil])
        let teapot = try await contexts("https://site-239.test/")
        XCTAssertEqual(teapot["Add to cart"], [nil], "a single one is described as before")
        // Approved by the owner on 2026-10-06 (item 8): an errand's step goes out with it.
        let jev = RecordedJev { _, _ in .answers(operation: "DONE") }
        let run = AgentRun(plan: try plan("https://site-238.test/"), errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        _ = await run.run()
        let steps = jev.bodies.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains(#""operation""#) }
        XCTAssertFalse(steps.isEmpty)
        XCTAssertTrue(steps.allSatisfy { $0.contains("Add to cart") && $0.contains(#""context""#)
            && $0.contains("Green mug") }, "\(steps)")
    }

    // MARK: - 8. Checked, not rebuilt (critics 27 and 11)

    /// A select whose change sends its POST form — the form has a submit
    /// button too — asks the user's Yes; a No sends nothing.
    @MainActor
    func testASelectWhoseChangeSendsAPostFormAsksTheUsersYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([{ $0.action.operation == .select && $0.action.payload == "Oldest" }])
        let asked = Counter()
        let record = await (try errand(world, from: "https://site-240.test/", engine: engine, confirm: { _ in
            asked.add()
            return .no
        })).run()
        XCTAssertEqual(asked.value, 1, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first { $0.operation == "select" }?.outcome, .refused)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/orders" }, "a No sends nothing")
    }

    /// A start address a server sends to another site is read where it
    /// landed, and the errand goes on.
    @MainActor
    func testAStartPageThatRedirectsToAnotherSiteIsRead() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([])
        let start = "https://site-243.test/redirect?to=https%3A%2F%2Fsite-241.test%2F"
        let record = await (try errand(world, from: start, engine: engine)).run()
        XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
        XCTAssertEqual(requests.all.first?.page.url, "https://site-241.test/")
        XCTAssertEqual(requests.all.first?.page.title, "Site Two Hundred Forty-One")
    }

    /// A page a site sends an open to on a host of its own — google.com's
    /// consent page, `consent.google.com` — is where the open landed, not a
    /// miss (ITER-076 stage 3, № 121).
    @MainActor
    func testAnOpenTheSiteSendsToItsOwnConsentPageIsNoMiss() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.on(.open, "Search recipes")])
        let record = await (try errand(world, from: "https://site-414.test/", engine: engine)).run()
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .acted, "\(record.eventLines)")
        XCTAssertFalse(record.events.map(\.shape).contains("miss settle"), "\(record.eventLines)")
        XCTAssertEqual(requests.all.last.map { URL(string: $0.page.url)?.host }, "consent.site-414.test")
    }

    // MARK: - Stop during each new act

    /// Stop the moment BACK, a click that opens a window, a scroll of a panel
    /// or a click on a script link went out: the errand ends within Stop's
    /// limit, nothing more is done — a window's address is never opened —
    /// and no tab is left.
    @MainActor
    func testStopDuringEachNewActEndsWithinTheLimitAndNothingIsDoneAfter() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let cases: [(String, [@Sendable (Candidate) -> Bool], StopsAtTheAct.Act)] = [
            ("https://site-232.test/", [Self.on(.open, "Next page"), Self.page(.back)], .back),
            ("https://site-230.test/", [Self.on(.click, "Open details")], .click),
            ("https://site-235.test/", [Self.page(.scroll)], .scroll),
            ("https://site-231.test/", [Self.on(.click, "Load more")], .click),
        ]
        for (start, picks, act) in cases {
            let hands = StopsAtTheAct(world.bridge, at: act)
            let (engine, _) = Self.engine(picks)
            let run = try errand(world, from: start, engine: engine, bridge: hands)
            var stoppedAt: ContinuousClock.Instant?
            hands.stop = {
                stoppedAt = .now
                run.stop()
            }
            let outcome = await run.run(report: { _ in })
            let returned = ContinuousClock.now
            XCTAssertEqual(outcome.ending, .stopped, start)
            let stopped = try XCTUnwrap(stoppedAt, start)
            XCTAssertLessThan(returned - stopped, AgentRun.stopLimit, start)
            XCTAssertEqual(hands.acts, 1, "\(start): nothing acted after Stop")
            let tabs = try await world.agentTabCount()
            XCTAssertEqual(tabs, 0, start)
        }
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/details" }, "a window's address is not opened after Stop")
    }
}

/// The agent's hands in Chrome, whose tab is left open when the errand
/// closes it, and which writes into the page — as a person would have typed —
/// right before the errand's first look.
@MainActor
final class FillsAtTheFirstLook: WrapsChromeBridge {
    let inner: ChromeBridge
    private let script: String
    private var filled = false
    private(set) var kept: [BrowserTab] = []

    init(_ inner: ChromeBridge, _ script: String) {
        self.inner = inner
        self.script = script
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if !filled, javascript == ObserverScript.source {
            filled = true
            _ = try await inner.runInPage(script, in: tab)
        }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, pressing Stop the moment one kind of act went
/// out — BACK, a click, or a scroll's script — and counting the acts that
/// went out at all.
@MainActor
final class StopsAtTheAct: WrapsChromeBridge {
    enum Act { case back, click, scroll }

    let inner: ChromeBridge
    private let act: Act
    var stop: () -> Void = {}
    /// Acts of the kind watched that went out.
    private(set) var acts = 0

    init(_ inner: ChromeBridge, at act: Act) {
        self.inner = inner
        self.act = act
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        try await inner.click(x: x, y: y, in: tab)
        if act == .click { went() }
    }

    func goBack(to entry: Int, in tab: BrowserTab) async throws {
        try await inner.goBack(to: entry, in: tab)
        if act == .back { went() }
    }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        let answer = try await inner.run(javascript, in: tab)
        if act == .scroll, javascript.contains("scrollBy") { went() }
        // A window's address opened in the tab after Stop would come here.
        if act == .click, acts > 0, javascript.hasPrefix("(() => {\nconst [destination") { acts += 1 }
        return answer
    }

    private func went() {
        acts += 1
        if acts == 1 { stop() }
    }
}
