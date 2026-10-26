import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-07 — the agent's hands, part 1, in a real Chrome (headless, a
/// profile of its own, the fixture pages served from inside Chrome): a form
/// sent only by a click on its own control, a page read only once it has gone
/// quiet, and typing that lands.
/// Ported from a reference browser agent (MIT). Skipped without Chrome.
final class ChromeHandsLiveTests: XCTestCase {

    // MARK: - Helpers

    private func plan(_ start: String, goal: String = "Look around the page") throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: goal, subgoals: [.init(description: goal, terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// A run on `start` whose engine picks what `script` says, then DONE.
    @MainActor
    private func run(_ world: ChromeWorld, from start: String, engine: ScriptedEngine,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no }) async throws -> ErrandRecord {
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: confirm))
        return await run.run()
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds — choosing «more» until one does — then DONE, keeping every
    /// request it was asked.
    private static func engine(_ picks: [@Sendable (Candidate) -> Bool]) -> (ScriptedEngine, Requests) {
        let requests = Requests()
        let turn = Counter()
        let engine = ScriptedEngine(choice: { request in
            _ = requests.add(request)
            if turn.value < picks.count {
                if let chosen = request.candidates.first(where: picks[turn.value]) {
                    turn.add()
                    return ScriptedEngine.pick(chosen)
                }
                if let more = request.candidates.first(where: { $0.action.operation == .more }) {
                    return ScriptedEngine.pick(more)
                }
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        return (engine, requests)
    }

    private static func click(_ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == .click && $0.action.target?.name == name }
    }

    // MARK: - Forms: sent only by a click on a control of their own

    /// What the candidates offer: the operations on each named element.
    private static func offered(on page: ObservedPage) -> [String: [AgentOperation]] {
        var offered: [String: [AgentOperation]] = [:]
        for candidate in CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: [])).candidates {
            guard let name = candidate.action.target?.name else { continue }
            offered[name, default: []].append(candidate.action.operation)
        }
        return offered
    }

    /// Codex review of I-07, round 3, P1-1: nothing in the page can bind what
    /// sending a form from its field would send, so no step sends one that
    /// way. A buttonless search form's field is offered typing and nothing
    /// else — that form has no way to be sent; a form with a submit control
    /// of its own is sent only by a click on that control, judged by what the
    /// click sends.
    @MainActor
    func testAButtonlessSearchFormsFieldIsOfferedOnlyTyping() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-119.test/")
        let offered = Self.offered(on: page)
        XCTAssertEqual(offered["Search the docs"], [.type], "the buttonless form's field")
        XCTAssertEqual(offered["Find a page"], [.type])
        XCTAssertEqual(offered["Go"], [.click], "the only way to send a form: its own control")
        XCTAssertEqual(SafetyGuard.structuralReason(of: try page.action(.click, on: "Go"), pageURL: page.liveAddress),
                       .submitsForm, "judged as a click that sends its form")
    }

    /// P1-1: a click on a submit control is judged by what it sends: its own
    /// method and address. "Continue" in a dialog form that posts elsewhere
    /// is a POST, so it needs a Yes; a No sends nothing.
    @MainActor
    func testAClickOnASubmitterIsJudgedByItsOwnMethodAndAddress() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-133.test/")
        let next = try XCTUnwrap(page.elements.first { $0.name == "Continue" })
        XCTAssertEqual(next.formMethod, "post")
        XCTAssertEqual(next.formAction, "https://site-133.test/messages")
        XCTAssertEqual(SafetyGuard.structuralReason(of: try page.action(.click, on: "Continue"),
                                                    pageURL: page.liveAddress), .postForm)
        let (engine, _) = Self.engine([Self.click("Continue")])
        let record = try await run(world, from: "https://site-133.test/", engine: engine, confirm: { _ in .no })
        XCTAssertEqual(record.events.first { if case .question = $0 { true } else { false } }?.shape,
                       "question click button")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/messages" }, "a No sends nothing")
    }

    /// P1-1: the button's address changes while the Yes is out. The Yes was
    /// for what the click did then: the click is not done, and nothing is
    /// sent anywhere.
    @MainActor
    func testASubmittersAddressChangedWhileTheYesWaitsIsNotClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Continue")])
        let record = try await run(world, from: "https://site-133.test/", engine: engine, confirm: { request in
            if let tab = Optional(request.tab) {
                _ = try? await bridge.runInPage("document.getElementById('continue').setAttribute('formaction', "
                    + "'https://site-133.test/elsewhere'); ''", in: tab)
            }
            return .yes
        })
        XCTAssertNotEqual(record.steps.first { $0.operation == "click" }?.outcome, .confirmed, "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { ["/messages", "/elsewhere"].contains($0.path) })
    }

    // MARK: - Overlays: closed by their own close control

    /// P1-2 (Codex review of I-07, round 2): no key closes an overlay — what a
    /// page's Escape handler does cannot be bound. The newsletter overlay is
    /// closed as a person closes it with the mouse: a click on its own "Close
    /// newsletter", acted; the next look no longer offers it, and no page
    /// operation but scroll, wait, back, done and stuck is ever offered.
    @MainActor
    func testAnOpenOverlayIsClosedByClickingItsOwnCloseControl() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Close newsletter")])
        let record = try await run(world, from: "https://site-121.test/", engine: engine)
        XCTAssertEqual(requests.all.first?.candidates.filter { $0.action.target == nil }.map(\.action.operation),
                       [.scroll, .wait, .done, .stuck], "no key is offered — nor BACK on a first page (ITER-076 I-10)")
        XCTAssertEqual(record.steps.first { $0.operation == "click" }?.outcome, .acted, "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertFalse(requests.all[1].candidates.contains { $0.action.target?.name == "Close newsletter" },
                       "the overlay is closed")
    }

    // MARK: - A page that has gone quiet

    /// A result list that arrives a while after the click, behind a spinner,
    /// is read once it is there: the look after the click waits for the
    /// spinner to go and the page to go quiet.
    @MainActor
    func testAResultListStillLoadingIsReadOnceItHasArrived() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Load results")])
        let record = try await run(world, from: "https://site-122.test/", engine: engine)
        XCTAssertEqual(record.steps.first?.outcome, .acted, "the click's check saw the results")
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertTrue(requests.all.last?.candidates.contains { $0.action.target?.name == "Result A" } == true,
                      "the next look is at the results, not the spinner")
    }

    /// 2026-10-08 (live, a practice site's dynamic loading): text that comes
    /// 2.5 s after the click — past the click's settle, which gives up on a
    /// loader at 1.5 s — is what the next look shows: the look waits on the
    /// loader first, as a reference browser agent's capture does.
    @MainActor
    func testTextThatComesPastTheSettlesLoaderBudgetIsWhatTheNextLookShows() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Start")])
        let record = try await run(world, from: "https://site-473.test/", engine: engine)
        XCTAssertEqual(record.steps.first?.operation, "click", "\(record.eventLines)")
        let text = requests.all.last?.page.text ?? ""
        XCTAssertTrue(text.contains("Hello World!"), text)
        XCTAssertFalse(text.contains("Loading..."), text)
    }

    /// A page that draws its answer in steps less than 200 ms apart, with no
    /// loading indicator, is read once it has been quiet for 200 ms: the next
    /// look sees the answer whole, not a step of it.
    @MainActor
    func testAPageIsReadOnlyOnceItHasBeenQuietFor200Milliseconds() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Search")])
        let record = try await run(world, from: "https://site-129.test/", engine: engine)
        XCTAssertEqual(record.steps.first?.outcome, .acted)
        XCTAssertTrue(requests.all.last?.candidates.contains { $0.action.target?.name == "Result B" } == true,
                      "the next look sees the answer: \(requests.all.last?.page.text ?? "")")
    }

    /// A wait whose read fails without the page moving — a script the page
    /// broke, a call that failed — is read again, not taken for quiet: the
    /// next look after the click still sees the results, not the spinner.
    @MainActor
    func testAWaitWhoseReadFailsIsReadAgainNotTakenForQuiet() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = BreaksTheQuietReadAfterTheClick(world.bridge)
        let (engine, requests) = Self.engine([Self.click("Load results")])
        let run = AgentRun(plan: try plan("https://site-122.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        _ = await run.run()
        XCTAssertTrue(hands.broke, "the wait's read failed once")
        XCTAssertTrue(requests.all.last?.candidates.contains { $0.action.target?.name == "Result A" } == true,
                      "the next look is at the results, not the spinner")
    }

    /// A spinner that never stops is waited on for 1.5 s by a settle, not for
    /// the whole wait, and — since 2026-10-08 — for 3 s by the look a step
    /// shows Jev (`ObserverScript.captureLoading`), never by the click's own
    /// check: the start page and the click each pay 1.5 s and 3 s once.
    @MainActor
    func testAnEndlessSpinnerIsReadAfterItsOwnBudget() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.click("Refresh")])
        let began = ContinuousClock.now
        let record = try await run(world, from: "https://site-123.test/", engine: engine)
        let took = ContinuousClock.now - began
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"])
        XCTAssertGreaterThan(took, .milliseconds(8_400), "the spinner was waited on: twice by a settle, twice by a look")
        XCTAssertLessThan(took, .milliseconds(12_500), "for 1.5 s and 3 s each, not 5 s, nor 3 s more at the click's check")
    }

    /// A page that never goes quiet — a clock ticking for ever — is read after
    /// the whole wait, 5 s, as it is: no miss, and the errand goes on.
    @MainActor
    func testAPageThatNeverGoesQuietIsReadAfterTheWholeWait() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([])
        let began = ContinuousClock.now
        let record = try await run(world, from: "https://site-124.test/", engine: engine)
        let took = ContinuousClock.now - began
        XCTAssertEqual(record.ending, .done)
        XCTAssertEqual(requests.all.count, 1, "the page was read")
        XCTAssertFalse(record.events.contains { $0.shape == "miss settle" }, "no miss: the page is read as it is")
        XCTAssertGreaterThan(took, .milliseconds(4_500))
        XCTAssertLessThan(took, .milliseconds(8_000))
    }

    /// A menu drawn in an animation frame is seen, even when that frame comes
    /// late — the page's own handler holds the page past the quiet time: the
    /// wait begins only after one rendered frame.
    @MainActor
    func testAMenuDrawnInALateAnimationFrameIsSeen() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-125.test/")
        // Quiet for longer than the quiet time before the click.
        try await Task.sleep(for: .milliseconds(400))
        let shown = try await world.bridge.run(
            "(() => { document.getElementById('menu-button').click(); return ("
                + ObserverScript.settledSource(within: .seconds(3))
                + ").then(() => String(!document.getElementById('menu').hidden)); })()", in: tab)
        XCTAssertEqual(shown, "true", "the menu was there when the page was read")
    }

    /// A navigation while the page is being waited on destroys that read:
    /// the read is made again on the new page, the action is not. The click
    /// is acted, the next page is read, and it was asked for once.
    @MainActor
    func testANavigationDuringTheReadRetriesTheReadNotTheAction() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Continue")])
        let record = try await run(world, from: "https://site-126.test/", engine: engine)
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"])
        XCTAssertEqual(record.steps.first?.outcome, .acted, "\(record.eventLines)")
        XCTAssertEqual(requests.all.last?.page.text.contains("Arrived"), true, "the next look is at the new page")
        XCTAssertEqual(world.fixtures.served.filter { $0.path == "/next" }.count, 1)
        XCTAssertFalse(record.events.contains { $0.shape.hasPrefix("miss") }, "\(record.eventLines)")
    }

    /// P2-4 (Codex review of I-07): a page that is usable but never complete
    /// — a picture its server never answers for — is read once it is
    /// interactive and quiet, not failed after the page's whole deadline.
    @MainActor
    func testAnInteractivePageWithAPictureThatNeverArrivesIsRead() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([])
        let began = ContinuousClock.now
        let record = try await run(world, from: "https://site-135.test/", engine: engine)
        XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 1, "the page was read")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(4))
    }

    /// P2-6: the open lands on the site it was for, then the page moves to
    /// another site while it is waited on. Where it ends is what counts: the
    /// step failed, and the open is not sent again.
    @MainActor
    func testAnOpenThatLandsThenMovesToAnotherSiteWhileWaitedOnFails() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([{ $0.action.operation == .open && $0.action.target?.name == "Go to the offer" }])
        let record = try await run(world, from: "https://site-136.test/", engine: engine)
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertEqual(world.fixtures.served.filter { $0.host == "site-137.test" && $0.path == "/" }.count, 1,
                       "opened once")
        XCTAssertTrue(world.fixtures.served.contains { $0.host == "site-138.test" }, "the page did move on")
    }

    /// Codex review of I-07, round 3, P2-1: the open lands on the site it was
    /// for, the page moves to another site while it is waited on, and the read
    /// of where it ended stalls. Where it ended is not established: the step
    /// failed, a settle miss on record, within the settle's own budget — not
    /// the stalled read's — and the open is not sent again.
    @MainActor
    func testAnOpenWhoseEndCannotBeReadAfterItMovedOnFails() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = StallsWhereThePageEndedAfterTheOpen(world.bridge)
        let (engine, _) = Self.engine([{ $0.action.operation == .open && $0.action.target?.name == "Go to the offer" }])
        let run = AgentRun(plan: try plan("https://site-136.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let began = ContinuousClock.now
        let record = await run.run()
        let took = ContinuousClock.now - began
        XCTAssertTrue(bridge.stalled, "the premise: the read of where it ended stalled")
        XCTAssertTrue(world.fixtures.served.contains { $0.host == "site-138.test" }, "the premise: it moved on")
        XCTAssertEqual(record.steps.first { $0.operation == "open" }?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape == "miss settle" }, "\(record.eventLines)")
        XCTAssertLessThan(took, .seconds(8), "the settle's budget, not the stalled read's 10 s")
        XCTAssertEqual(world.fixtures.served.filter { $0.host == "site-137.test" && $0.path == "/" }.count, 1,
                       "opened once")
    }

    /// Stop while the page is being waited on ends the wait at once: the run
    /// returns well within Stop's limit.
    @MainActor
    func testStopWhileWaitingForAPageToGoQuietEndsTheWait() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        let proxy = try XCTUnwrap(world.proxy)
        let (engine, _) = Self.engine([])
        let run = AgentRun(plan: try plan("https://site-124.test/"), errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        defer { run.stop() }
        let stoppedAt = Box<ContinuousClock.Instant>()
        let firstWait = FirstTime()
        let quietWait: @Sendable (String) -> Bool = {
            $0.contains("\"Runtime.evaluate\"") && $0.contains("const QUIET =")
        }
        // Stop only once the quiet read is in flight. Its reply stays held even if the fixture's timer pauses,
        // so returning within Stop's limit proves cancellation, not a page that happened to become quiet.
        proxy.onHeld = { _ in }
        proxy.holdsReply = { message in
            guard quietWait(message) else { return false }
            if firstWait.take() {
                Task { @MainActor in
                    stoppedAt.value = .now
                    run.stop()
                }
            }
            return true
        }
        let result = await Deadline.run(within: .seconds(15)) { await run.run(report: { _ in }) }
        let returned = ContinuousClock.now
        XCTAssertEqual(proxy.messages.filter(quietWait).count, 1, "the run reached its quiet wait once")
        let outcome = try XCTUnwrap(result, "the run must return even if the quiet reply stays held")
        XCTAssertEqual(outcome.ending, .stopped)
        let stop = try XCTUnwrap(stoppedAt.value)
        XCTAssertLessThan(returned - stop, .milliseconds(1_000), "the wait ended with Stop, not with its own time")
    }

    // MARK: - Typing that lands

    /// Types `text` into the field named `name` as the run does after a
    /// person's click on it: the aim, the click, then the typing.
    @MainActor
    private func type(_ text: String, into name: String, on page: ObservedPage, in tab: BrowserTab,
                      world: ChromeWorld, hands: (any TrustedInputBridge)? = nil,
                      stopping: @escaping () -> Bool = { false },
                      afterRead: @escaping (String) -> Void = { _ in },
                      read reader: (any BrowserBridge)? = nil) async throws -> (AgentAction, TrustedTyping.Typed) {
        let action = try page.action(.type, on: name, payload: text)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim, name)
        let clicker: any TrustedInputBridge = hands ?? world.bridge
        try await clicker.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let bridge: any BrowserBridge = reader ?? hands ?? world.bridge
        let typed = try await TrustedTyping.type(action, on: page, approval: nil,
                                                 read: { script in
                                                     let answer = try? await bridge.run(script, in: tab)
                                                     afterRead(script)
                                                     return answer
                                                 }, stopping: stopping)
        return (action, typed)
    }

    @MainActor
    /// The check of what landed, as the run makes it: after the page has
    /// gone quiet, or — `settles: false`, to time the suggestions' wait alone
    /// — at once.
    private func finish(_ typed: TrustedTyping.Typed, _ action: AgentAction, on page: ObservedPage, in tab: BrowserTab,
                        world: ChromeWorld, settles: Bool = true) async throws -> Bool {
        let bridge = world.bridge
        return try await TrustedTyping.finish(typed, action: action, on: page, read: { try? await bridge.run($0, in: tab) },
                                              settle: {
                                                  guard settles else { return }
                                                  _ = try? await bridge.runAwaiting(
                                                      ObserverScript.settledSource(within: .seconds(5)), in: tab)
                                              })
    }

    private static let landed = TrustedTyping.Typed.typed(.init(held: true, suggests: false))
    private static let missed = TrustedTyping.Typed.typed(.init(held: false, suggests: false))

    /// A framework's field that swaps itself for a hydrated copy when it
    /// takes the focus: the text lands in the copy, where the focus went.
    @MainActor
    func testTheTextLandsInTheFieldThePageSwappedInOnFocus() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (action, typed) = try await type("Riga", into: "City", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed)
        let value = try await world.bridge.runInPage("document.getElementById('city-hydrated').value", in: tab)
        XCTAssertEqual(value, "Riga")
        let held = try await finish(typed, action, on: page, in: tab, world: world)
        XCTAssertTrue(held)
    }

    /// The copy the page swaps in is a secret field: the page is the user's
    /// part, and nothing is typed there.
    @MainActor
    func testASecretFieldSwappedInOnFocusIsAWallAndNothingIsTyped() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (_, typed) = try await type("sam", into: "Account", on: page, in: tab, world: world)
        XCTAssertEqual(typed, .wall)
        let value = try await world.bridge.runInPage("document.getElementById('account-secret').value", in: tab)
        XCTAssertEqual(value, "", "never typed into")
    }

    /// An editor the page opens over the field on its first input takes the
    /// focus after the text went in, and the text is gone: typed once more,
    /// into the editor, and it lands there.
    @MainActor
    func testAnEditorThatTookTheFocusLateIsTypedIntoOnceMore() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (action, typed) = try await type("Riga", into: "Search the catalog", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed)
        let seen = try await world.bridge.runInPage(
            "document.getElementById('overlay-search').value + '|' + counts.catalog + '|' + counts.overlay", in: tab)
        XCTAssertEqual(seen, "Riga|1|1", "typed into the field once, then into the editor once")
        let held = try await finish(typed, action, on: page, in: tab, world: world)
        XCTAssertTrue(held)
    }

    /// A field that keeps fewer characters than the text, and one that
    /// reformats a number: the step fails honestly — one typing each, no
    /// retry loop, never "done".
    @MainActor
    func testAFieldThatChangesTheTextFailsHonestlyAfterOneTyping() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (code, cut) = try await type("ABCDEFG", into: "Code", on: page, in: tab, world: world)
        XCTAssertEqual(cut, Self.missed)
        let codeHeld = try await finish(cut, code, on: page, in: tab, world: world)
        XCTAssertFalse(codeHeld)
        let (phone, masked) = try await type("5551234567", into: "Phone", on: page, in: tab, world: world)
        XCTAssertEqual(masked, Self.missed)
        let phoneHeld = try await finish(masked, phone, on: page, in: tab, world: world)
        XCTAssertFalse(phoneHeld)
        let seen = try await world.bridge.runInPage(
            "document.getElementById('code').value + '|' + counts.code + '|' + document.getElementById('phone').value "
                + "+ '|' + counts.phone", in: tab)
        XCTAssertEqual(seen, "ABCD|1|(555) 123-4567|1")
    }

    /// An editor's text is read through its words.
    @MainActor
    func testAnEditorsTextIsCheckedThroughItsWords() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (_, typed) = try await type("Call Sam at noon", into: "Note", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed)
        let words = try await world.bridge.runInPage("document.getElementById('note').innerText", in: tab)
        XCTAssertEqual(words, "Call Sam at noon")
    }

    /// A native date input takes its ISO value through its setter, with the
    /// input and change events its own picker sends, and it is read back.
    @MainActor
    func testANativeDateInputTakesItsIsoValue() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (_, typed) = try await type("2026-10-15", into: "Arrival", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed)
        let seen = try await world.bridge.runInPage(
            "document.getElementById('arrival').value + '|' + counts.arrivalInput + '|' + counts.arrivalChange", in: tab)
        XCTAssertEqual(seen, "2026-10-15|1|1")
        let (_, wrong) = try await type("15.10.2026", into: "Arrival", on: page, in: tab, world: world)
        XCTAssertEqual(wrong, Self.missed, "not an ISO value: it does not hold")
    }

    /// A search whose suggestions arrive 300 ms after the typing: the check
    /// waits for them, so the next look sees them listed.
    @MainActor
    func testSuggestionsThatArriveLaterAreListedWhenThePageIsReadNext() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (action, typed) = try await type("Ri", into: "Find a city", on: page, in: tab, world: world)
        XCTAssertEqual(typed, .typed(.init(held: true, suggests: true)))
        let held = try await finish(typed, action, on: page, in: tab, world: world)
        XCTAssertTrue(held)
        let after = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
        XCTAssertTrue(after.elements.contains { $0.role == "option" && $0.name == "Riga, Latvia" },
                      "the suggestion is there to be chosen")
    }

    /// A field that asks for no suggestions is not waited on; one that asks
    /// and never gets any is waited on for 1.2 s at most.
    @MainActor
    func testTheWaitForSuggestionsIsPaidOnlyByAFieldThatAsksAndIsBounded() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (plain, typedPlain) = try await type("Hello", into: "Plain field", on: page, in: tab, world: world)
        XCTAssertEqual(typedPlain, Self.landed)
        var began = ContinuousClock.now
        let plainHeld = try await finish(typedPlain, plain, on: page, in: tab, world: world, settles: false)
        XCTAssertTrue(plainHeld)
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(200), "no wait")
        let (never, typedNever) = try await type("1999", into: "Search the archive", on: page, in: tab, world: world)
        XCTAssertEqual(typedNever, .typed(.init(held: true, suggests: true)))
        began = ContinuousClock.now
        let neverHeld = try await finish(typedNever, never, on: page, in: tab, world: world, settles: false)
        XCTAssertTrue(neverHeld)
        let waited = ContinuousClock.now - began
        XCTAssertGreaterThan(waited, .milliseconds(1_000))
        XCTAssertLessThan(waited, .milliseconds(2_500), "bounded")
    }

    /// P2-2 (Codex review of I-07): what landed is final only once the page
    /// has gone quiet. A field the page empties 100 ms after the text went in
    /// is a failed step; one it draws anew keeping the text holds it.
    @MainActor
    func testWhatLandedIsFinalOnlyOnceThePageHasGoneQuiet() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (fleeting, typed) = try await type("Riga", into: "Fleeting field", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed, "it landed, at first")
        let emptied = try await finish(typed, fleeting, on: page, in: tab, world: world)
        XCTAssertFalse(emptied, "the page emptied it: the step failed")
        let (redrawn, kept) = try await type("Riga", into: "Redrawn field", on: page, in: tab, world: world)
        XCTAssertEqual(kept, Self.landed)
        let held = try await finish(kept, redrawn, on: page, in: tab, world: world)
        XCTAssertTrue(held, "drawn anew with the text in it")
    }

    /// P2-1: the field the date goes into turns into a secret field between
    /// its preparation and the setter: nothing is written, and the page is the
    /// user's part.
    @MainActor
    func testADateFieldThatTurnsSecretBeforeTheSetterIsAWall() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let hands = TurnsTheFieldBeforeTheWrite(world.bridge,
                                                change: "document.getElementById('arrival').type = 'password'; ''")
        let (_, typed) = try await type("2026-10-15", into: "Arrival", on: page, in: tab, world: world, hands: hands,
                                        read: hands)
        XCTAssertTrue(hands.changed)
        XCTAssertEqual(typed, .wall)
        let seen = try await world.bridge.runInPage(
            "document.getElementById('arrival').value + '|' + counts.arrivalInput", in: tab)
        XCTAssertEqual(seen, "|0", "nothing written")
    }

    /// P2-1 (Codex review of I-07, rounds 1 and 2): the field turns into a
    /// password box, or the focus moves to another field, at the last moment
    /// before the text is written: none goes in, and a secret field makes the
    /// page the user's part. The check and the text are one renderer task, so
    /// nothing can come between them.
    @MainActor
    func testATextFieldThatTurnsSecretOrLosesTheFocusBeforeTheTextGetsNone() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let secret = TurnsTheFieldBeforeTheWrite(world.bridge,
                                                 change: "document.getElementById('plain').type = 'password'; ''")
        let (_, walled) = try await type("hunter2", into: "Plain field", on: page, in: tab, world: world,
                                         hands: secret, read: secret)
        XCTAssertTrue(secret.changed)
        XCTAssertEqual(walled, .wall)
        let value = try await world.bridge.runInPage("document.getElementById('plain').value", in: tab)
        XCTAssertEqual(value, "", "nothing typed into the password box")

        let (freshTab, freshPage) = try await world.open("https://site-128.test/")
        let moved = TurnsTheFieldBeforeTheWrite(world.bridge,
                                                change: "document.getElementById('code').focus(); ''")
        let (_, notTyped) = try await type("Hello", into: "Phone", on: freshPage, in: freshTab, world: world,
                                           hands: moved, read: moved)
        XCTAssertTrue(moved.changed)
        XCTAssertEqual(notTyped, .notTyped)
        let both = try await world.bridge.runInPage(
            "document.getElementById('phone').value + '|' + document.getElementById('code').value", in: freshTab)
        XCTAssertEqual(both, "|", "typed nowhere")
    }

    /// P2-1: the text goes in as the page's own editing does — a field that
    /// takes only trusted input (it empties itself on any other) keeps it.
    @MainActor
    func testTheTextIsTrustedInputThatAFieldKeeps() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-82.test/")
        let (_, typed) = try await type("Sam", into: "Name", on: page, in: tab, world: world)
        XCTAssertEqual(typed, Self.landed)
        let value = try await world.bridge.runInPage("document.getElementById('name').value", in: tab)
        XCTAssertEqual(value, "Sam")
    }

    /// P2-3 (Codex review of I-07, round 2): suggestions end their wait only
    /// in the field's own list — found in the field's own tree first, a
    /// component's shadow root included — and only once they are new. A list
    /// of something else that gains an option 50 ms after the typing never
    /// ends it; a field that names no list waits its whole 1.2 s.
    @MainActor
    func testSuggestionsEndTheirWaitOnlyInTheFieldsOwnList() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, own) in [("Find a street", "Elm Street"), ("Find a town street", "Oak Lane")] {
            let (tab, page) = try await world.open("https://site-141.test/")
            let (action, typed) = try await type("E", into: name, on: page, in: tab, world: world)
            XCTAssertEqual(typed, .typed(.init(held: true, suggests: true)), name)
            let began = ContinuousClock.now
            let held = try await finish(typed, action, on: page, in: tab, world: world, settles: false)
            XCTAssertTrue(held, name)
            let waited = ContinuousClock.now - began
            XCTAssertGreaterThan(waited, .milliseconds(450), "\(name): not ended by another list")
            XCTAssertLessThan(waited, .milliseconds(1_000), "\(name): ended by its own list, not the whole wait")
            let after = try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
            XCTAssertTrue(after.elements.contains { $0.role == "option" && $0.name == own }, name)
        }
        let (tab, page) = try await world.open("https://site-141.test/")
        let (places, typed) = try await type("P", into: "Search places", on: page, in: tab, world: world)
        let began = ContinuousClock.now
        let held = try await finish(typed, places, on: page, in: tab, world: world, settles: false)
        XCTAssertTrue(held)
        XCTAssertGreaterThan(ContinuousClock.now - began, .milliseconds(1_000), "no list of its own: the whole wait")
    }

    /// Stop at each point of typing into the field whose editor takes the
    /// focus late — right after the first text went in, while that text is
    /// checked, while the editor is found — and before any: no text goes in
    /// after Stop, and the editor is not even focused once Stop was pressed.
    @MainActor
    func testNoTextGoesInAfterStop() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        /// A run of the typing on a fresh page, Stop pressed when `stopWhen`
        /// says, from what has been typed and read.
        func typing(stopWhen: @escaping (_ typings: Int, _ reads: [String]) -> Bool)
            async throws -> (typed: TrustedTyping.Typed, typings: Int, reads: [String], overlay: String) {
            let (tab, page) = try await world.open("https://site-128.test/")
            let hands = CountsTheTyping(world.bridge)
            var reads: [String] = []
            var stopped = false
            let (_, typed) = try await type("Riga", into: "Search the catalog", on: page, in: tab, world: world,
                                            hands: hands, stopping: {
                                                stopped = stopped || stopWhen(hands.typings, reads)
                                                return stopped
                                            }, afterRead: { reads.append($0) })
            let overlay = try await world.bridge.runInPage(
                "document.getElementById('overlay-search')?.value ?? 'none'", in: tab)
            return (typed, hands.typings, reads, overlay)
        }
        func read(_ operation: String, in reads: [String]) -> Bool {
            reads.contains { $0.contains("\"operation\":\"\(operation)\"") }
        }

        let afterTyping = try await typing { typings, _ in typings >= 1 }
        XCTAssertEqual(afterTyping.typed, .typed(nil), "stopped before its check: the postcondition reads it")
        XCTAssertEqual(afterTyping.typings, 1)
        XCTAssertFalse(read("landed", in: afterTyping.reads), "no read after Stop")
        XCTAssertEqual(afterTyping.overlay, "")

        let whileChecking = try await typing { _, reads in read("landed", in: reads) }
        XCTAssertEqual(whileChecking.typed, .typed(.init(held: false, suggests: false)), "the check that ran tells")
        XCTAssertEqual(whileChecking.typings, 1)
        XCTAssertFalse(read("focusedAgain", in: whileChecking.reads), "the editor is not focused after Stop")
        XCTAssertEqual(whileChecking.overlay, "")

        let whileFinding = try await typing { _, reads in read("focusedAgain", in: reads) }
        XCTAssertEqual(whileFinding.typings, 1, "found, and not typed into")
        XCTAssertEqual(whileFinding.reads.filter { $0.contains("\"operation\":\"typeText\"") }.count, 1,
                       "not written again after Stop")
        XCTAssertEqual(whileFinding.overlay, "")

        let whileFocusing = try await typing { _, reads in read("focused", in: reads) }
        XCTAssertEqual(whileFocusing.typed, .notTyped)
        XCTAssertEqual(whileFocusing.typings, 0, "Stop as the field was focused: no text")
        XCTAssertEqual(whileFocusing.overlay, "none")

        let before = try await typing { _, _ in true }
        XCTAssertEqual(before.typed, .notTyped)
        XCTAssertEqual(before.typings, 0)
        XCTAssertTrue(before.reads.isEmpty, "nothing read, nothing focused")
        XCTAssertEqual(before.overlay, "none")
    }

    /// Stop while the suggestions are waited for ends the wait at once.
    @MainActor
    func testStopWhileWaitingForSuggestionsEndsTheWait() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-128.test/")
        let (action, typed) = try await type("1999", into: "Search the archive", on: page, in: tab, world: world)
        let bridge = world.bridge
        let waiting = Task { @MainActor in
            try await TrustedTyping.finish(typed, action: action, on: page, read: { try await bridge.run($0, in: tab) },
                                           settle: {})
        }
        try await Task.sleep(for: .milliseconds(200))
        let stoppedAt = ContinuousClock.now
        waiting.cancel()
        _ = try? await waiting.value
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .milliseconds(500), "not the rest of the 1.2 s")
    }
}

/// Every request a scripted engine was asked, in order, from any thread.
final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [ChooseRequest] = []

    /// Keeps `request`; returns its number, from 0.
    func add(_ request: ChooseRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        kept.append(request)
        return kept.count - 1
    }

    var all: [ChooseRequest] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }
}

/// The agent's hands in Chrome, counting the typing that went out: each
/// script that writes the text.
@MainActor
final class CountsTheTyping: WrapsChromeBridge {
    let inner: ChromeBridge
    private(set) var typings = 0

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"typeText\"") { typings += 1 }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, whose read of where the page is, once the
/// page after an open has been waited on, stalls for 10 s, as a call lost on
/// its way does.
@MainActor
final class StallsWhereThePageEndedAfterTheOpen: WrapsChromeBridge {
    let inner: ChromeBridge
    private var opened = false
    private var waited = false
    private(set) var stalled = false

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        defer { if opened { waited = true } }
        return try await inner.runAwaiting(javascript, in: tab)
    }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"open\"") { opened = true }
        if waited, !stalled, javascript.contains("performance.timeOrigin") {
            stalled = true
            try await Task.sleep(for: .seconds(10))
        }
        return try await inner.run(javascript, in: tab)
    }
}

/// The agent's hands in Chrome, changing the page in its own world at the
/// last moment before the text is written — right before the script that
/// checks the field and writes the text in one task — and right before the
/// date's setter.
@MainActor
final class TurnsTheFieldBeforeTheWrite: WrapsChromeBridge {
    let inner: ChromeBridge
    private let change: String
    private(set) var changed = false

    init(_ inner: ChromeBridge, change: String) {
        self.inner = inner
        self.change = change
    }

    private func turn(_ tab: BrowserTab) async throws {
        guard !changed else { return }
        changed = true
        _ = try await inner.runInPage(change, in: tab)
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if ["\"operation\":\"setDate\"", "\"operation\":\"typeText\""].contains(where: javascript.contains) {
            try await turn(tab)
        }
        return try await inner.run(javascript, in: tab)
    }

}

/// The agent's hands in Chrome, failing the first wait for the page to go
/// quiet that follows a click, as a script the page broke fails: at once,
/// and with the page where it was.
@MainActor
final class BreaksTheQuietReadAfterTheClick: WrapsChromeBridge {
    let inner: ChromeBridge
    private var clicked = false
    private(set) var broke = false

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        clicked = true
        try await inner.click(x: x, y: y, in: tab)
    }

    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if clicked, !broke {
            broke = true
            throw BrowserBridgeError.scriptFailed(code: -3)
        }
        return try await inner.runAwaiting(javascript, in: tab)
    }
}
