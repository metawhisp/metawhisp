import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-09 — frames, in a real Chrome (headless, a profile of its own,
/// the fixture pages served from inside Chrome): a frame of the page's own
/// origin and one from another site — in a process of its own, attached to the
/// agent's tab only — are read and acted on under every rule the page is; a
/// control carries its frame; a sign-in or a card form from another site is
/// the user's part; a frame the page lays a layer over is never clicked
/// through it; a frame's dialogs, downloads and addresses are guarded as the
/// page's are. Ported from a reference browser agent (MIT). Skipped without
/// Chrome.
final class ChromeFramesLiveTests: XCTestCase {

    // MARK: - Helpers

    /// A person's click on `element`, in its frame: aimed there, brought to
    /// the tab's viewport, pressed.
    @MainActor
    private func press(_ element: ObservedElement, on page: ObservedPage, in tab: BrowserTab,
                       _ world: ChromeWorld) async throws {
        let place = tab.inFrame(element.frame)
        let action = AgentAction(operation: .click, target: element, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: place)
        XCTAssertEqual(aim.outcome, .aim, element.name)
        let point = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
        let at = try XCTUnwrap(point, "\(element.name) reaches its frame")
        try await world.bridge.click(x: at.x, y: at.y, in: tab)
    }

    @MainActor
    private func named(_ name: String, in page: ObservedPage, file: StaticString = #filePath,
                       line: UInt = #line) throws -> ObservedElement {
        try XCTUnwrap(page.elements.first { $0.name == name }, name, file: file, line: line)
    }

    /// Waits — 10 s at most, where a second is plenty — for `script` to
    /// answer `expected` in `tab`.
    @MainActor
    private func wait(for expected: String, from script: String, in tab: BrowserTab, _ world: ChromeWorld,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        var last: String?
        while Date() < deadline {
            last = try? await world.bridge.run(script, in: tab)
            if last == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(script) answered \(last ?? "nothing"), not \(expected)", file: file, line: line)
    }

    /// The log of the document `control` is in — its frame's, or the
    /// page's — read in the agent's own world: what that document did.
    @MainActor
    private func log(of control: String, in tab: BrowserTab, _ world: ChromeWorld) async throws -> String {
        let page = try await world.look(tab)
        return try await world.bridge.run("document.getElementById('log').textContent",
                                          in: tab.inFrame(try named(control, in: page).frame))
    }

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look", terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds, then DONE, keeping every request.
    private static func engine(_ picks: [@Sendable (Candidate) -> Bool],
                               irreversible: @escaping @Sendable (AgentAction) -> Double = { _ in 0.05 })
        -> (ScriptedEngine, Requests) {
        let requests = Requests()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            _ = requests.add(request)
            if turn.value < picks.count, let chosen = request.candidates.first(where: picks[turn.value]) {
                turn.add()
                return ScriptedEngine.pick(chosen)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: irreversible)
        return (engine, requests)
    }

    private static let waits: @Sendable (Candidate) -> Bool = { $0.action.operation == .wait }

    private static func on(_ operation: AgentOperation, _ name: String, payload: String? = nil)
        -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == operation && $0.action.target?.name == name && $0.action.payload == payload }
    }

    @MainActor
    private func run(_ world: ChromeWorld, from start: String, engine: ScriptedEngine, bridge: (any BrowserBridge)? = nil,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no }) throws -> AgentRun {
        AgentRun(plan: try plan(start), errandID: UUID(),
                 collaborators: .init(bridge: bridge ?? world.bridge, engine: engine, writer: FakeWriter(),
                                      sheet: FixtureSheet(), confirm: confirm))
    }

    // MARK: - Every frame read

    /// A frame of the page's own origin, one from another site in a process
    /// of its own, a frame inside that one of its own site and one of a third
    /// site: every control in each is read, each carrying its own frame, and
    /// each answers to its frame's address.
    @MainActor
    func testEveryFrameIsReadWithItsControlsEachCarryingItsFrame() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-170.test/")
        let page = try await world.look(tab)
        XCTAssertNil(try named("Top button", in: page).frame)
        let same = try XCTUnwrap(try named("Book", in: page).frame)
        XCTAssertEqual(try named("Guests", in: page).frame, same)
        let other = try XCTUnwrap(try named("Reserve", in: page).frame)
        XCTAssertEqual(try named("Email", in: page).frame, other)
        let nested = try XCTUnwrap(try named("Nested inside", in: page).frame)
        let deep = try XCTUnwrap(try named("Deep button", in: page).frame)
        XCTAssertEqual(Set([same, other, nested, deep]).count, 4, "four frames")
        XCTAssertEqual(page.address(of: try named("Reserve", in: page)), "https://site-171.test/")
        XCTAssertEqual(page.address(of: try named("Deep button", in: page)), "https://site-172.test/")
        XCTAssertEqual(page.address(of: try named("Top button", in: page)), "https://site-170.test/")
    }

    /// A frame that comes after the first look is read on the next.
    @MainActor
    func testAFrameThatComesAfterTheFirstLookIsReadOnTheNext() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-174.test/")
        let first = try await world.look(tab)
        XCTAssertFalse(first.elements.contains { $0.name == "Deep button" })
        let deadline = Date().addingTimeInterval(10)
        var later = first
        while Date() < deadline, !later.elements.contains(where: { $0.name == "Deep button" }) {
            try await Task.sleep(for: .milliseconds(100))
            later = try await world.look(tab)
        }
        XCTAssertNotNil(try named("Deep button", in: later).frame)
    }

    // MARK: - Acted on as the page is

    /// A person's click and typing reach a control in a frame — of the page's
    /// origin, of another site, inside that one, and of a third site — and a
    /// select there is chosen as the page's are.
    @MainActor
    func testAControlInAFrameIsClickedAndTypedInAsAPersonDoes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-170.test/")
        let page = try await world.look(tab)
        for (field, text) in [("Guests", "4"), ("Email", "guest@site-171.test")] {
            let target = try named(field, in: page)
            let place = tab.inFrame(target.frame)
            let action = AgentAction(operation: .type, target: target, destination: nil, payload: text,
                                     isPlannedSearch: false)
            let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: place)
            XCTAssertEqual(aim.outcome, .aim, field)
            let reached = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
            let at = try XCTUnwrap(reached, field)
            try await world.bridge.click(x: at.x, y: at.y, in: tab)
            let bridge = world.bridge
            let typed = try await TrustedTyping.type(action, on: page, approval: nil,
                                                     read: { try? await bridge.run($0, in: place) }, stopping: { false })
            XCTAssertEqual(typed, .typed(.init(held: true, suggests: false)), field)
        }
        let seating = try named("Seating", in: page)
        let select = AgentAction(operation: .select, target: seating, destination: nil, payload: "Terrace",
                                 isPlannedSearch: false)
        let chosen = try await world.outcome(ActionScript.source(for: select, on: page), in: tab.inFrame(seating.frame))
        XCTAssertEqual(chosen.outcome, .done)
        try await press(try named("Book", in: page), on: page, in: tab, world)
        try await press(try named("Reserve", in: page), on: page, in: tab, world)
        try await press(try named("Nested inside", in: page), on: page, in: tab, world)
        try await press(try named("Deep button", in: page), on: page, in: tab, world)
        try await wait(for: "booked 4 Terrace;", from: "document.getElementById('log').textContent", in: tab, world)
        let widget = tab.inFrame(try named("Reserve", in: page).frame)
        try await wait(for: "reserved guest@site-171.test;", from: "document.getElementById('log').textContent",
                       in: widget, world)
        try await wait(for: "nested pressed", from: "document.title", in: tab.inFrame(try named("Nested inside", in: page).frame),
                       world)
        try await wait(for: "deep;", from: "document.getElementById('log').textContent",
                       in: tab.inFrame(try named("Deep button", in: page).frame), world)
        let top = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertFalse(top.contains("top;"), "no click went to the page's own button: \(top)")
    }

    /// The same widget twice: its controls differ by nothing but the frame
    /// that holds them — twins, never offered (Claude review c7 of I-09, #4).
    /// A widget the page lays a layer over is never clicked through the
    /// layer: nothing is pressed at all.
    @MainActor
    func testTwinWidgetsAreTwinsAndALayerOverAFrameIsNeverClickedThrough() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-173.test/")
        let page = try await world.look(tab)
        let twins = page.elements.filter { $0.name == "Deep button" }
        guard twins.count == 2 else { return XCTFail("two widgets, two buttons: \(twins.count)") }
        XCTAssertNotEqual(twins[0].frame, twins[1].frame)
        XCTAssertEqual(twins[0].fingerprint, twins[1].fingerprint)
        let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: ["deep"]))
        XCTAssertFalse(set.candidates.contains { $0.action.target?.name == "Deep button" }, "never offered")
        let covered = try named("Under the layer", in: page)
        let place = tab.inFrame(covered.frame)
        let aim = try await world.outcome(ActionScript.aim(for: AgentAction(operation: .click, target: covered,
                                                                             destination: nil, payload: nil,
                                                                             isPlannedSearch: false), on: page),
                                          in: place)
        XCTAssertEqual(aim.outcome, .aim, "nothing in its own frame covers it")
        let point = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
        XCTAssertNil(point, "the page's layer covers the frame there")
    }

    /// A frame below the fold — of another site, a third site's inside it
    /// below that one's own fold, and one of the page's own — is brought on
    /// screen and clicked where it is drawn.
    @MainActor
    func testAFrameBelowTheFoldIsBroughtOnScreenAndClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-181.test/")
        let page = try await world.look(tab)
        try await press(try named("Widget top", in: page), on: page, in: tab, world)
        try await wait(for: "widget pressed", from: "document.title", in: tab.inFrame(try named("Widget top", in: page).frame),
                       world)
        try await press(try named("Deep button", in: page), on: page, in: tab, world)
        try await wait(for: "deep;", from: "document.getElementById('log').textContent",
                       in: tab.inFrame(try named("Deep button", in: page).frame), world)
        try await press(try named("Low inside", in: page), on: page, in: tab, world)
        try await wait(for: "low pressed", from: "document.title", in: tab.inFrame(try named("Low inside", in: page).frame),
                       world)
    }

    /// A frame that is gone — taken out of the page with the frames inside
    /// it — is reached nowhere and read as a script that failed, never as the
    /// tab lost: the tab goes on.
    @MainActor
    func testAFrameThatIsGoneIsReachedNowhereAndTheTabGoesOn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-170.test/")
        let page = try await world.look(tab)
        let reserve = tab.inFrame(try named("Reserve", in: page).frame)
        let nested = tab.inFrame(try named("Nested inside", in: page).frame)
        _ = try await world.bridge.runInPage("document.getElementById('other').remove(), 'gone'", in: tab)
        try await Task.sleep(for: .milliseconds(300))
        for frame in [reserve, nested] {
            let reached = try await world.bridge.point(x: 10, y: 10, in: frame)
            XCTAssertNil(reached)
            do {
                _ = try await world.bridge.run("document.title", in: frame)
                XCTFail("a frame that is gone runs nothing")
            } catch let error as BrowserBridgeError {
                guard case .scriptFailed = error else { return XCTFail("\(error)") }
            }
        }
        let title = try await world.bridge.run("String(1 + 1)", in: tab)
        XCTAssertEqual(title, "2")
    }

    // MARK: - A frame's dialogs, downloads and addresses

    /// A frame from another site is guarded as the page is: its alert is
    /// closed, its confirm without a Yes is Cancel, its download is refused
    /// with nothing saved — one it would start itself, through a `download`
    /// link, never begins (ITER-076 I-10) — and its own way to the user's
    /// network is stopped at the request.
    @MainActor
    func testAFramesDialogsDownloadsAndAddressesAreGuarded() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-179.test/")
        let page = try await world.look(tab)
        let widget = tab.inFrame(try named("Remove widget", in: page).frame)
        try await wait(for: "loaded;", from: "document.getElementById('log').textContent", in: widget, world)
        var seen = world.bridge.events(in: tab)
        XCTAssertEqual(seen, [.dialog(.alert, accepted: true)])
        try await press(try named("Remove widget", in: page), on: page, in: tab, world)
        try await wait(for: "loaded;kept;", from: "document.getElementById('log').textContent", in: widget, world)
        seen = world.bridge.events(in: tab)
        XCTAssertEqual(seen, [.dialog(.confirm, accepted: false)])
        try await press(try named("The terms", in: page), on: page, in: tab, world)
        try await press(try named("The widget notes", in: page), on: page, in: tab, world)
        try await press(try named("Open the router", in: page), on: page, in: tab, world)
        let deadline = Date().addingTimeInterval(10)
        seen = []
        while Date() < deadline, seen.count < 2 {
            seen += world.bridge.events(in: tab)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(500))
        seen += world.bridge.events(in: tab)
        XCTAssertEqual(seen.map { "\($0)" }.sorted(), ["addressRefused", "downloadRefused"], "\(seen)")
        try await Task.sleep(for: .milliseconds(300))
        // The terms are refused before Chrome begins to save them. The notes,
        // a `download` link, are cancelled as they begin: Chrome may have
        // written so small a file whole by then — a known limit (Claude
        // review c7 of I-09, #22).
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertFalse(saved.contains { $0.hasPrefix("terms") }, "\(saved)")
        XCTAssertFalse(world.fixtures.blocked.contains { $0.contains("192.168.") }, "\(world.fixtures.blocked)")
        let still = try await world.bridge.run("location.href", in: widget)
        XCTAssertEqual(still, "https://site-180.test/")
    }

    // MARK: - The errand, in frames

    /// A step on a control in a frame is taken as one on the page is: a
    /// click deep in a third site's frame, a choice in a select of the page's
    /// own frame, and a link in a frame, opened by its own address in the tab.
    @MainActor
    func testAStepOnAControlInAFrameIsTakenAsOnThePage() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.on(.click, "Deep button"), Self.on(.select, "Seating", payload: "Terrace"),
                                       { $0.action.operation == .open && $0.action.target?.name == "More about us" }])
        let record = try await run(world, from: "https://site-170.test/", engine: engine).run()
        XCTAssertEqual(record.steps.map(\.operation), ["click", "select", "open", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(record.ending, .done)
    }

    /// A card form from a payment provider's site, in its frame: none of its
    /// controls is touched — the step is the user's payment — neither the one
    /// beside the card nor one in a form of its own, which only its frame
    /// makes the user's; and the page's own button, whose words name no
    /// payment, on a page that takes one, is the user's too. Nothing pressed
    /// anywhere (review of I-09, tests F3).
    @MainActor
    func testACardFrameFromAnotherSiteIsTheUsersPayment() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for name in ["Save card", "Apply a coupon", "Confirm"] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, requests) = Self.engine([Self.on(.click, name)])
            let asked = Counter()
            let record = try await run(world, from: "https://site-175.test/", engine: engine, bridge: hands, confirm: { _ in
                asked.add()
                return .yes
            }).run()
            XCTAssertTrue(requests.all.first?.candidates.contains { $0.action.target?.name == name } == true, name)
            XCTAssertEqual(record.ending, .needsUser, "\(name): \(record.eventLines)")
            XCTAssertTrue(record.events.contains { if case .handover(.payment, _) = $0 { true } else { false } },
                          "\(name): \(record.eventLines)")
            XCTAssertEqual(asked.value, 0, "\(name): never asked, never paid")
            let tab = try XCTUnwrap(hands.kept.first)
            for control in ["Save card", "Confirm"] {
                let log = try await log(of: control, in: tab, world)
                XCTAssertEqual(log, "", "\(name): nothing pressed where \(control) is")
            }
        }
    }

    /// A sign-in from another site, in its frame: its controls are the
    /// user's part — one in the sign-in's form, and one outside it, which
    /// only its frame makes the user's. Nothing pressed (review of I-09,
    /// tests F3).
    @MainActor
    func testASignInFrameFromAnotherSiteIsTheUsers() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for name in ["Next", "Trouble signing in"] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)])
            let record = try await run(world, from: "https://site-177.test/", engine: engine, bridge: hands).run()
            XCTAssertEqual(record.ending, .needsUser, "\(name): \(record.eventLines)")
            XCTAssertTrue(record.events.contains { if case .handover(.signIn, _) = $0 { true } else { false } },
                          "\(name): \(record.eventLines)")
            let log = try await log(of: "Next", in: try XCTUnwrap(hands.kept.first), world)
            XCTAssertEqual(log, "", "\(name): nothing pressed")
        }
    }

    /// A consent page of the page's own site, in a frame — its address asks
    /// for access by OAuth — makes the page the user's grant, as that address
    /// on the page itself does: nothing on it is chosen or pressed (review of
    /// I-09, F3).
    @MainActor
    func testAFrameWhoseAddressAsksForAGrantIsTheUsersWhateverItsSite() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Confirm")])
        let record = try await run(world, from: "https://site-198.test/", engine: engine, bridge: hands).run()
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.grant, host: "site-198.test")), "\(record.eventLines)")
        XCTAssertTrue(record.steps.isEmpty, "\(record.eventLines)")
        XCTAssertTrue(requests.all.isEmpty, "nothing chosen")
        let tab = try XCTUnwrap(hands.kept.first)
        for control in ["Confirm", "Continue"] {
            let log = try await log(of: control, in: tab, world)
            XCTAssertEqual(log, "", "nothing pressed where \(control) is")
        }
    }

    /// An identity provider's account chooser from another site, in its
    /// frame — no password, no form — is the user's sign-in: offered, never
    /// asked about, never pressed (review of I-09, F6).
    @MainActor
    func testAnAccountChooserFromAnotherSiteIsTheUsersSignIn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Continue as Sam")])
        let asked = Counter()
        let record = try await run(world, from: "https://site-200.test/", engine: engine, bridge: hands, confirm: { _ in
            asked.add()
            return .yes
        }).run()
        XCTAssertTrue(requests.all.first?.candidates.contains { $0.action.target?.name == "Continue as Sam" } == true)
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.signIn, host: "site-200.test")), "\(record.eventLines)")
        XCTAssertEqual(asked.value, 0)
        let log = try await log(of: "Continue as Sam", in: try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "", "never pressed")
    }

    // MARK: - Who a frame is (review of I-09, F5)

    /// Who a frame is holds across a reload — the page's own, another site's
    /// in a process of its own, the page's own inside that one, and a third
    /// site's — though the browser gives every one of them a new id. The
    /// frames are listed as the page goes and comes, each listing in a
    /// moment: a frame that went with the page that held it — on whose
    /// session the browser answers nothing — holds no look up, then or after.
    @MainActor
    func testAFramesIdentityHoldsAcrossAReload() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-170.test/")
        let before = try await frames(of: tab, world, until: { $0.count == 4 })
        let who = Set(before.map(\.identity))
        XCTAssertEqual(who.count, 4, "\(before)")
        let old = Set(before.compactMap(\.tab.frame))
        _ = try? await world.bridge.runInPage("setTimeout(() => location.reload(), 0), 'x'", in: tab)
        // Each frame made anew — a new id — and known as who it was.
        let after = try await frames(of: tab, world, until: { listed in
            listed.count == 4 && Set(listed.map(\.identity)) == who && listed.allSatisfy { !old.contains($0.tab.frame ?? "") }
        })
        XCTAssertEqual(Set(after.map(\.identity)), who)
        let began = ContinuousClock.now
        let again = try await world.bridge.frames(of: tab)
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1_500), "no frame that went is asked")
        XCTAssertEqual(again.frames, after)
        XCTAssertEqual(again.unread, 0)
    }

    /// A frame in a process of its own that does not say what it holds — as
    /// one going with the page that held it does not — holds no listing up:
    /// it is left out of it, in a moment, and the page's own frame is listed.
    /// Each frame left out is counted, not each frame that said nothing: the
    /// widget of another site, the frame of its own site inside it — as the
    /// widget last held it — and the third site's frame (Codex review 2 of
    /// I-09, P2-5).
    @MainActor
    func testAFrameThatNeverAnswersHoldsNoListingUp() async throws {
        let chrome = try await TestChrome.launch()
        let proxy = try await CDPProxy.start(to: chrome.endpoint.webSocketURL)
        let connection = CDPConnection(url: proxy.url)
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let bridge = ChromeBridge(connection: connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        defer {
            fixtures.stop()
            Task { await connection.close() }
            proxy.stop()
            chrome.quit()
        }
        let tab = try await bridge.openTab(URL(string: "https://site-170.test/")!)
        let deadline = Date().addingTimeInterval(10)
        var listed: [BrowserFrame] = []
        while Date() < deadline, listed.count < 4 {
            listed = (try? await bridge.frames(of: tab))?.frames ?? []
            if listed.count < 4 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(listed.count, 4, "\(listed)")
        let page = "\"sessionId\":\"\(tab.tabID)\""
        proxy.holdsReply = { $0.contains("Page.getFrameTree") && $0.contains("sessionId") && !$0.contains(page) }
        proxy.onHeld = { _ in }
        let began = ContinuousClock.now
        let held = try await bridge.frames(of: tab)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(8), "no listing held up")
        XCTAssertEqual(held.frames.map(\.identity), ["/://"], "the page's own frame: \(held)")
        XCTAssertEqual(held.unread, 3, "the three frames left out, each counted: \(held)")
        XCTAssertEqual(held.unknown, 0, "each was listed before: what it holds is known")
    }

    /// A frame in a process of its own whose setup fails before it runs —
    /// its requests could not be guarded — never runs, and is never left out
    /// silently: Chrome keeps the document that stood in it in its holder's
    /// process, and that one is listed — once (Codex review 2 of I-09, P2-5).
    @MainActor
    func testAFrameWhoseSetupFailsBeforeItRunsIsNeverLeftOut() async throws {
        let chrome = try await TestChrome.launch()
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let page = FirstTime()
        // The page's own setup goes through; a frame's fails.
        let bridge = ChromeBridge(connection: connection, prepareTab: { session in
            guard page.take() else { throw BrowserBridgeError.scriptFailed(code: -1) }
            try await fixtures.serve(session)
        }, resolve: ChromeFixtures.resolve)
        defer {
            fixtures.stop()
            Task { await connection.close() }
            chrome.quit()
        }
        let events = await connection.events()
        let tab = try await bridge.openTab(URL(string: "https://site-170.test/")!)
        // The widget of another site is attached, and its setup fails.
        let attached = await Deadline.run(within: .seconds(10)) { () -> String? in
            for await event in events where event.method == "Target.attachedToTarget"
                && event.params["targetInfo"]?["type"]?.string == "iframe" {
                return event.params["targetInfo"]?["targetId"]?.string
            }
            return nil
        } ?? nil
        let widget = try XCTUnwrap(attached, "the widget is attached")
        try await Task.sleep(for: .seconds(1))
        let began = ContinuousClock.now
        let listing = try await bridge.frames(of: tab)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(3), "no listing held up")
        // The document that stood in the frame before it went to a process
        // of its own — blank — is still there, in the page's: listed, and
        // read as the user sees it. Not counted as well.
        XCTAssertTrue(listing.frames.contains { $0.tab.frame == widget }, "the widget's frame is listed: \(listing)")
        XCTAssertEqual(listing.unread, 0, "\(listing)")
        XCTAssertEqual(listing.unknown, 0, "\(listing)")
        XCTAssertFalse(listing.frames.contains { $0.identity.contains("site-171") }, "it never ran: \(listing)")
        let read = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab.inFrame(widget)))
        XCTAssertTrue(read.elements.isEmpty, "blank, as the user sees it")
    }

    /// A frame in a process of its own that went with the frame that held it
    /// — the browser does not say so of it — is never asked what it holds:
    /// after a reload a listing takes a moment, though the answer of any
    /// such frame is held for good, and it lists the frames there are, none
    /// left out (Claude review c7 of I-09, #19).
    @MainActor
    func testAFrameThatWentWithItsHolderIsNeverAsked() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        let (tab, _) = try await world.open("https://site-170.test/")
        let before = try await frames(of: tab, world, until: { $0.map(\.identity) == Self.site170Frames })
        // Every session a frame of another site was asked on before the
        // reload: the widget's, and the third site's inside it.
        let asked = Set(proxy.messages.compactMap { try? CDPValue.decode($0) }
            .filter { $0["method"]?.string == "Page.getFrameTree" }
            .compactMap { $0["sessionId"]?.string }).subtracting([tab.tabID])
        XCTAssertEqual(asked.count, 2, "\(asked)")
        proxy.onHeld = { _ in }
        proxy.holdsReply = { message in
            message.contains("\"Page.getFrameTree\"") && asked.contains { message.contains($0) }
        }
        let old = Set(before.compactMap(\.tab.frame))
        _ = try? await world.bridge.runInPage("setTimeout(() => location.reload(), 0), 'x'", in: tab)
        let after = try await frames(of: tab, world, until: { listed in
            listed.map(\.identity) == Self.site170Frames && listed.allSatisfy { !old.contains($0.tab.frame ?? "") }
        })
        // What was asked is read from the messages that went out, not from how
        // long the listing took: a busy machine slows a listing that asks no
        // frame that went.
        let sent = proxy.messages.count
        let again = try await world.bridge.frames(of: tab)
        let askedGone = proxy.messages.dropFirst(sent).compactMap { try? CDPValue.decode($0) }
            .filter { $0["method"]?.string == "Page.getFrameTree" && asked.contains($0["sessionId"]?.string ?? "") }
        XCTAssertTrue(askedGone.isEmpty, "no frame that went is asked: \(askedGone.count)")
        XCTAssertEqual(again.frames, after)
        XCTAssertEqual(again.unread, 0, "no frame that went is counted")
    }

    /// site-170's frames once loaded (fixtures site-170, site-171): its own
    /// srcdoc form, the widget of site-171, and inside the widget its srcdoc
    /// button and the third site's frame. Four frames are listed before the
    /// third site's frame has left its first blank page — then it is a twin of
    /// the srcdoc button (gate 2026-10-06 16:20) — so a wait asks for these.
    private static let site170Frames = ["/://", "/https://site-171.test", "/https://site-171.test/://",
                                        "/https://site-171.test/https://site-172.test"]

    /// The tab's frames once their listing is `done` — 10 s at most, each
    /// listing in less than 8 s.
    @MainActor
    private func frames(of tab: BrowserTab, _ world: ChromeWorld,
                        until done: ([BrowserFrame]) -> Bool) async throws -> [BrowserFrame] {
        let deadline = Date().addingTimeInterval(10)
        var listed: [BrowserFrame] = []
        while Date() < deadline {
            let began = ContinuousClock.now
            listed = (try? await world.bridge.frames(of: tab))?.frames ?? []
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(8), "a listing held up")
            if done(listed) { return listed }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never listed as wanted: \(listed)")
        return listed
    }

    /// A No to a control in a frame holds after the page is loaded again —
    /// its frame made anew, with a new id in the browser: the control is
    /// never offered, nor asked about, again in the errand.
    @MainActor
    func testANoToAControlInAFrameHoldsAfterAReload() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Remove member"), Self.on(.click, "Reload the page"),
                                              Self.on(.click, "Remove member")])
        let asked = Counter()
        let record = try await run(world, from: "https://site-199.test/", engine: engine, bridge: hands, confirm: { _ in
            asked.add()
            return .no
        }).run()
        XCTAssertEqual(asked.value, 1, "asked once: \(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .refused, "\(record.eventLines)")
        XCTAssertEqual(record.steps.dropFirst().first?.operation, "click", "the reload: \(record.eventLines)")
        let first = requests.all.first?.candidates.first { $0.action.target?.name == "Remove member" }?.action.target?.frame
        let later = Array(requests.all.dropFirst(2))
        XCTAssertFalse(later.isEmpty, "\(record.eventLines)")
        XCTAssertFalse(later.contains { $0.candidates.contains { $0.action.target?.name == "Remove member" } },
                       "never offered again")
        let tab = try XCTUnwrap(hands.kept.first)
        let now = try await world.look(tab)
        XCTAssertNotEqual(try named("Remove member", in: now).frame, try XCTUnwrap(first), "the frame was made anew")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "", "never pressed")
    }

    // MARK: - Where a frame's control is pressed (review of I-09, F7, F1)

    /// A frame drawn squeezed on one axis is no place to press: its control
    /// is reached nowhere, and nothing is pressed (review of I-09, F7).
    @MainActor
    func testAFrameScaledOnOneAxisIsReachedNowhere() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-202.test/")
        let page = try await world.look(tab)
        let save = try named("Save", in: page)
        let place = tab.inFrame(save.frame)
        let aim = try await world.outcome(ActionScript.aim(for: AgentAction(operation: .click, target: save, destination: nil,
                                                                            payload: nil, isPlannedSearch: false),
                                                           on: page), in: place)
        XCTAssertEqual(aim.outcome, .aim)
        let point = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
        XCTAssertNil(point, "a squeezed frame: no point")
        if let point { try await world.bridge.click(x: point.x, y: point.y, in: tab) }
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: place)
        XCTAssertEqual(log, "", "nothing pressed")
    }

    /// A frame the page shifts once it is brought on screen: the press goes
    /// where the control is after the shift — measured again right before it
    /// — never on what slid under the point measured before (review of
    /// I-09, F1).
    @MainActor
    func testAFrameThatShiftsAsItIsBroughtOnScreenIsPressedWhereItIsNow() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Save")])
        let record = try await run(world, from: "https://site-203.test/", engine: engine, bridge: hands).run()
        XCTAssertEqual(record.steps.first?.operation, "click", "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let top = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(top, "", "nothing that slid under the point was pressed")
        let saved = try await log(of: "Save", in: tab, world)
        XCTAssertEqual(saved, "saved;")
    }

    /// A control that moves at every frame the page draws: no measure of it
    /// holds, so it is never pressed — the step is gone (review of I-09, F1).
    @MainActor
    func testAControlThatNeverStandsStillIsNeverPressed() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Catch me")])
        let record = try await run(world, from: "https://site-206.test/", engine: engine, bridge: hands).run()
        XCTAssertEqual(record.steps.first?.operation, "click", "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .gone, "\(record.eventLines)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "", "never pressed")
    }

    // MARK: - What Jev reads (review of I-09, F8)

    /// A frame that cannot be read is counted — on record as a miss — never
    /// dropped silently, and the rest of the page is read as it is.
    @MainActor
    func testAFrameThatCannotBeReadIsCountedAndThePageIsReadWithoutIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = FailsTheFrameReads(world.bridge)
        let (engine, requests) = Self.engine([])
        let record = try await run(world, from: "https://site-170.test/", engine: engine, bridge: hands).run()
        XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
        XCTAssertEqual(record.events.filter { $0 == .pageMiss(.read) }.count, hands.failed, "\(record.eventLines)")
        XCTAssertGreaterThan(hands.failed, 0)
        let offered = requests.all.first?.candidates.compactMap(\.action.target?.name) ?? []
        XCTAssertTrue(offered.contains("Top button"), "\(offered)")
        XCTAssertFalse(offered.contains("Reserve"), "\(offered)")
    }

    /// Stop while a frame's confirm is open — its answer kept from Chrome
    /// until a moment after Stop — while a document is refused as a download
    /// — the refusal kept from Chrome — or while a frame loads — held at its
    /// start: the errand returns well within Stop's limit of the press, takes
    /// no step after it, saves nothing and leaves no tab (Claude review c7 of
    /// I-09, #21).
    @MainActor
    func testStopAtAFramesDialogDownloadOrLoadEndsWithinTheLimit() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        let cases: [(start: String, picks: [@Sendable (Candidate) -> Bool], kept: String,
                     when: @Sendable (CDPEvent) -> Bool)] = [
            ("https://site-179.test/", [Self.on(.click, "Remove widget")], "\"Page.handleJavaScriptDialog\"",
             { $0.method == "Page.javascriptDialogOpening" && $0.params["type"]?.string == "confirm" }),
            ("https://site-179.test/", [{ $0.action.operation == .open && $0.action.target?.name == "The terms" }],
             "\"Fetch.failRequest\"",
             { $0.method == "Fetch.requestPaused" && $0.params["responseStatusCode"] != nil
                 && ($0.params["request"]?["url"]?.string ?? "").contains("terms.pdf") }),
            ("https://site-174.test/", Array(repeating: Self.waits, count: 20), "\"Runtime.runIfWaitingForDebugger\"",
             { $0.method == "Target.attachedToTarget" && $0.params["targetInfo"]?["type"]?.string == "iframe" }),
        ]
        for (start, picks, kept, when) in cases {
            // What is kept from Chrome is kept once the act went out: the
            // frame's alert on load is answered as ever.
            let hands = ArmsAtTheAct(world.bridge) { proxy.swallows = { $0.contains(kept) } }
            let (engine, _) = Self.engine(picks)
            let run = try run(world, from: start, engine: engine, bridge: hands, confirm: { _ in .yes })
            let events = await world.connection.events()
            let pressed = Box<ContinuousClock.Instant>()
            let taken = Box<Int>()
            let stopping = Task { @MainActor in
                for await event in events where when(event) {
                    taken.value = run.record.steps.count
                    pressed.value = .now
                    run.stop()
                    // The dialog's answer comes a moment after Stop: Cancel,
                    // as the bridge answers one once its Yes is gone.
                    if event.method == "Page.javascriptDialogOpening", let session = event.sessionID {
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.swallows = nil
                        _ = try? await world.connection.send("Page.handleJavaScriptDialog", params: ["accept": false],
                                                             sessionID: session)
                    }
                    return
                }
            }
            if start.contains("174") { hands.arm() }
            let outcome = await run.run(report: { _ in })
            stopping.cancel()
            proxy.swallows = nil
            let stopped = try XCTUnwrap(pressed.value, "\(start) \(kept): Stop pressed")
            XCTAssertEqual(outcome.ending, .stopped, kept)
            // A run that waits out Stop's backstop fails here; the check of
            // an act already sent may take its own few seconds.
            XCTAssertLessThan(ContinuousClock.now - stopped, AgentRun.stopLimit - .seconds(2),
                              "\(kept): well within Stop's limit")
            XCTAssertEqual(run.record.steps.count, taken.value, "\(kept): no step after Stop: \(run.record.eventLines)")
            let tabs = try await world.agentTabCount()
            XCTAssertEqual(tabs, 0, kept)
        }
        let saved = try FileManager.default.contentsOfDirectory(atPath: world.chrome.downloads.path)
        XCTAssertFalse(saved.contains { $0.hasPrefix("terms") }, "\(saved)")
    }

    // MARK: - Review round 2 of I-09 (Codex review 1; Claude review c7)

    /// The same widget in each row of a team, the member's name in the page
    /// only: its controls — in frames of the page's own site, or of another
    /// — differ by nothing but the frame that holds them. They are twins,
    /// and none is offered: a Yes or a No could reach any member's (Claude
    /// review c7 of I-09, #4).
    @MainActor
    func testTwinControlsInFramesOfOneSiteAreTwinsAndNeverOffered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for address in ["https://site-255.test/team", "https://site-255.test/team-widget"] {
            let tab = try await world.bridge.openTab(URL(string: address)!)
            try await world.waitUntilLoaded(tab)
            var page = try await world.look(tab)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, page.elements.filter({ $0.name == "Remove member" }).count < 3 {
                try await Task.sleep(for: .milliseconds(100))
                page = try await world.look(tab)
            }
            let twins = page.elements.filter { $0.name == "Remove member" }
            XCTAssertEqual(twins.count, 3, address)
            XCTAssertEqual(Set(twins.compactMap(\.frame)).count, 3, "\(address): three frames")
            XCTAssertEqual(Set(twins.map(\.fingerprint)).count, 1, "\(address): twins")
            let set = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: ["remove", "member"]))
            XCTAssertFalse(set.candidates.contains { $0.action.target?.name == "Remove member" }, address)
            try await world.bridge.closeTab(tab)
        }
    }

    /// Two widgets of one other site side by side, each with a control of
    /// its own. A No to the second one's control holds on a look where the
    /// first one's frame says nothing of what it holds: who the second one
    /// is does not hang on which frames answered (Codex review 1 of I-09,
    /// P2-1). The frame that said nothing is not read, and is on record as a
    /// miss (P2-2).
    @MainActor
    func testWhoAFrameIsDoesNotHangOnWhichFramesAnswered() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.waits, Self.on(.click, "Remove member"),
                                              Self.on(.click, "Remove member")])
        let asked = Counter()
        let record = try await run(world, from: "https://site-255.test/siblings", engine: engine, bridge: hands,
                                   confirm: { _ in
            asked.add()
            // From now on the first widget's frame — the first to run — says
            // nothing of what it holds.
            let first = proxy.messages.lazy.compactMap { try? CDPValue.decode($0) }
                .first { $0["method"]?.string == "Runtime.runIfWaitingForDebugger" }?["sessionId"]?.string ?? "?"
            proxy.onHeld = { _ in }
            proxy.holdsReply = { $0.contains("\"Page.getFrameTree\"") && $0.contains(first) }
            return .no
        }).run()
        XCTAssertEqual(asked.value, 1, "asked once: \(record.eventLines)")
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .refused, "\(record.eventLines)")
        let later = Array(requests.all.dropFirst(2))
        XCTAssertFalse(later.isEmpty, "\(record.eventLines)")
        XCTAssertFalse(later.contains { $0.candidates.contains { $0.action.target?.name == "Remove member" } },
                       "never offered again")
        XCTAssertFalse(later.contains { $0.candidates.contains { $0.action.target?.name == "Archive" } },
                       "the frame that said nothing is not read")
        XCTAssertTrue(record.events.contains(.pageMiss(.read)), "\(record.eventLines)")
    }

    /// A frame in a process of its own that never says what it holds is left
    /// out of the look in a moment, and each frame left out is on record as
    /// a miss — one apiece (Codex review 1 of I-09, P2-2). Here neither the
    /// widget of another site nor the third site's frame inside it ever said
    /// what it holds: how many frames each holds is not known, and is a miss
    /// of its own beside each (Codex review 2 of I-09, P2-5). The errand ends
    /// as it would.
    @MainActor
    func testEachFrameThatNeverSaysWhatItHoldsIsOnRecordAsAMiss() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        // The page's own session is the first to ask for a frame tree: every
        // other — a frame's — is held for good.
        let page = Box<String>()
        let held = Counter()
        proxy.onHeld = { _ in held.add() }
        proxy.holdsReply = { message in
            guard message.contains("\"Page.getFrameTree\""),
                  let session = (try? CDPValue.decode(message))?["sessionId"]?.string else { return false }
            if page.value == nil { page.value = session }
            return session != page.value
        }
        let (engine, _) = Self.engine([Self.waits])
        let began = ContinuousClock.now
        let record = try await run(world, from: "https://site-170.test/", engine: engine).run()
        XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(20), "bounded")
        XCTAssertGreaterThan(held.value, 0)
        // Two frames asked in each look, and held: each a miss, and what each
        // holds another.
        XCTAssertEqual(record.events.filter { $0 == .pageMiss(.read) }.count, 2 * held.value, "\(record.eventLines)")
    }

    /// Frames in a process of their own that never say what they hold are
    /// asked all at once, each within its own limit: a listing with eight of
    /// them held takes about one frame's limit, not eight — and each is
    /// counted (Claude review c8 of I-09, #29). Nothing after the listing
    /// bounds it.
    @MainActor
    func testFramesThatNeverAnswerAreAskedAllAtOnce() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        let (tab, _) = try await world.open("https://site-263.test/held")
        let listed = try await frames(of: tab, world, until: { $0.count == 8 })
        XCTAssertEqual(listed.count, 8)
        let page = "\"sessionId\":\"\(tab.tabID)\""
        let held = Counter()
        proxy.onHeld = { _ in held.add() }
        proxy.holdsReply = { $0.contains("\"Page.getFrameTree\"") && $0.contains("sessionId") && !$0.contains(page) }
        let began = ContinuousClock.now
        let listing = try await world.bridge.frames(of: tab)
        let took = ContinuousClock.now - began
        XCTAssertLessThan(took, .seconds(5), "all at once: about one frame's limit")
        XCTAssertEqual(held.value, 8, "each frame asked")
        XCTAssertEqual(listing.frames, [])
        XCTAssertEqual(listing.unread, 8, "\(listing)")
    }

    /// A page of very many frames is read within a bound: no more frames
    /// than the page's own census reads, and none once the look's time for
    /// frames is spent; the frames left are on record as a miss (Claude
    /// review c7 of I-09, #7).
    @MainActor
    func testAPageOfVeryManyFramesIsReadWithinItsBound() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for slow in [false, true] {
            let hands = CountsTheFrameReads(world.bridge, each: slow ? .milliseconds(400) : .zero)
            let (engine, _) = Self.engine([])
            let began = ContinuousClock.now
            let record = try await run(world, from: "https://site-255.test/many", engine: engine, bridge: hands).run()
            XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
            XCTAssertLessThanOrEqual(hands.reads, 50, "slow \(slow): the page's own census bound")
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(25), "slow \(slow)")
            XCTAssertTrue(record.events.contains(.pageMiss(.read)), "slow \(slow): \(record.eventLines)")
            if slow { XCTAssertLessThan(hands.reads, 50, "the look's time for frames ran out") }
        }
    }

    /// A widget of another site whose sign-in shows while the question
    /// about its button waits: the fresh look after the Yes finds the button
    /// the user's part — handed over as a sign-in — and nothing is pressed
    /// (Claude review c7 of I-09, #5).
    @MainActor
    func testASignInThatShowsWhileTheQuestionWaitsIsTheUsersAfterTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Continue")], irreversible: { _ in 0.9 })
        let bridge = world.bridge
        let asked = Counter()
        let record = try await run(world, from: "https://site-255.test/signin", engine: engine, bridge: hands,
                                   confirm: { request in
            asked.add()
            let frame = request.tab.inFrame(request.action.target?.frame)
            _ = try? await bridge.run("document.getElementById('signin').hidden = false, 'shown'", in: frame)
            return .yes
        }).run()
        XCTAssertEqual(asked.value, 1, "\(record.eventLines)")
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.signIn, host: "site-255.test")), "\(record.eventLines)")
        XCTAssertEqual(hands.aims, 0, "handed over at the Yes, before any act")
        let log = try await log(of: "Continue", in: try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "", "never pressed")
    }

    /// The same sign-in showing right before the act, with no question
    /// asked: the act finds the button the user's part where it stands — its
    /// frame another site's that holds a sign-in now — and nothing is pressed
    /// (Claude review c7 of I-09, #5).
    @MainActor
    func testASignInThatShowsRightBeforeTheActIsTheUsersAtTheAct() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ShowsTheSignInAtTheAim(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Continue")])
        let record = try await run(world, from: "https://site-255.test/signin", engine: engine, bridge: hands).run()
        XCTAssertTrue(hands.shown, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .handedOver, "\(record.eventLines)")
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.signIn, host: "site-255.test")), "\(record.eventLines)")
        let log = try await log(of: "Continue", in: try XCTUnwrap(hands.kept.first), world)
        XCTAssertEqual(log, "", "never pressed")
    }

    /// A Yes for a control in a frame is bound to that frame's own page:
    /// given for a button of no form on the widget's page, it presses there;
    /// given there and spent after the widget moved to another page of its
    /// site — the same button on it — it presses nothing (Claude review c7
    /// of I-09, #18).
    @MainActor
    func testAYesInAFrameIsBoundToTheFramesOwnPage() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for moves in [false, true] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, "Deep button")], irreversible: { _ in 0.9 })
            let bridge = world.bridge
            let asked = Counter()
            let record = try await run(world, from: "https://site-170.test/", engine: engine, bridge: hands,
                                       confirm: { request in
                asked.add()
                guard moves else { return .yes }
                let frame = request.tab.inFrame(request.action.target?.frame)
                _ = try? await bridge.run("location.assign('https://site-172.test/other'), 'x'", in: frame)
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline,
                      (try? await bridge.run("location.pathname + ' ' + document.readyState", in: frame)) != "/other complete" {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .yes
            }).run()
            XCTAssertEqual(asked.value, 1, "\(moves): \(record.eventLines)")
            XCTAssertTrue(record.events.contains(.answer(.yes)), "\(moves): \(record.eventLines)")
            // Pressed, the step's own check decides how it went; not pressed,
            // it is gone at the act.
            let outcome = record.steps.first { $0.operation == "click" }?.outcome
            if moves {
                XCTAssertEqual(outcome, .gone, "\(record.eventLines)")
            } else {
                XCTAssertTrue(outcome == .confirmed || outcome == .failed, "\(record.eventLines)")
            }
            let tab = try XCTUnwrap(hands.kept.first)
            if moves {
                try await Task.sleep(for: .milliseconds(300))
                let log = try await log(of: "Deep button", in: tab, world)
                XCTAssertEqual(log, "", "nothing pressed on the page the Yes was not given on")
            } else {
                let page = try await world.look(tab)
                try await wait(for: "deep;", from: "document.getElementById('log').textContent",
                               in: tab.inFrame(try named("Deep pressed", in: page).frame), world)
            }
        }
    }

    /// A widget of another site still loading, before a frame the page
    /// writes itself: who that frame is stays the same at every listing —
    /// while the widget loads and once it came — and a No to its control
    /// given while the widget loads holds after it came (Claude review c7
    /// of I-09, #20).
    @MainActor
    func testAFrameStillLoadingChangesNoOtherFramesIdentity() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-255.test/loading")!)
        var own: (id: String, identity: String)?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, own == nil {
            for frame in (try? await world.bridge.frames(of: tab))?.frames ?? [] {
                let button = try? await world.bridge.run("String(document.querySelector('button')?.textContent)", in: frame.tab)
                if button == "Remove member", let id = frame.tab.frame { own = (id, frame.identity) }
            }
            if own == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let written = try XCTUnwrap(own, "the page's own frame listed")
        for _ in 0..<3 {
            let listed = try await world.bridge.frames(of: tab).frames
            XCTAssertEqual(listed.first { $0.tab.frame == written.id }?.identity, written.identity, "while the widget loads")
        }
        _ = try await world.bridge.runInPage("document.getElementById('widget').src = 'https://site-256.test/archive', 'x'",
                                             in: tab)
        var came = false
        let later = Date().addingTimeInterval(10)
        while Date() < later, !came {
            let listed = try await world.bridge.frames(of: tab).frames
            XCTAssertEqual(listed.first { $0.tab.frame == written.id }?.identity, written.identity, "\(listed)")
            came = listed.contains { $0.identity.contains("site-256") }
            if !came { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(came, "the widget came")
        try await world.bridge.closeTab(tab)
        // A No given while the widget loads holds after it came.
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.on(.click, "Remove member"), Self.on(.click, "Remove member")])
        let bridge = world.bridge
        let asked = Counter()
        let record = try await run(world, from: "https://site-255.test/loading", engine: engine, bridge: hands,
                                   confirm: { request in
            asked.add()
            _ = try? await bridge.runInPage(
                "document.getElementById('widget').src = 'https://site-256.test/archive', 'x'", in: request.tab)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline,
                  !((try? await bridge.frames(of: request.tab))?.frames ?? []).contains(where: { $0.identity.contains("site-256") }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .no
        }).run()
        XCTAssertEqual(asked.value, 1, "asked once: \(record.eventLines)")
        let after = Array(requests.all.dropFirst())
        XCTAssertFalse(after.isEmpty, "\(record.eventLines)")
        XCTAssertFalse(after.contains { $0.candidates.contains { $0.action.target?.name == "Remove member" } },
                       "never offered again")
    }

    /// A widget the page draws slanted is no place to press: a point of its
    /// own viewport is not where it is drawn, so its control is reached
    /// nowhere, and nothing is pressed (Claude review c7 of I-09, #23).
    @MainActor
    func testASlantedFrameIsReachedNowhere() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-255.test/skewed")
        let page = try await world.look(tab)
        let save = try named("Save", in: page)
        let place = tab.inFrame(save.frame)
        let aim = try await world.outcome(ActionScript.aim(for: AgentAction(operation: .click, target: save, destination: nil,
                                                                            payload: nil, isPlannedSearch: false),
                                                           on: page), in: place)
        XCTAssertEqual(aim.outcome, .aim)
        let point = try await world.bridge.point(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: place)
        XCTAssertNil(point, "a slanted frame: no point")
        if let point { try await world.bridge.click(x: point.x, y: point.y, in: tab) }
        try await Task.sleep(for: .milliseconds(200))
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: place)
        XCTAssertEqual(log, "", "nothing pressed")
    }

    /// A widget of another site — in a process of its own — that asks for a
    /// file after the agent's click: the request comes to the agent on the
    /// frame's own session, never as a picker in the user's Chrome (Claude
    /// review c7 of I-09, #23).
    @MainActor
    func testAFilePickerAFrameFromAnotherSiteOpensIsNeverShown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-255.test/upload")
        var page = try await world.look(tab)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !page.elements.contains(where: { $0.name == "Attach a file" }) {
            try await Task.sleep(for: .milliseconds(100))
            page = try await world.look(tab)
        }
        let events = await world.connection.events()
        try await press(try named("Attach a file", in: page), on: page, in: tab, world)
        let session = tab.tabID
        let taken = await Deadline.run(within: .seconds(3)) {
            for await event in events where event.method == "Page.fileChooserOpened" && event.sessionID != session {
                return true
            }
            return false
        } ?? false
        XCTAssertTrue(taken, "the request came to the agent, on the frame's session, not to a dialog")
    }
}

/// The agent's hands in Chrome, which do `arm` once an act goes out — a
/// click, or an open's script — and leave the tab to the errand.
@MainActor
final class ArmsAtTheAct: WrapsChromeBridge {
    let inner: ChromeBridge
    let arm: () -> Void

    init(_ inner: ChromeBridge, arm: @escaping () -> Void) {
        self.inner = inner
        self.arm = arm
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        arm()
        try await inner.click(x: x, y: y, in: tab)
    }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"open\"") || javascript.hasPrefix("(() => {\nconst [destination") { arm() }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, whose every look into a frame takes `each`
/// longer, counted.
@MainActor
final class CountsTheFrameReads: WrapsChromeBridge {
    let inner: ChromeBridge
    let each: Duration
    private(set) var reads = 0

    init(_ inner: ChromeBridge, each: Duration) {
        self.inner = inner
        self.each = each
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if tab.frame != nil, javascript == ObserverScript.source {
            reads += 1
            try await Task.sleep(for: each)
        }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, which show a widget's sign-in in the frame
/// the agent aims into, right before its first aim there — and keep the tab
/// when the errand closes it.
@MainActor
final class ShowsTheSignInAtTheAim: WrapsChromeBridge {
    let inner: ChromeBridge
    private(set) var shown = false
    private(set) var kept: [BrowserTab] = []

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if tab.frame != nil, !shown, javascript.contains("\"operation\":\"aim\"") {
            shown = true
            _ = try await inner.run("document.getElementById('signin').hidden = false, 'shown'", in: tab)
        }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, whose tab is left open when the errand
/// closes it — so a test reads what the page did there — which can act
/// right after a click went out, and which count the aims sent.
@MainActor
final class KeepsTheTab: WrapsChromeBridge {
    let inner: ChromeBridge
    var afterClick: () -> Void = {}
    private(set) var kept: [BrowserTab] = []
    private(set) var aims = 0

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"aim\"") { aims += 1 }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }

    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        try await inner.click(x: x, y: y, in: tab)
        afterClick()
    }
}

/// The agent's hands in Chrome, whose look into any frame fails, as a frame's
/// script that threw does.
@MainActor
final class FailsTheFrameReads: WrapsChromeBridge {
    let inner: ChromeBridge
    private(set) var failed = 0

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if tab.frame != nil, javascript == ObserverScript.source {
            failed += 1
            throw BrowserBridgeError.scriptFailed(code: -3)
        }
        return try await inner.run(javascript, in: tab)
    }
}

extension ChromeWorld {
    /// What a look at the tab sees, its frames included, as the run reads it:
    /// a frame that cannot be read — one going, or not yet ready — is left out.
    func look(_ tab: BrowserTab) async throws -> ObservedPage {
        let page = try ObservedPage.decode(try await bridge.run(ObserverScript.source, in: tab))
        var frames: [(id: String, identity: String, page: ObservedPage)] = []
        for frame in try await bridge.frames(of: tab).frames {
            guard let id = frame.tab.frame, let report = try? await bridge.run(ObserverScript.source, in: frame.tab),
                  let read = try? ObservedPage.decode(report) else { continue }
            frames.append((id: id, identity: frame.identity, page: read))
        }
        return page.merging(frames)
    }
}

/// Review of I-09, F7 — where a point of a frame's viewport is drawn in the
/// document that holds it, without a browser: each axis by its own ratio, as
/// a reference browser agent's hit test does (MIT); a frame squeezed on one
/// axis is no place to press.
final class ChromeFramePointTests: XCTestCase {
    /// A frame drawn as it is: the box's corner, plus the point.
    func testAFrameDrawnAsItIsKeepsItsPoint() throws {
        let point = try XCTUnwrap(ChromeBridge.framePoint(20, 30, box: [100, 50, 500, 50, 500, 250, 100, 250],
                                                          width: 400, height: 200))
        XCTAssertEqual(point.x, 120)
        XCTAssertEqual(point.y, 80)
    }

    /// A frame drawn at twice its size, and one whose drawn height differs
    /// from its own by a rounding: each axis by its own ratio.
    func testEachAxisScalesByItsOwnRatio() throws {
        let twice = try XCTUnwrap(ChromeBridge.framePoint(10, 20, box: [0, 0, 800, 0, 800, 400, 0, 400],
                                                          width: 400, height: 200))
        XCTAssertEqual(twice.x, 20)
        XCTAssertEqual(twice.y, 40)
        let rounded = try XCTUnwrap(ChromeBridge.framePoint(10, 100, box: [0, 0, 300, 0, 300, 149.4, 0, 149.4],
                                                            width: 300, height: 150))
        XCTAssertEqual(rounded.x, 10, accuracy: 1e-9)
        XCTAssertEqual(rounded.y, 99.6, accuracy: 1e-9)
    }

    /// Drawn at half its height but its whole width, or of no size: no point.
    func testAFrameScaledOnOneAxisHasNoPoint() {
        XCTAssertNil(ChromeBridge.framePoint(10, 20, box: [0, 0, 400, 0, 400, 100, 0, 100], width: 400, height: 200))
        XCTAssertNil(ChromeBridge.framePoint(10, 20, box: [0, 0, 400, 0, 400, 200, 0, 200], width: 0, height: 200))
    }
}

/// ITER-076 I-09, round 5 — owner decision of 2026-10-03: Jev sees what a
/// person sees. Only the value of a field the page marks secret by structure
/// is never read, in the page or in any frame; signing in and paying stay the
/// user's part.
extension ChromeFramesLiveTests {

    /// An errand from `start` whose Jev clicks the control labelled `name`,
    /// then is done; the tab is kept.
    @MainActor
    private func clicking(_ name: String, from start: String, _ world: ChromeWorld)
        async throws -> (record: ErrandRecord, sent: [String], tab: BrowserTab) {
        let hands = KeepsTheTab(world.bridge)
        let jev = RecordedJev { asked, _ in
            guard asked.isStep else { return .answers() }
            guard asked.recentLabels.isEmpty, let target = asked.key(labelled: name) else {
                return .answers(operation: "DONE")
            }
            return .answers(operation: "CLICK", target: target)
        }
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        return (record, jev.bodies.map { String(decoding: $0, as: UTF8.self) },
                try XCTUnwrap(hands.kept.first, "\(record.eventLines)"))
    }

    /// A frame of another site holding fields it marks secret by structure
    /// alone — a password, a current and a new password, a one-time code,
    /// dots, a card's number, security code and expiry — filled in: no value
    /// reaches any request to Jev, the step on the frame's button is the
    /// user's sign-in or payment, and nothing is pressed.
    @MainActor
    func testFieldsMarkedSecretInAFrameOfAnotherSiteReachNoOneAndAreTheUsers() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let cases: [(String, String, ErrandHandover.Kind, [String])] = [
            ("https://site-290.test/signin", "Go on", .signIn, ["vA-4417q", "vB-5521q", "vC-6632q", "738204", "vE-7743q"]),
            ("https://site-290.test/card", "Keep", .payment, ["4111111111111111", "8462", "08/31"])
        ]
        for (start, name, kind, values) in cases {
            let (record, sent, tab) = try await clicking(name, from: start, world)
            XCTAssertFalse(sent.isEmpty, "\(start): \(record.eventLines)")
            XCTAssertTrue(sent.allSatisfy { $0.contains(name) }, "\(start): the frame's button is offered: \(sent)")
            for value in values {
                XCTAssertFalse(sent.contains { $0.contains(value) }, "\(start) \(value): \(sent)")
            }
            XCTAssertEqual(record.ending, .needsUser, "\(start): \(record.eventLines)")
            XCTAssertTrue(record.events.contains(.handover(kind, host: "site-290.test")), "\(start): \(record.eventLines)")
            let log = try await log(of: name, in: tab, world)
            XCTAssertEqual(log, "", "\(start): nothing pressed")
        }
    }

    /// A sign-in in a frame of another site that only its words name — a
    /// "Password" box with no type, no autocomplete, no dots — is still the
    /// user's: its button is handed over as a sign-in, never pressed.
    @MainActor
    func testAWordNamedSignInInAFrameOfAnotherSiteIsStillTheUsers() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (record, sent, tab) = try await clicking("Go on", from: "https://site-290.test/words", world)
        XCTAssertTrue(sent.allSatisfy { $0.contains("Go on") }, "\(sent)")
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.signIn, host: "site-290.test")), "\(record.eventLines)")
        let log = try await log(of: "Go on", in: tab, world)
        XCTAssertEqual(log, "", "nothing pressed")
    }

    /// A code a person reads — beside "Your one-time code", on a button, as a
    /// field's value, in a drawing, in the page or in a frame of it, its words
    /// in the other — reaches Jev as it is shown, and the writer's excerpt of
    /// the page too: nothing is hidden by the words around it.
    @MainActor
    func testAVisibleCodeInTextReachesJev() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let cases: [(String, [String], String?)] = [
            ("https://site-208.test/", ["481920"], "481920"),
            ("https://site-209.test/", ["481920", "735102"], "735102"),
            ("https://site-204.test/", ["481920"], nil),
            ("https://site-257.test/drawn", ["481920", "735102", "629384"], nil),
            ("https://site-257.test/heading", ["481920"], nil)
        ]
        for (start, codes, inExcerpt) in cases {
            let jev = RecordedJev { _, _ in .answers(operation: "DONE", nouls: ["goal_done": 0.95]) }
            let writer = RecordingWriter()
            let run = AgentRun(plan: try plan(start), errandID: UUID(),
                               collaborators: .init(bridge: world.bridge, engine: jev.engine, writer: writer,
                                                    sheet: FixtureSheet(), confirm: { _ in .no }))
            let record = await run.run()
            let sent = jev.bodies.map { String(decoding: $0, as: UTF8.self) }
            XCTAssertFalse(sent.isEmpty, "\(start): \(record.eventLines)")
            for code in codes {
                XCTAssertTrue(sent.contains { $0.contains(code) }, "\(start) \(code): \(sent)")
            }
            XCTAssertFalse(sent.contains { $0.contains("[hidden]") }, "\(start): \(sent)")
            XCTAssertFalse(writer.excerpts.isEmpty, "\(start): the writer was asked: \(record.eventLines)")
            for excerpt in writer.excerpts {
                XCTAssertFalse(excerpt.text.contains("[hidden]"), "\(start): \(excerpt.text)")
                if let inExcerpt { XCTAssertTrue(excerpt.text.contains(inExcerpt), "\(start): \(excerpt.text)") }
            }
        }
    }

    /// A frame the page names as a secret field — a label around it, its
    /// title, "Passport number" — shows what a person sees in it: what its
    /// field holds reaches Jev as it is, beside the page's own controls. Only
    /// a field the frame's page marks secret by its structure is withheld,
    /// by the frame's own look (owner decision of 2026-10-03; until then
    /// `ChromeSecrecyLiveTests.testAFrameThePageNamesAsASecretFieldShowsNothingOfIt`
    /// held the opposite on this page).
    @MainActor
    func testAFrameThePageNamesAsASecretFieldShowsWhatAPersonSees() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let jev = RecordedJev { _, _ in .answers(operation: "DONE", nouls: ["goal_done": 0.95]) }
        let run = AgentRun(plan: try plan("https://site-208.test/passport"), errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let sent = jev.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(sent.isEmpty, "\(record.eventLines)")
        XCTAssertTrue(sent.contains { $0.contains("X12Y34Z") }, "\(sent)")
        XCTAssertTrue(sent.allSatisfy { $0.contains("Help") }, "\(sent)")
    }
}

/// ITER-076 I-09, round 7 (Claude review c11, #4, #10): what the page names a
/// frame is the user's part for acting; an approved open of a frame's link
/// opens.
extension ChromeFramesLiveTests {

    /// A frame of another site the page names a card's field — by the label
    /// around it, or by its title while it holds a form — whose own field no
    /// structure and no word of its own marks: its controls are offered as
    /// they are, and the step on one is handed over as the user's payment,
    /// never asked about; nothing in it is typed into or pressed (#4).
    @MainActor
    func testAFrameOfAnotherSiteThePageNamesACardsFieldIsTheUsersPayment() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (start, name) in [("https://site-311.test/label", "Next"), ("https://site-311.test/title", "Submit")] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, requests) = Self.engine([Self.on(.click, name)])
            let asked = Counter()
            let record = try await run(world, from: start, engine: engine, bridge: hands, confirm: { _ in
                asked.add()
                return .yes
            }).run()
            XCTAssertTrue(requests.all.first?.candidates.contains { $0.action.target?.name == name } == true,
                          "\(start): \(record.eventLines)")
            XCTAssertEqual(record.ending, .needsUser, "\(start): \(record.eventLines)")
            XCTAssertTrue(record.events.contains(.handover(.payment, host: "site-311.test")),
                          "\(start): \(record.eventLines)")
            XCTAssertEqual(asked.value, 0, "\(start): never asked")
            let tab = try XCTUnwrap(hands.kept.first)
            let page = try await world.look(tab)
            XCTAssertEqual(try named("Number", in: page).touchesSecret, true, "\(start): never typed into")
            let log = try await log(of: name, in: tab, world)
            XCTAssertEqual(log, "", "\(start): nothing pressed")
        }
    }

    /// A link in a frame of another site, which Jev rates irreversible: the
    /// user is asked once, says Yes, and the link opens — found in its own
    /// document, opened in the tab its Yes is bound to (#10).
    @MainActor
    func testAnApprovedOpenOfALinkInAFrameOpensOnce() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([{ $0.action.operation == .open && $0.action.target?.name == "More about us" }],
                                      irreversible: { _ in 0.9 })
        let asked = Counter()
        let record = try await run(world, from: "https://site-170.test/", engine: engine, bridge: hands, confirm: { _ in
            asked.add()
            return .yes
        }).run()
        XCTAssertEqual(asked.value, 1, "\(record.eventLines)")
        XCTAssertEqual(record.steps.map(\.operation), ["open", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        let address = try await world.bridge.runInPage("location.href", in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(address, "https://site-1.test/")
    }
}
