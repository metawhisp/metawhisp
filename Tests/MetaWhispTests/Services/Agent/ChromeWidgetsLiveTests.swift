import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-08 — the agent's hands, part 2, in a real Chrome (headless, a
/// profile of its own, the fixture pages served from inside Chrome): made-up
/// dropdowns, see-through checkboxes and radios, controls only a script makes
/// clickable, and date, read-only and file fields. Ported from a reference
/// browser agent (MIT). Skipped without Chrome.
final class ChromeWidgetsLiveTests: XCTestCase {

    // MARK: - Helpers

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look around the page",
                                                                                    terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// A run on `start` whose engine picks what it says.
    @MainActor
    private func run(_ world: ChromeWorld, from start: String, engine: any DecisionEngine,
                     bridge: (any BrowserBridge)? = nil,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no }) async throws -> ErrandRecord {
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: bridge ?? world.bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: confirm))
        return await run.run()
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds — choosing «more» until one does — then DONE, keeping every
    /// request it was asked.
    private static func engine(_ picks: [@Sendable (Candidate) -> Bool],
                               irreversible: @escaping @Sendable (AgentAction) -> Double = { _ in 0.05 })
        -> (ScriptedEngine, Requests) {
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
        }, irreversible: irreversible)
        return (engine, requests)
    }

    private static func click(_ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == .click && $0.action.target?.name == name }
    }

    /// What the candidates offer: the operations on each named element.
    private static func offered(on page: ObservedPage,
                                context: CandidateContext = CandidateContext(subgoalTerms: []))
        -> [String: [AgentOperation]] {
        var offered: [String: [AgentOperation]] = [:]
        for candidate in CandidateBuilder.build(page: page, context: context).candidates {
            guard let name = candidate.action.target?.name else { continue }
            offered[name, default: []].append(candidate.action.operation)
        }
        return offered
    }

    /// The options a request offered, in its order.
    private static func options(in request: ChooseRequest) -> [ObservedElement] {
        request.candidates.compactMap(\.action.target).filter { $0.role == "option" }
    }

    /// A person's click on the element named `name`, where the aim says.
    @MainActor
    private func press(_ name: String, on page: ObservedPage, in tab: BrowserTab, world: ChromeWorld) async throws {
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim, name)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
    }

    /// A look at the page once it has gone quiet.
    @MainActor
    private func look(_ tab: BrowserTab, world: ChromeWorld) async throws -> ObservedPage {
        _ = try await world.bridge.runAwaiting(ObserverScript.settledSource(within: .seconds(3)), in: tab)
        return try ObservedPage.decode(try await world.bridge.run(ObserverScript.source, in: tab))
    }

    /// Whether the made-up dropdown `list` shows `option` now, read in the page.
    @MainActor
    private func shows(_ option: String, in list: ObservedElement, on page: ObservedPage, tab: BrowserTab,
                       world: ChromeWorld) async throws -> ActionOutcome.Kind {
        let check = AgentAction(operation: .select, target: list, destination: nil, payload: option,
                                isPlannedSearch: false)
        return try await world.outcome(ActionScript.holds(check, on: page), in: tab).outcome
    }

    // MARK: - 1. Made-up dropdowns

    /// A React-style select — a box that shows its choice, and a list drawn
    /// only while it is open, closed by a press anywhere else: a click opens
    /// it, the next look offers its options as clicks, the click on one is
    /// read back in the page, and the choice is kept: reopened, the list no
    /// longer offers it.
    @MainActor
    func testAMadeUpDropdownIsOpenedItsOptionClickedAndTheChoiceReadBack() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Country"), Self.click("Latvia"), Self.click("Country")])
        let record = try await run(world, from: "https://site-142.test/", engine: engine)
        let first = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(first.candidates.filter { $0.action.target?.name == "Country" }.map(\.action.operation), [.click],
                       "a click opens it")
        XCTAssertEqual(record.steps.map(\.operation), ["click", "click", "click", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 4)
        guard requests.all.count == 4 else { return }
        XCTAssertEqual(Self.options(in: requests.all[1]).map(\.name), ["Estonia", "Latvia", "Lithuania", "Finland"],
                       "the next look offers its options")
        XCTAssertEqual(Self.options(in: requests.all[3]).map(\.name), ["Estonia", "Lithuania", "Finland"],
                       "the choice was read back and is kept: not offered again")
    }

    /// The same list with 300 options, six of them in sight: the ones a
    /// person sees are offered first, and one the list hides is scrolled into
    /// sight in the list and clicked.
    @MainActor
    func testALongMadeUpListOffersWhatItShowsFirstAndScrollsToTheRest() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Size"), Self.click("Size 9"), Self.click("Size")])
        let record = try await run(world, from: "https://site-143.test/", engine: engine)
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 4)
        guard requests.all.count == 4 else { return }
        let offered = Self.options(in: requests.all[1])
        let shown = offered.prefix { $0.inViewport }
        XCTAssertEqual(shown.first?.name, "Size 1")
        XCTAssertGreaterThanOrEqual(shown.count, 5, "the options in sight: \(offered.map(\.name))")
        XCTAssertTrue(offered.dropFirst(shown.count).allSatisfy { !$0.inViewport }, "then the ones it hides")
        XCTAssertEqual(offered.first { $0.name == "Size 9" }?.inViewport, false, "the premise: Size 9 is out of sight")
        let reopened = Self.options(in: requests.all[3]).map(\.name)
        XCTAssertFalse(reopened.contains("Size 9"), "chosen: \(reopened)")
        XCTAssertTrue(reopened.contains("Size 8"))
    }

    /// A list that opens on the press but not on the click, and one that
    /// closes when the focus moves: each takes its choice, read back, and
    /// still chosen when it is opened again.
    @MainActor
    func testAListOpenedOnThePressOrClosedOnBlurStillTakesItsChoice() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Fit"), Self.click("Loose"), Self.click("Colour"),
                                              Self.click("Green"), Self.click("Fit"), Self.click("Colour")])
        let record = try await run(world, from: "https://site-144.test/", engine: engine)
        XCTAssertEqual(record.steps.prefix(6).map(\.outcome), Array(repeating: .acted, count: 6), "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 7)
        guard requests.all.count == 7 else { return }
        XCTAssertEqual(Self.options(in: requests.all[1]).map(\.name), ["Slim", "Regular", "Loose"])
        XCTAssertEqual(Self.options(in: requests.all[5]).map(\.name), ["Slim", "Regular"], "Loose is still chosen")
        XCTAssertEqual(Self.options(in: requests.all[6]).map(\.name), ["Red", "Blue"], "Green is still chosen")
    }

    /// An editable made-up dropdown is typed into, as a field is; its
    /// suggestion is then a click, found as one of its list's, and what the
    /// field shows after it is read back. One that is read-only is opened
    /// by a click, and never typed into.
    @MainActor
    func testAnEditableDropdownIsTypedIntoAndItsSuggestionClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-145.test/")
        let offered = Self.offered(on: page)
        XCTAssertEqual(offered["City"], [.type])
        XCTAssertEqual(offered["Airport"], [.click], "read-only: a click opens it")
        let city = try page.action(.type, on: "City", payload: "Ri")
        let aim = try await world.outcome(ActionScript.aim(for: city, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let bridge = world.bridge
        let typed = try await TrustedTyping.type(city, on: page, approval: nil,
                                                 read: { try? await bridge.run($0, in: tab) }, stopping: { false })
        XCTAssertEqual(typed, .typed(.init(held: true, suggests: true)))
        let listed = try await look(tab, world: world)
        let field = try XCTUnwrap(listed.elements.first { $0.name == "City" })
        let riga = try XCTUnwrap(listed.elements.first { $0.name == "Riga, Latvia" })
        XCTAssertEqual(riga.role, "option")
        XCTAssertEqual(riga.listOf, field.index, "one of the field's own list")
        XCTAssertEqual(Self.offered(on: listed)["Riga, Latvia"], [.click])
        try await press("Riga, Latvia", on: listed, in: tab, world: world)
        let held = try await shows("Riga, Latvia", in: field, on: listed, tab: tab, world: world)
        XCTAssertEqual(held, .held)

        try await press("Airport", on: page, in: tab, world: world)
        let open = try await look(tab, world: world)
        let airport = try XCTUnwrap(open.elements.first { $0.name == "Airport" })
        XCTAssertEqual(open.elements.first { $0.name == "Tallinn Airport" }?.listOf, airport.index)
        try await press("Tallinn Airport", on: open, in: tab, world: world)
        let chosen = try await shows("Tallinn Airport", in: airport, on: open, tab: tab, world: world)
        XCTAssertEqual(chosen, .held)
    }

    /// A secret field inside a made-up dropdown, and a made-up dropdown that
    /// is itself a secret field — each marked secret by its structure, a
    /// password and a card number's autocomplete — are hidden as any secret
    /// field is: never reported or offered; with the secret field in sight,
    /// the dropdown's option is the user's part.
    @MainActor
    func testASecretFieldInsideAMadeUpDropdownIsStillHidden() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-150.test/")
        XCTAssertNil(page.elements.first { $0.name == "Card number" }, "a dropdown that is a secret field")
        XCTAssertTrue(page.flags.paymentForm)
        try await press("Saved addresses", on: page, in: tab, world: world)
        let open = try await look(tab, world: world)
        XCTAssertFalse(open.elements.contains { $0.name.contains("PIN") }, "\(open.elements.map(\.name))")
        XCTAssertTrue(open.flags.loginForm)
        XCTAssertEqual(open.elements.first { $0.name == "Home" }?.touchesSecret, true)

        let (engine, requests) = Self.engine([Self.click("Saved addresses"), Self.click("Home")])
        let record = try await run(world, from: "https://site-150.test/", engine: engine)
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape.hasPrefix("handover ") }, "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 2)
        for request in requests.all {
            XCTAssertFalse(request.candidates.contains {
                ($0.action.target?.name ?? "").contains("PIN") || $0.action.target?.name == "Card number"
            })
        }
    }

    /// Stop while a made-up list is open: nothing is chosen after it.
    @MainActor
    func testStopWhileAListIsOpenChoosesNothing() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (picks, requests) = Self.engine([Self.click("Country"), Self.click("Latvia")])
        let engine = StopsOnItsSecondQuestion(picks)
        let hands = CountsTheClicks(world.bridge)
        let run = AgentRun(plan: try plan("https://site-142.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        engine.stop = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(engine.asked, 2)
        XCTAssertEqual(requests.all.count, 2)
        guard requests.all.count == 2 else { return }
        XCTAssertEqual(Self.options(in: requests.all[1]).map(\.name), ["Estonia", "Latvia", "Lithuania", "Finland"],
                       "the list was open when Stop came")
        XCTAssertEqual(hands.clicks, 1, "only the click that opened it")
        XCTAssertEqual(run.record.steps.map(\.operation), ["click"], "\(run.record.eventLines)")
        XCTAssertEqual(run.record.steps.first?.outcome, .acted, "it opened the list")
    }

    /// 2026-10-15 (the bench's bstackdemo sort: "Order by" beside a select of its own with no label, and the sort was
    /// never offered — Jev clicked the "Orders" link instead): a native select with no name is named — since
    /// 2026-10-21 by the words before it in its own group, "Order by", else, as a reference browser agent names a
    /// control with none, by its role — and offered with its options.
    @MainActor
    func testANativeSelectWithNoLabelIsOfferedByItsRoleWithItsOptions() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-475.test/")
        let sort = try XCTUnwrap(page.elements.first { $0.role == "combobox" }, "\(page.elements.map(\.name))")
        XCTAssertEqual(sort.name, "Order by")
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
        XCTAssertEqual(Set(offered.candidates.compactMap { $0.action.target?.role == "combobox" ? $0.action.target?.index : nil }),
                       [sort.index], "a disabled select, by itself or by its fieldset, is not offered (Codex review P2-5)")
        let sorting = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: ["Sort lowest to highest"]))
        XCTAssertTrue(sorting.candidates.contains { $0.action.operation == .select && $0.action.target?.index == sort.index
                && $0.action.payload == "Lowest to highest" }, "\(sorting.candidates.map(\.action))")
    }

    // MARK: - 2. See-through checkboxes and radios

    /// A box drawn by CSS over a see-through input is offered through its
    /// label, with the input's state — and clicked on the input where it
    /// covers its label whole. With its label hidden, the input itself is, as
    /// a to-do's box with no label is: named, as a reference browser agent
    /// names a control with no name, by its role, and told apart by its row.
    /// One switched off, or that takes no pointer, never is. Each is ticked by
    /// a click, and the state is read from the input.
    @MainActor
    func testASeeThroughCheckboxIsOfferedThroughItsLabelOrItself() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-146.test/")
        // Name, row and role of each box, in the page's order.
        let expected: [(name: String, context: String?, role: String)] = [
            ("I agree to the terms", nil, "checkbox"), ("checkbox", nil, "checkbox"), ("Yearly billing", nil, "radio"),
            ("Show me offers", nil, "checkbox"), ("checkbox", "Buy milk", "checkbox")]
        let boxes = page.elements.filter { ["checkbox", "radio"].contains($0.role) && $0.name != "Send me weekly news" }
        XCTAssertEqual(boxes.map(\.name), expected.map(\.name))
        XCTAssertEqual(boxes.map(\.context), expected.map(\.context))
        XCTAssertEqual(boxes.map(\.role), expected.map(\.role))
        XCTAssertEqual(boxes.map(\.checked), Array(repeating: false, count: expected.count))
        let offered = CandidateBuilder.build(page: page, context: CandidateContext(subgoalTerms: []))
        for box in boxes {
            XCTAssertEqual(offered.candidates.filter { $0.action.target?.index == box.index }.map(\.action.operation),
                           [.click], "\(box.name) \(box.context ?? "")")
        }
        XCTAssertFalse(page.elements.contains { ["Locked choice", "Dim choice"].contains($0.name) }, "switched off")
        XCTAssertFalse(page.elements.contains { $0.context == "Archived task" }, "takes no pointer")
        for box in boxes {
            let action = AgentAction(operation: .click, target: box, destination: nil, payload: nil, isPlannedSearch: false)
            let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, box.name)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        }
        let after = try await look(tab, world: world)
        let ticked = after.elements.filter { ["checkbox", "radio"].contains($0.role) && $0.name != "Send me weekly news" }
        XCTAssertEqual(ticked.map(\.checked), Array(repeating: true, count: expected.count))
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "terms;news;yearly;offers;milk;", "pressed in the page's order")
    }

    /// Review of I-08, F2: a control of its own around a hidden input and its
    /// label is one control: offered once, and clickable.
    @MainActor
    func testALabelInsideAControlIsNoSecondControl() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-146.test/")
        let weekly = page.elements.filter { $0.name == "Send me weekly news" }
        XCTAssertEqual(weekly.map(\.role), ["checkbox"], "one control")
        XCTAssertEqual(Self.offered(on: page)["Send me weekly news"], [.click])
        try await press("Send me weekly news", on: page, in: tab, world: world)
        let after = try await look(tab, world: world)
        XCTAssertEqual(after.elements.first { $0.name == "Send me weekly news" }?.checked, true)
    }

    /// The loop ticks the consent box through its label — "agree" asks the
    /// user first, as it does on any control — and its check reads the
    /// input's state: confirmed, and ticked.
    @MainActor
    func testTheLoopTicksASeeThroughConsentBox() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("I agree to the terms")])
        let record = try await run(world, from: "https://site-146.test/", engine: engine, confirm: { _ in .yes })
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"], "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape == "question click checkbox" }, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        XCTAssertEqual(requests.all.last?.candidates.first { $0.action.target?.name == "I agree to the terms" }?
            .action.target?.checked, true)
    }

    // MARK: - 3. Controls only a script makes clickable

    /// Anchors with no address but a handler — a date picker's, one with its
    /// own `onclick`, one that says it is a button — and a card clickable
    /// only by its own handler are buttons; a panel with a pointer cursor and
    /// no handler is nothing.
    @MainActor
    func testAnchorsAndCardsOnlyAScriptMakesClickableAreButtons() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-147.test/")
        let offered = Self.offered(on: page)
        for name in ["Earlier month", "Later month", "Add to list", "Show more", "Blue mug ceramic, 350 ml"] {
            XCTAssertEqual(offered[name], [.click], name)
            XCTAssertEqual(page.elements.first { $0.name == name }?.role, "button", name)
            XCTAssertNil(page.elements.first { $0.name == name }?.href, name)
        }
        XCTAssertNil(page.elements.first { $0.name == "Decorative panel" }, "the cursor is no handler")
        try await press("Later month", on: page, in: tab, world: world)
        try await press("Add to list", on: page, in: tab, world: world)
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "next;added;")
    }

    // MARK: - 4. Date, read-only and file fields

    /// A read-only date field with a calendar is offered as a click that
    /// opens the calendar, and nothing is typed; one read-only by its role
    /// too. Native date, time and colour fields are typed through their
    /// setters (colour: 2026-10-19, a practice form's colour field took no
    /// text on any brain).
    @MainActor
    func testAReadOnlyDateFieldIsOpenedByAClickAndNativeOnesAreTyped() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-148.test/")
        let offered = Self.offered(on: page)
        XCTAssertEqual(offered["Check-in"], [.click])
        XCTAssertEqual(offered["Check-out"], [.click])
        XCTAssertEqual(offered["Departure"], [.type])
        XCTAssertEqual(offered["Pickup time"], [.type])
        XCTAssertEqual(offered["Favourite colour"], [.type])
        try await press("Check-in", on: page, in: tab, world: world)
        let bridge = world.bridge
        for (name, value) in [("Departure", "2026-10-15"), ("Pickup time", "14:30"), ("Favourite colour", "#3366A0")] {
            let action = try page.action(.type, on: name, payload: value)
            let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
            let typed = try await TrustedTyping.type(action, on: page, approval: nil,
                                                     read: { try? await bridge.run($0, in: tab) }, stopping: { false })
            XCTAssertEqual(typed, .typed(.init(held: true, suggests: false)), name)
        }
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "calendar;departure 2026-10-15;pickup 14:30;favourite #3366a0;",
                       "the calendar opened by a click; the colour held as the field writes it")
        for name in ["Check-in", "Check-out"] {
            let write = try await world.outcome(
                ActionScript.aim(for: try page.action(.type, on: name, payload: "2026-10-15"), on: page), in: tab)
            XCTAssertEqual(write.outcome, .gone, "\(name): the hands never write in it either")
        }

        let (engine, _) = Self.engine([Self.click("Check-in")])
        let record = try await run(world, from: "https://site-148.test/", engine: engine)
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .acted, "the click opened its calendar: \(record.eventLines)")
    }

    /// A file field is never offered, required or not. A click that would
    /// send the form needing a file is the user's part: a hand-over of its own
    /// kind, before any question, and nothing is sent, typed or picked. The
    /// form whose file is optional is sent as any form is: asked about.
    @MainActor
    func testAFormThatNeedsAFileIsHandedOverAndAFileFieldIsNeverOffered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-149.test/")
        let offered = Self.offered(on: page)
        XCTAssertEqual(page.elements.first { $0.name == "Your CV" }?.inputType, "file", "reported")
        XCTAssertNil(offered["Your CV"], "never offered")
        XCTAssertNil(offered["Picture"], "never offered")
        XCTAssertEqual(offered["Send application"], [.click])
        XCTAssertEqual(offered["Full name"], [.type])

        let (engine, _) = Self.engine([Self.click("Send application")])
        let record = try await run(world, from: "https://site-149.test/", engine: engine,
                                   confirm: { _ in XCTFail("never asked"); return .no })
        XCTAssertEqual(record.ending, .needsUser, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains { $0.shape == "handover file site-149.test" }, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .handedOver)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/apply" }, "nothing sent, its own check off")

        let (optional, _) = Self.engine([Self.click("Send note")])
        let asked = Counter()
        let noted = try await run(world, from: "https://site-149.test/", engine: optional,
                                  confirm: { _ in asked.add(); return .no })
        XCTAssertEqual(asked.value, 1, "asked about, as any send: \(noted.eventLines)")
        XCTAssertFalse(noted.events.contains { $0.shape.hasPrefix("handover") })
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "a No sends nothing")
    }

    /// A file field is never touched by the hands either: the aim refuses it.
    @MainActor
    func testTheHandsRefuseAFileField() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-149.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Your CV"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .unsupported)
    }

    // MARK: - Review of I-08

    /// Safety F1: a form that needs a file, sent by script — an anchor with no
    /// address, a button that is no submitter, a box that says it is a button
    /// — is the user's part before any question, and nothing is sent. Its own
    /// check is off: a click that got through would send it.
    @MainActor
    func testAFormThatNeedsAFileSentByScriptIsHandedOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-151.test/")
        for sender in ["Send by link", "Send by button", "Send by box"] {
            XCTAssertEqual(page.elements.first { $0.name == sender }?.needsFile, true, sender)
        }
        for setter in ["Keep a copy", "Title"] {
            XCTAssertEqual(page.elements.first { $0.name == setter }?.needsFile, false, "\(setter): a click sends nothing")
        }
        for sender in ["Send by link", "Send by button", "Send by box"] {
            let (engine, _) = Self.engine([Self.click(sender)])
            let asked = Counter()
            let record = try await run(world, from: "https://site-151.test/", engine: engine,
                                       confirm: { _ in asked.add(); return .yes })
            XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape),
                           ["handover file site-151.test"], "\(sender): \(record.eventLines)")
            XCTAssertEqual(asked.value, 0, "\(sender): no question")
        }
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/upload" }, "nothing sent")
    }

    /// Safety F2: the option of a made-up dropdown in a POST form, its list
    /// drawn at the end of the page, goes with that form: its click is asked
    /// about as any click in a POST form is, whatever language its words are
    /// in, and a No sends nothing.
    @MainActor
    func testAnOptionDrawnOutsideItsDropdownsPostFormIsAskedAbout() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let remove = "Supprimer l'acc\u{E8}s"
        let (engine, requests) = Self.engine([Self.click("Access"), Self.click(remove)])
        let answers = Counter()
        let record = try await run(world, from: "https://site-152.test/", engine: engine, confirm: { _ in
            answers.add()
            return answers.value == 1 ? .yes : .no
        })
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("question") }.map(\.shape),
                       ["question click combobox", "question click option"], "\(record.eventLines)")
        let option = requests.all.count > 1 ? Self.options(in: requests.all[1]).first { $0.name == remove } : nil
        XCTAssertEqual(option?.listForm?.method, "post", "its dropdown's form, kept beside its own")
        XCTAssertEqual(option?.listForm?.action, "https://site-152.test/admin/users/42")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/admin/users/42" }, "a No sends nothing")
    }

    /// Safety F2: an option drawn outside its dropdown's form goes with that
    /// form whole — where it sends, how, its submit label, whether it grants
    /// access, whether it could send the form's secret field, and the amount
    /// it shows. Since Codex review 1 (P1-3) the dropdown's form is kept
    /// beside the one the option is drawn in, which here is none.
    @MainActor
    func testAnOptionDrawnOutsideItsDropdownsFormGoesWithThatForm() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-159.test/")
        _ = try await world.bridge.runInPage("document.getElementById('kind').click(); ''", in: tab)
        let open = try await look(tab, world: world)
        let kind = try XCTUnwrap(open.elements.first { $0.name == "Card kind" })
        let plastic = try XCTUnwrap(open.elements.first { $0.name == "Plastic" })
        XCTAssertEqual(plastic.listOf, kind.index)
        XCTAssertEqual(plastic.region, .aside, "the premise: drawn outside the form")
        XCTAssertNil(plastic.formMethod, "drawn in no form")
        XCTAssertEqual(plastic.listForm, ObservedElement.ListForm(action: "https://site-159.test/redeem", method: "get",
                                                                   submitLabel: "Redeem", grants: false))
        XCTAssertEqual(plastic.touchesSecret, true, "its form holds a secret field filled in")
        XCTAssertEqual(plastic.showsAmount, true, "its form shows an amount")
    }

    /// Safety F3: a label with a handler of its own stays the control it was,
    /// a button, which commits: an irreversible click on it is asked about,
    /// and goes with the Yes — a page that shows what it costs asks no card,
    /// so it is no payment (owner decision of 2026-10-19).
    @MainActor
    func testALabelWithAHandlerOfItsOwnStaysAButtonThatCommits() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-153.test/")
        XCTAssertEqual(page.elements.first { $0.name == "Pro" }?.role, "button")
        let (engine, _) = Self.engine([Self.click("Pro")], irreversible: { _ in 0.9 })
        let asked = Counter()
        let record = try await run(world, from: "https://site-153.test/", engine: engine, confirm: { _ in
            asked.add()
            return .yes
        })
        XCTAssertEqual(asked.value, 1, "asked once: \(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertTrue(world.fixtures.served.contains { $0.path == "/buy" }, "went with the Yes: \(record.eventLines)")
    }

    /// Safety F4: the saved numbers a secret field — one that draws dots —
    /// lists at the end of the page are its own: none of them is reported —
    /// as an option, a name, or the page's text.
    @MainActor
    func testTheListASecretFieldOwnsIsWithheldWithIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-154.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertNil(page.elements.first { $0.name == "Passport number" }, "the premise: a secret field")
        XCTAssertNotNil(page.elements.first { $0.name == "Continue" })
        XCTAssertFalse(page.elements.contains { $0.role == "option" })
        for number in ["AB1234567", "CD7654321", "QR4545454", "YZ5656565"] { XCTAssertFalse(json.contains(number), number) }
    }

    /// Correctness F1: a control below the fold of an app that scrolls its
    /// own root, under a sticky header and over a fixed bar, is brought to the
    /// middle and clicked — not left at an edge, covered.
    @MainActor
    func testAControlInAnAppThatScrollsItsRootIsBroughtToTheMiddle() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.click("Compare plans")])
        let record = try await run(world, from: "https://site-155.test/", engine: engine)
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .acted, "\(record.eventLines)")
    }

    /// Correctness F4: a checkbox holds no typed secret. A styled toggle named
    /// "Two-factor authentication", and a plain box named "Pin to top", on a
    /// page with no form are boxes, and the page's other controls stay the
    /// errand's.
    @MainActor
    func testAToggleIsNoSecretWhateverItsWords() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-156.test/")
        XCTAssertFalse(page.flags.loginForm)
        XCTAssertEqual(page.elements.first { $0.name == "Two-factor authentication" }?.role, "checkbox")
        XCTAssertEqual(page.elements.first { $0.name == "Pin to top" }?.role, "checkbox")
        XCTAssertEqual(page.elements.first { $0.name == "Help" }?.touchesSecret, false)
        let (engine, _) = Self.engine([Self.click("Help")])
        let record = try await run(world, from: "https://site-156.test/", engine: engine)
        XCTAssertEqual(record.steps.map(\.operation), ["click", "done"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .acted, "\(record.eventLines)")
    }

    /// Correctness F5: a made-up dropdown on a product card, its list drawn in
    /// the card: the card reads the same open or closed, so the choice is read
    /// back, kept, and not offered again.
    @MainActor
    func testAChoiceInADropdownWhoseListIsDrawnInItsCardIsKept() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Size"), Self.click("Medium"), Self.click("Size")])
        let record = try await run(world, from: "https://site-157.test/", engine: engine)
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 4)
        guard requests.all.count == 4 else { return }
        XCTAssertEqual(Self.options(in: requests.all[1]).map(\.name), ["Small", "Medium", "Large"])
        XCTAssertEqual(Self.options(in: requests.all[3]).map(\.name), ["Small", "Large"])

        // The same where the list is drawn inside the dropdown itself.
        let (inside, asked) = Self.engine([Self.click("Colour"), Self.click("Blue"), Self.click("Colour")])
        let hat = try await run(world, from: "https://site-157.test/", engine: inside)
        XCTAssertEqual(hat.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(hat.eventLines)")
        XCTAssertEqual(asked.all.count, 4)
        guard asked.all.count == 4 else { return }
        XCTAssertEqual(Self.options(in: asked.all[1]).map(\.name), ["Grey", "Blue", "Green"])
        XCTAssertEqual(Self.options(in: asked.all[3]).map(\.name), ["Grey", "Green"])
    }

    /// Correctness F6: two made-up dropdowns name one list; it is the open
    /// one's. A choice in one hides nothing in the other, and each is read
    /// back on its own. With both claiming to be open, the list is no one's.
    @MainActor
    func testAListTwoDropdownsNameIsTheOpenOnes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Billing country"), Self.click("Canada"),
                                              Self.click("Shipping country"), Self.click("Mexico"),
                                              Self.click("Shipping country")])
        let record = try await run(world, from: "https://site-158.test/", engine: engine)
        XCTAssertEqual(record.steps.prefix(5).map(\.outcome), Array(repeating: .acted, count: 5), "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 6)
        guard requests.all.count == 6 else { return }
        XCTAssertEqual(Self.options(in: requests.all[3]).map(\.name), ["Canada", "Mexico", "Chile"],
                       "Canada, chosen for billing, is still shipping's to choose")
        XCTAssertEqual(Self.options(in: requests.all[5]).map(\.name), ["Canada", "Chile"], "Mexico read back on shipping")

        let (tab, _) = try await world.open("https://site-158.test/")
        _ = try await world.bridge.runInPage("draw(document.getElementById('billing')); "
            + "document.getElementById('shipping').setAttribute('aria-expanded', 'true'); ''", in: tab)
        let both = try await look(tab, world: world)
        XCTAssertFalse(both.elements.contains { $0.role == "option" },
                       "whose they are cannot be proved: not reported (Codex review 3 of I-08, P1-2)")
    }

    /// TV-6 (b): the loop's own path through an editable dropdown: its
    /// suggestions listed by the page, one clicked, read back in the field,
    /// and not offered again while the field still shows it. The loop does
    /// not type yet — a type it chooses carries no text until a text writer
    /// exists — so the page's own button lists the suggestions.
    @MainActor
    func testTheLoopChoosesAnEditableDropdownsSuggestionAndKeepsIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Recent cities"), Self.click("Riga, Latvia"),
                                              Self.click("Recent cities")])
        let record = try await run(world, from: "https://site-145.test/", engine: engine)
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 4)
        guard requests.all.count == 4 else { return }
        XCTAssertEqual(Self.options(in: requests.all[1]).map(\.name), ["Riga, Latvia", "Rome, Italy", "Oslo, Norway"])
        XCTAssertEqual(Self.options(in: requests.all[3]).map(\.name), ["Rome, Italy", "Oslo, Norway"])
    }

    /// TV-6 (c): a choice is still known once the page draws its dropdown
    /// anew: a new node, the same control, the choice not offered again.
    @MainActor
    func testAChoiceIsStillKnownWhenThePageDrawsItsDropdownAnew() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Country"), Self.click("Latvia"), Self.click("Country")])
        let record = try await run(world, from: "https://site-142.test/?redraw=1", engine: engine)
        XCTAssertEqual(record.steps.prefix(3).map(\.outcome), [.acted, .acted, .acted], "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 4)
        guard requests.all.count == 4 else { return }
        let country = { (request: ChooseRequest) in
            request.candidates.compactMap(\.action.target).first { $0.name == "Country" }
        }
        XCTAssertNotEqual(country(requests.all[0])?.key, country(requests.all[2])?.key, "the premise: drawn anew")
        XCTAssertEqual(Self.options(in: requests.all[3]).map(\.name), ["Estonia", "Lithuania", "Finland"])
    }

    // MARK: - Codex review 1 of I-08

    /// A run of `plan` on `world` whose engine is `engine`.
    @MainActor
    private func run(_ world: ChromeWorld, plan: AgentPlan, engine: any DecisionEngine) async -> ErrandRecord {
        let run = AgentRun(plan: plan, errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        return await run.run()
    }

    /// P1-1: a secret widget — one that draws dots — whose field inside
    /// names a list drawn elsewhere owns that list. Neither its numbers nor
    /// those of a secret field's own list reach the report — names, text,
    /// rows — the excerpt, or the bytes of a request to Jev.
    @MainActor
    func testWhatASecretWidgetsFieldListsReachesNoReportAndNoJevRequest() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let numbers = ["AB1234567", "CD7654321", "XY7654321", "QZ9988776"]
        let tab = try await world.bridge.openTab(URL(string: "https://site-154.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let excerpt = try await world.bridge.run(ObserverScript.excerptSource(), in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertNil(page.elements.first { $0.name == "Identity card number" }, "the premise: a secret widget")
        XCTAssertTrue(page.text.contains("Traveller"), "the premise: the page's text is read")
        for number in numbers {
            XCTAssertFalse(json.contains(number), "report: \(number)")
            XCTAssertFalse(excerpt.contains(number), "excerpt: \(number)")
        }
        let jev = JevStub(clicking: [])
        let plan = try XCTUnwrap(AgentPlan(goal: "Look around the page",
                                           subgoals: [.init(description: "Look around the page", terms: ["page"])],
                                           searches: [URL(string: "https://site-154.test/")!], columns: ["Name"],
                                           sheetTitle: "Page", rowsWanted: 1, emptyCell: "n/a"))
        let record = await run(world, plan: plan, engine: jev.engine)
        XCTAssertEqual(record.ending, .done, "\(record.eventLines)")
        XCTAssertFalse(jev.sent.isEmpty, "the premise: Jev was asked")
        for body in jev.sent {
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("Continue"), "the premise: the page's controls are in the request")
            for number in numbers { XCTAssertFalse(text.contains(number), "Jev request: \(number)") }
        }
    }

    /// P1-2: the dropdown that owns an option is part of what the option is.
    /// The list switches to another record's dropdown while the Yes for the
    /// first one's option waits: nothing is clicked, and nothing is sent.
    @MainActor
    func testAnOptionWhoseListMovesToAnotherDropdownWhileTheYesWaitsIsNotClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Archived")])
        let record = try await run(world, from: "https://site-167.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage("retarget(); ''", in: request.tab)
            return .yes
        })
        XCTAssertTrue(record.events.contains { $0.shape == "answer yes" }, "the premise: asked, and Yes: \(record.eventLines)")
        XCTAssertFalse(record.steps.contains { $0.outcome == .confirmed }, "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path.hasPrefix("/records") }, "nothing sent, for either record")

        // What it is, what the act is bound to, and what a No refuses all
        // follow the dropdown.
        let (tab, before) = try await world.open("https://site-167.test/")
        let archived = try before.action(.click, on: "Archived")
        _ = try await world.bridge.runInPage("retarget(); ''", in: tab)
        let after = try await look(tab, world: world)
        XCTAssertNil(after.element(matching: before.identity(of: try XCTUnwrap(archived.target))), "another option now")
        let aim = try await world.outcome(ActionScript.aim(for: archived, on: before), in: tab)
        XCTAssertEqual(aim.outcome, .gone, "the act is bound to the first record's dropdown")
        let left = Self.offered(on: after, context: CandidateContext(subgoalTerms: [],
                                                                    refused: [archived.effect]))
        XCTAssertEqual(left["Archived"], [.click], "a No for the first record's is no No for the second's")
    }

    /// P1-2: the list drawn anew, still the first record's while the Yes
    /// waits, is the same option: clicked, for that record.
    @MainActor
    func testAnOptionWhoseListIsDrawnAnewForItsOwnDropdownIsStillClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Archived")])
        let record = try await run(world, from: "https://site-167.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage("draw(); ''", in: request.tab)
            return .yes
        })
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        XCTAssertTrue(world.fixtures.served.contains { $0.path == "/records/a" }, "sent for record A")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/records/b" })
    }

    /// P1-3: an option keeps the form its dropdown sends as well as the one
    /// the page draws it in, and is judged by the stricter: its dropdown's
    /// form grants an app access, so its click is the user's part — no
    /// question, no request — though the page drew it inside a search form.
    @MainActor
    func testAnOptionDrawnInAnotherFormStillGrantsWhatItsDropdownsFormGrants() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.click("Everything")])
        let asked = Counter()
        let record = try await run(world, from: "https://site-160.test/", engine: engine,
                                   confirm: { _ in asked.add(); return .yes })
        XCTAssertTrue(record.events.contains { $0.shape == "handover grant site-160.test" }, "\(record.eventLines)")
        XCTAssertEqual(asked.value, 0, "never asked")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/connect/app" })
    }

    /// P1-3: the same where the dropdown's form is a POST form that grants
    /// nothing: the click is asked about, and a No sends nothing.
    @MainActor
    func testAnOptionDrawnInAnotherFormIsAskedAboutAsItsDropdownsPostForm() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.click("Everything")])
        let record = try await run(world, from: "https://site-161.test/", engine: engine)
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("question") }.map(\.shape), ["question click option"],
                       "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/settings" }, "a No sends nothing")

        // The dropdown's form starts to grant access after the checks: the act
        // is bound to the form they saw, and does nothing.
        let (tab, page) = try await world.open("https://site-161.test/")
        _ = try await world.bridge.runInPage("const f = document.getElementById('auth'); "
            + "for (const [n, v] of [['client_id', 'app-2'], ['redirect_uri', 'https://site-161.test/back'], "
            + "['response_type', 'code']]) { const i = document.createElement('input'); i.type = 'hidden'; "
            + "i.name = n; i.value = v; f.appendChild(i); } ''", in: tab)
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Everything"), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .gone)
    }

    /// P1-3: what an option's dropdown's form says is read as the option's
    /// own form is: its button's words ask the user first, and a form that
    /// leaves the browser makes the option offer nothing.
    @MainActor
    func testAnOptionIsReadByItsDropdownsFormsWordsAndAddress() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-169.test/")
        XCTAssertNotNil(page.elements.first { $0.name == "Support team" }, "the premise: reported")
        XCTAssertNil(Self.offered(on: page)["Support team"], "its dropdown's form leaves the browser")
        let (engine, _) = Self.engine([Self.click("Everything")])
        let record = try await run(world, from: "https://site-169.test/", engine: engine)
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("question") }.map(\.shape), ["question click option"],
                       "its dropdown's form says \"Delete files\": \(record.eventLines)")
        // A form whose button says it grants, or whose address asks for
        // access: the option grants, and is the user's part.
        for option in ["Notes app", "Work account"] {
            let (grants, _) = Self.engine([Self.click(option)])
            let granted = try await run(world, from: "https://site-169.test/", engine: grants)
            XCTAssertTrue(granted.events.contains { $0.shape == "handover grant site-169.test" },
                          "\(option): \(granted.eventLines)")
        }
    }

    /// P1-4: a label for a hidden checkbox, covered whole by a plain label for
    /// another form's submit button. A click on the checkbox's label must not
    /// land on the other label: the aim finds no point that is the checkbox's
    /// own, and no form is sent.
    @MainActor
    func testACheckboxsLabelCoveredByAnotherControlsLabelIsNotClickedThroughIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-162.test/")
        let agree = try XCTUnwrap(page.elements.first { $0.name == "I agree" })
        XCTAssertEqual(agree.role, "checkbox", "the premise: the label stands for the checkbox")
        let action = AgentAction(operation: .click, target: agree, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        if aim.outcome == .aim, let x = aim.x, let y = aim.y {
            try await world.bridge.click(x: x, y: y, in: tab)
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(aim.outcome, .covered)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/other" }, "the other form is never sent")
    }

    /// P2-1: a form that needs a file is the user's part whatever its sender
    /// says it is — a native submit button named an option or a checkbox, an
    /// option of its dropdown drawn outside it that sends it, a submit button
    /// in a form whose file field stands past the first 200 controls: a hand-
    /// over of its own kind before any question, and nothing sent.
    @MainActor
    func testEverySenderOfAFormThatNeedsAFileIsHandedOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (site, sender) in [("site-163.test", "Send as option"), ("site-163.test", "Send as box"),
                               ("site-163.test", "Full plan"), ("site-168.test", "Send long form")] {
            let (engine, _) = Self.engine([Self.click(sender)])
            let asked = Counter()
            let record = try await run(world, from: "https://\(site)/", engine: engine,
                                       confirm: { _ in asked.add(); return .yes })
            XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape),
                           ["handover file \(site)"], "\(sender): \(record.eventLines)")
            XCTAssertEqual(asked.value, 0, "\(sender): no question")
        }
        XCTAssertFalse(world.fixtures.served.contains { ["/roles", "/auto", "/long"].contains($0.path) }, "nothing sent")
    }

    /// P2-2: the file field turns required while the Yes waits. The act sees
    /// it: no click, and the step is the user's file hand-over.
    @MainActor
    func testAFileThatTurnsRequiredWhileTheYesWaitsIsHandedOverAtTheAct() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Send note")])
        let record = try await run(world, from: "https://site-149.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage("document.getElementById('picture').required = true; ''", in: request.tab)
            return .yes
        })
        XCTAssertTrue(record.events.contains { $0.shape == "handover file site-149.test" }, "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "nothing sent")
    }

    /// P2-2: the same where the hands send a script's click, as in a browser
    /// without trusted input: the act's answer is the user's file hand-over.
    @MainActor
    func testAFileThatTurnsRequiredWhileTheYesWaitsIsHandedOverWithoutTrustedInput() async throws {
        let bridge = WebViewBridge()
        let (engine, _) = Self.engine([Self.click("Send note")])
        let run = AgentRun(plan: try plan("https://site-149.test/"), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                               _ = try? await bridge.run("document.getElementById('picture').required = true; ''",
                                                         in: request.tab)
                               return .yes
                           }))
        let record = await run.run()
        XCTAssertTrue(record.events.contains { $0.shape == "handover file site-149.test" }, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .handedOver, "\(record.eventLines)")
    }

    /// P2-3: a field that turns read-only in its own focus or press handler,
    /// as the person reaches it, is not written in: its value stays, and no
    /// input or change event fires — a native date field, and text fields
    /// read-only by attribute or by `aria-readonly`.
    @MainActor
    func testAFieldThatTurnsReadOnlyAsItIsReachedIsNotWrittenIn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        for (name, id, text) in [("Delivery date", "when", "2026-10-15"), ("Coupon", "coupon", "SPRING"),
                                 ("Nickname", "nickname", "Sam")] {
            let (tab, page) = try await world.open("https://site-164.test/")
            let action = try page.action(.type, on: name, payload: text)
            let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, "\(name): writable when aimed at")
            try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
            let typed = try await TrustedTyping.type(action, on: page, approval: nil,
                                                     read: { try? await bridge.run($0, in: tab) }, stopping: { false })
            XCTAssertEqual(typed, .notTyped, name)
            let seen = try await world.bridge.runInPage("document.getElementById('\(id)').value + '|' + events.\(id)",
                                                        in: tab)
            XCTAssertEqual(seen, "|0", "\(name): nothing written, no event")
        }
    }

    /// P2-4: an option the subgoal names, deep in a list of 300, ranks first,
    /// so Jev — asked through the real decision engine, which offers no
    /// «more» — can choose it.
    @MainActor
    func testJevCanChooseTheOptionTheSubgoalNamesDeepInALongList() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let jev = JevStub(clicking: ["Size", "Size 250"])
        let plan = try XCTUnwrap(AgentPlan(goal: "Choose size 250",
                                           subgoals: [.init(description: "Choose size 250", terms: ["size", "250"])],
                                           searches: [URL(string: "https://site-143.test/")!], columns: ["Name"],
                                           sheetTitle: "Size", rowsWanted: 1, emptyCell: "n/a"))
        let record = await run(world, plan: plan, engine: jev.engine)
        XCTAssertEqual(jev.clicked, ["Size", "Size 250"], "\(record.eventLines)")
        XCTAssertEqual(record.steps.prefix(2).map(\.outcome), [.acted, .acted], "\(record.eventLines)")
    }

    /// P2-5: an option of a list that runs past the window's edge is brought
    /// into the part of the list a person sees, by scrolling the list alone:
    /// the page does not move, so a list that closes when the page scrolls
    /// stays open, and the choice is made.
    @MainActor
    func testAnOptionOfAListRunningPastTheWindowIsReachedWithoutScrollingThePage() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-165.test/")
        try await press("Time slot", on: page, in: tab, world: world)
        let open = try await look(tab, world: world)
        let option = try XCTUnwrap(open.elements.first { $0.name == "16:00" })
        XCTAssertFalse(option.inViewport, "the premise: past the window's edge")
        try await press("16:00", on: open, in: tab, world: world)
        let seen = try await world.bridge.runInPage("document.getElementById('slot').textContent + '|' + scrollY", in: tab)
        XCTAssertEqual(seen, "16:00|0", "chosen, and the page did not move")

        // A list that cannot scroll its option into sight: nothing is clicked,
        // and the page is not moved for it — the list stays open.
        let (other, fresh) = try await world.open("https://site-165.test/")
        try await press("Room", on: fresh, in: other, world: world)
        let rooms = try await look(other, world: world)
        let last = try rooms.action(.click, on: "Room 12")
        let aim = try await world.outcome(ActionScript.aim(for: last, on: rooms), in: other)
        XCTAssertNotEqual(aim.outcome, .aim)
        let still = try await world.bridge.runInPage("String(!!document.getElementById('rooms')) + '|' + scrollY", in: other)
        XCTAssertEqual(still, "true|0", "open, and the page did not move")
    }

    /// P2-6: a switch's box the page fades and shows again, the same node, is
    /// one control whichever stands for it — its label or itself: the same
    /// role and identity, and refused once, it is not offered again.
    @MainActor
    func testASwitchIsOneControlWhetherItsLabelOrItselfIsClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, faded) = try await world.open("https://site-166.test/")
        let throughLabel = try XCTUnwrap(faded.elements.first { $0.name == "Dark mode" })
        XCTAssertEqual(throughLabel.role, "switch")
        let refused: Set<AgentAction.Effect> = [try faded.action(.click, on: "Dark mode").effect]
        _ = try await world.bridge.runInPage("fade(false); ''", in: tab)
        let shown = try await look(tab, world: world)
        let itself = try XCTUnwrap(shown.elements.first { $0.name == "Dark mode" })
        XCTAssertNotEqual(itself.key, throughLabel.key, "the premise: the input itself stands for it now")
        XCTAssertEqual(itself.role, "switch")
        XCTAssertNotNil(shown.element(matching: faded.identity(of: throughLabel)), "the same control")
        let left = Self.offered(on: shown, context: CandidateContext(subgoalTerms: [],
                                                                    refused: refused))
        XCTAssertNil(left["Dark mode"], "refused, not offered again")
    }

    // MARK: - Codex review 2 of I-08

    /// P1-1: a secret widget — one that draws dots — whose own field names
    /// its lists, behind 5,200 parts, and a second secret field in a
    /// component naming a list in the page. The parts do not cut the check
    /// short (Claude review of the round-2 fix): the page is checked whole,
    /// and no list either owns reaches the report — names, text, rows — the
    /// excerpt, or the bytes of a request to Jev; the page's other controls
    /// and words still do.
    @MainActor
    func testListsASecretWidgetOwnsBehindThousandsOfPartsAreWithheld() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let numbers = ["AB1234567", "CD7654321", "EF1122334", "IJ9900112"]
        let tab = try await world.bridge.openTab(URL(string: "https://site-183.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let excerpt = try await world.bridge.run(ObserverScript.excerptSource(), in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertFalse(page.truncated, "thousands of parts do not cut the check short")
        XCTAssertTrue(page.text.contains("Traveller"), "the page's words are read")
        XCTAssertNil(page.elements.first { $0.name == "Identity card number" }, "the premise: a secret widget")
        XCTAssertNotNil(page.elements.first { $0.name == "Continue" }, "the page's other controls are reported")
        XCTAssertFalse(page.elements.contains { $0.role == "option" }, "no option of a list it may own")
        XCTAssertEqual(Set(page.elements.filter { $0.role == "button" }.map(\.name)), ["Continue", "Edit travellers"],
                       "no button of a list it may own; the card's own button is")
        for number in numbers {
            XCTAssertFalse(json.contains(number), "report: \(number)")
            XCTAssertFalse(excerpt.contains(number), "excerpt: \(number)")
        }
        let jev = JevStub(clicking: [])
        let plan = try XCTUnwrap(AgentPlan(goal: "Look around the page",
                                           subgoals: [.init(description: "Look around the page", terms: ["page"])],
                                           searches: [URL(string: "https://site-183.test/")!], columns: ["Name"],
                                           sheetTitle: "Page", rowsWanted: 1, emptyCell: "n/a"))
        let record = await run(world, plan: plan, engine: jev.engine)
        XCTAssertFalse(jev.sent.isEmpty, "the premise: Jev was asked: \(record.eventLines)")
        for body in jev.sent {
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("Continue"), "the premise: the page's controls are in the request")
            for number in numbers { XCTAssertFalse(text.contains(number), "Jev request: \(number)") }
        }
    }

    /// P1-2: two dropdowns no one can tell apart share a list. Whose an
    /// option is cannot be proved, so none is offered: the list moved to the
    /// other dropdown while a Yes waited would get the click. Nothing is
    /// clicked, and nothing is sent.
    @MainActor
    func testAnOptionOfADropdownThatHasATwinIsNeverClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-184.test/")
        XCTAssertEqual(page.elements.filter { $0.name == "Status" }.count, 2, "the premise: twin dropdowns")
        XCTAssertNil(Self.offered(on: page)["Archived"], "an option no one can tell whose it is is not offered")
        // The options after the ones left out keep their dropdown.
        XCTAssertEqual(page.elements.map(\.index), Array(page.elements.indices), "each element at its own index")
        let priority = try XCTUnwrap(page.elements.first { $0.name == "Priority" })
        XCTAssertEqual(page.elements.filter { $0.listOf == priority.index }.map(\.name), ["High", "Low"])
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Archived")])
        let record = try await run(world, from: "https://site-184.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage("retarget(); ''", in: request.tab)
            return .yes
        })
        XCTAssertFalse(record.steps.contains { $0.outcome == .confirmed || $0.outcome == .acted && $0.operation == "click" },
                       "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path.hasPrefix("/records") }, "nothing sent")
    }

    /// P1-3: the checkbox's label holds another form's submit button, drawn
    /// away from it, and a label for that button covers the checkbox's. A
    /// click there lands on the button: the aim refuses it, and the other form
    /// is never sent.
    @MainActor
    func testALabelForAControlInsideTheTargetIsNotClickedThroughIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-185.test/")
        let agree = try XCTUnwrap(page.elements.first { $0.role == "checkbox" })
        let action = AgentAction(operation: .click, target: agree, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        if aim.outcome == .aim, let x = aim.x, let y = aim.y {
            try await world.bridge.click(x: x, y: y, in: tab)
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(aim.outcome, .covered)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/other" }, "the other form is never sent")
    }

    /// P1-1: an ARIA list no one in the walked trees names, before more
    /// controls than the walk reads: a field it never reached, which the page
    /// marks secret by its structure, owns it, so no option of it is
    /// reported, nor its words. A tab's panel is no field's list: its
    /// controls are. A list a field no census sees names — one the page marks
    /// secret by no structure — is shown (owner decision of 2026-10-03).
    @MainActor
    func testAListOfOptionsIsWithheldWhenTheWalkStopsBeforeItsOwner() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-187.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertTrue(page.truncated, "the premise: the walk was cut short")
        XCTAssertNotNil(page.elements.first { $0.name == "Continue" }, "the page's other controls are reported")
        XCTAssertEqual(page.elements.filter { $0.role == "option" }.map(\.name), ["WX9898989"],
                       "no option of a list a secret field names")
        XCTAssertFalse(json.contains("GH5566778"))
        XCTAssertFalse(json.contains("KL3344556"), "a plain list a field names from a tree the walk never reached")
        XCTAssertFalse(json.contains("OP1212121"), "a list that list names in turn")
        XCTAssertFalse(json.contains("ST6767676"), "a list an editable region with no role names")
        XCTAssertTrue(json.contains("WX9898989"), "an ARIA list a field no census sees names")
        XCTAssertNotNil(page.elements.first { $0.name == "Edit saved" }, "the card's own button is reported")
        XCTAssertNotNil(page.elements.first { $0.name == "Book now" }, "a tab's panel stays the page's")
    }

    /// Codex review 3 of I-08, P1-1: a page too big even to count its trees.
    /// Who names what cannot be known, so nothing a name could point to — an
    /// element with an id, or inside one — is reported; the rest is.
    @MainActor
    func testWhatANameCouldPointToIsWithheldWhenThePageIsTooBigToCount() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-188.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertTrue(page.truncated, "the premise: the walk was cut short")
        XCTAssertNotNil(page.elements.first { $0.name == "Continue" }, "the page's other controls are reported")
        XCTAssertFalse(json.contains("MN7788990"))
    }

    /// Codex review 3 of I-08, P1-2: two dropdowns claim the shared list — both
    /// open, or neither. Whose its options are cannot be proved: none is
    /// reported, clicked or sent with.
    @MainActor
    func testAnOptionOfAListTwoDropdownsClaimAlikeIsNeverClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for mode in ["both", "none"] {
            let address = "https://site-167.test/?open=\(mode)"
            let (_, page) = try await world.open(address)
            XCTAssertNotNil(page.elements.first { $0.name == "Status of record A" }, "\(mode): the premise")
            XCTAssertFalse(page.elements.contains { $0.role == "option" }, "\(mode): no option of no proved dropdown")
            let (engine, _) = Self.engine([Self.click("Archived")])
            let record = try await run(world, from: address, engine: engine, confirm: { _ in .yes })
            XCTAssertFalse(record.steps.contains { $0.operation == "click" && ($0.outcome == .acted || $0.outcome == .confirmed) },
                           "\(mode): \(record.eventLines)")
        }
        XCTAssertFalse(world.fixtures.served.contains { $0.path.hasPrefix("/records") }, "nothing sent")
    }

    /// Claude review of the round-2 fix: a dropdown past the report's limit
    /// claims the shared list. The list moves to it while the Yes for the
    /// first one's option waits: whose the option is cannot be bound, so
    /// nothing is clicked, and nothing is sent.
    @MainActor
    func testAnOptionWhoseListMovesToADropdownPastTheReportIsNotClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-220.test/")
        XCTAssertNil(page.elements.first { $0.name == "Status of record B" }, "the premise: past the report's limit")
        XCTAssertNotNil(page.elements.first { $0.name == "Archived" }, "the premise: the option is the first one's")
        let bridge = world.bridge
        let (engine, _) = Self.engine([Self.click("Archived")])
        let record = try await run(world, from: "https://site-220.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage("retarget(); ''", in: request.tab)
            return .yes
        })
        XCTAssertTrue(record.events.contains { $0.shape == "answer yes" }, "the premise: asked, and Yes: \(record.eventLines)")
        XCTAssertFalse(record.steps.contains { $0.outcome == .confirmed }, "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path.hasPrefix("/records") }, "nothing sent")
        // The list the second one's from the start: its owner is not in the
        // report, so its options are not reported.
        let (_, second) = try await world.open("https://site-220.test/?open=b")
        XCTAssertFalse(second.elements.contains { $0.role == "option" }, "no option of an owner the report does not hold")
    }

    /// Claude review of the round-2 fix: the count of what fields own has a
    /// ceiling. A secret widget — one that draws dots — with more parts than
    /// it reads leaves who owns what unknown: the page is not checked whole,
    /// and the list it names is withheld all the same.
    @MainActor
    func testWhatFieldsOwnIsUnknownPastItsCountAndItsListsAreWithheld() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let tab = try await world.bridge.openTab(URL(string: "https://site-224.test/")!)
        try await world.waitUntilLoaded(tab)
        let json = try await world.bridge.run(ObserverScript.source, in: tab)
        let page = try ObservedPage.decode(json)
        XCTAssertTrue(page.truncated, "past the count: not checked whole")
        XCTAssertNotNil(page.elements.first { $0.name == "Continue" }, "the page's other controls are reported")
        XCTAssertFalse(json.contains("UV2323232"))
    }

    /// Claude review of the round-2 fix: the target stands inside a label for
    /// another form's submit button. A click on it runs that label too: no
    /// point of it is safe, and the other form is never sent.
    @MainActor
    func testAControlInsideALabelForAnotherControlIsNotClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-221.test/")
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: "Archive"), on: page), in: tab)
        if aim.outcome == .aim, let x = aim.x, let y = aim.y {
            try await world.bridge.click(x: x, y: y, in: tab)
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(aim.outcome, .covered)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/other" }, "the other form is never sent")
    }

    /// Claude review of the round-2 fix: a box the report holds as a control
    /// of its own, inside the target, its label covering the target. That box
    /// is another control: the click does not select it.
    @MainActor
    func testABoxOfItsOwnInsideTheTargetIsAnotherControl() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-222.test/")
        XCTAssertNotNil(page.elements.first { $0.name == "Select" }, "the premise: the box is reported")
        let row = try XCTUnwrap(page.elements.first { $0.role == "button" && $0.name.contains("quarterly") })
        let action = AgentAction(operation: .click, target: row, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        if aim.outcome == .aim, let x = aim.x, let y = aim.y {
            try await world.bridge.click(x: x, y: y, in: tab)
            try await Task.sleep(for: .milliseconds(300))
        }
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertFalse(log.contains("selected"), "the box is not selected by the row's click: \(log)")
    }

    /// Claude review of the round-2 fix: a styled checkbox whose own input
    /// and label stand in its shadow root. Its label is part of it: the click
    /// goes through, and ticks it.
    @MainActor
    func testAStyledCheckboxWithItsLabelInItsShadowRootIsClicked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-223.test/")
        XCTAssertEqual(page.elements.filter { $0.name == "Notify me" }.map(\.role), ["checkbox"], "the premise: one control")
        try await press("Notify me", on: page, in: tab, world: world)
        try await Task.sleep(for: .milliseconds(300))
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "notify;")
    }

    /// Claude review of the round-2 fix: while the Yes waits, the form comes to
    /// need a file and to show its total. The file is named first, after the
    /// Yes as before the question and at the act; nothing is sent.
    @MainActor
    func testAFileAndATotalThatComeWhileTheYesWaitsAreTheFileHandOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let change = "document.getElementById('picture').required = true; const p = document.createElement('p'); "
            + "p.textContent = 'Total $10.00'; document.getElementById('note').appendChild(p); ''"
        let (engine, _) = Self.engine([Self.click("Send note")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-149.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage(change, in: request.tab)
            return .yes
        })
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape), ["handover file site-149.test"],
                       "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "nothing sent")
    }

    /// Codex review 3 of I-08, P1-3: the control the covering label names is
    /// one of the page's own making, inside the checkbox's label. A label's
    /// control is part of the target only when it is a box, a radio or a
    /// field: this one is another control, and the other form is never sent.
    @MainActor
    func testALabelForACustomControlInsideTheTargetIsNotClickedThroughIt() async throws {
        for address in ["https://site-189.test/", "https://site-189.test/?bare"] {
            try await labelForAnotherControlIsNotClicked(address)
        }
    }

    /// Codex review 3 of I-08, P1-3: the other form's submit inside the
    /// checkbox's label is a hidden input the report cannot see. An input
    /// that sends is another control all the same.
    @MainActor
    func testALabelForAHiddenSubmitInsideTheTargetIsNotClickedThroughIt() async throws {
        try await labelForAnotherControlIsNotClicked("https://site-185.test/?hidden")
    }

    @MainActor
    private func labelForAnotherControlIsNotClicked(_ address: String) async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open(address)
        let agree = try XCTUnwrap(page.elements.first { $0.role == "checkbox" })
        let action = AgentAction(operation: .click, target: agree, destination: nil, payload: nil, isPlannedSearch: false)
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        if aim.outcome == .aim, let x = aim.x, let y = aim.y {
            try await world.bridge.click(x: x, y: y, in: tab)
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(aim.outcome, .covered, address)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/other" }, "\(address): the other form is never sent")
    }

    /// Codex review 3 of I-08, P2-1: a refusal reads the dropdown's form
    /// address as the app reads every address: a route written with escapes
    /// (`#%2F…`, `#%21%2F…`) is a place of its own, so another route is
    /// another action.
    @MainActor
    func testRoutesWrittenWithEscapesInADropdownsFormAreRefusedApart() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-167.test/")
        for (first, second) in [("%2Fall", "%2Farchived"), ("%21%2Fall", "%21%2Farchived"), ("/all", "/archived")] {
            _ = try await world.bridge.runInPage("document.getElementById('records').action = '/records#\(first)'; ''", in: tab)
            let before = try await look(tab, world: world)
            let refused = CandidateContext(subgoalTerms: [],
                                           refused: [try before.action(.click, on: "Archived").effect])
            XCTAssertNil(Self.offered(on: before, context: refused)["Archived"], "\(first): refused here")
            _ = try await world.bridge.runInPage("document.getElementById('records').action = '/records#\(second)'; ''", in: tab)
            let after = try await look(tab, world: world)
            XCTAssertEqual(Self.offered(on: after, context: refused)["Archived"], [.click], "\(second): another place")
        }
    }

    /// P2-1: a No for an option holds when only the heading above its
    /// dropdown changes, or its form's address gains an anchor; another
    /// dropdown's option is still its own.
    @MainActor
    func testARefusedOptionStaysRefusedWhenItsDropdownsHeadingChanges() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, before) = try await world.open("https://site-167.test/")
        let archived = try before.action(.click, on: "Archived")
        let refused = CandidateContext(subgoalTerms: [], refused: [archived.effect])
        _ = try await world.bridge.runInPage("document.querySelector('h1').textContent = 'All records'; "
            + "document.getElementById('records').action = '/records#all'; ''", in: tab)
        let renamed = try await look(tab, world: world)
        XCTAssertNotEqual(renamed.elements.first { $0.name == "Archived" }?.heading, "Records", "the premise")
        XCTAssertEqual(renamed.elements.first { $0.name == "Status of record A" }?.formAction,
                       "https://site-167.test/records#all", "the premise")
        XCTAssertNil(Self.offered(on: renamed, context: refused)["Archived"], "refused, not offered again")
        // A client-side route in its form's address is another place to send.
        _ = try await world.bridge.runInPage("document.getElementById('records').action = '/records#/all'; ''", in: tab)
        let routed = try await look(tab, world: world)
        XCTAssertEqual(Self.offered(on: routed, context: refused)["Archived"], [.click], "another destination")
        _ = try await world.bridge.runInPage("document.getElementById('records').action = '/records'; ''", in: tab)
        _ = try await world.bridge.runInPage("retarget(); ''", in: tab)
        let other = try await look(tab, world: world)
        XCTAssertEqual(Self.offered(on: other, context: refused)["Archived"], [.click], "the other record's is its own")
    }

    /// P2-2: the file field turns required as the aim scrolls the form into
    /// view. The step is the user's file hand-over at once: no other question
    /// to Jev, and nothing sent.
    @MainActor
    func testAFileThatTurnsRequiredAsTheAimScrollsIsHandedOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, requests) = Self.engine([Self.click("Send note")])
        let record = try await run(world, from: "https://site-186.test/", engine: engine, confirm: { _ in .yes })
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape), ["handover file site-186.test"],
                       "\(record.eventLines)")
        XCTAssertEqual(requests.all.count, 1, "no other question: \(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "nothing sent")
    }

    /// P2-2: as the aim scrolls, the form both needs a file and grows past its
    /// scan, so it may now send a secret too. At the act the file comes
    /// first, as the policy orders them.
    @MainActor
    func testAFormThatGrowsAsTheAimScrollsIsAFileHandOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (engine, _) = Self.engine([Self.click("Send note")])
        let record = try await run(world, from: "https://site-186.test/?grow", engine: engine, confirm: { _ in .yes })
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape), ["handover file site-186.test"],
                       "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "nothing sent")
    }

    /// P2-2: the form grows past the controls its scan reads while the Yes
    /// waits: it may now need a file and send a secret. The file comes first,
    /// at the act as before the question.
    @MainActor
    func testAFormThatGrowsPastItsScanWhileTheYesWaitsIsAFileHandOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let bridge = world.bridge
        let grow = "const f = document.getElementById('note'); for (let i = 0; i < 210; i++) { "
            + "const h = document.createElement('input'); h.type = 'hidden'; h.name = 'x' + i; f.prepend(h); } ''"
        let (engine, _) = Self.engine([Self.click("Send note")])
        let record = try await run(world, from: "https://site-149.test/", engine: engine, confirm: { request in
            _ = try? await bridge.runInPage(grow, in: request.tab)
            return .yes
        })
        XCTAssertEqual(record.events.filter { $0.shape.hasPrefix("handover") }.map(\.shape), ["handover file site-149.test"],
                       "\(record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/note" }, "nothing sent")
    }

    // MARK: - 5. Identity

    /// Every new kind of control keeps the fingerprint rules: drawn anew, each
    /// is the same control, and one the user refused is not offered again.
    @MainActor
    func testEveryNewKindOfControlIsKnownAgainWhenThePageDrawsItAnew() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let kinds = ["https://site-146.test/": ["I agree to the terms", "Show me offers", "Yearly billing"],
                     "https://site-147.test/": ["Later month", "Add to list"],
                     "https://site-148.test/": ["Check-in", "Check-out"],
                     "https://site-142.test/": ["Country"]]
        for (address, names) in kinds {
            let (tab, before) = try await world.open(address)
            _ = try await world.bridge.runInPage("const m = document.querySelector('main'); m.outerHTML = m.outerHTML; ''",
                                                 in: tab)
            let after = try await look(tab, world: world)
            var refused = Set<AgentAction.Effect>()
            for name in names {
                let element = try XCTUnwrap(before.elements.first { $0.name == name }, name)
                let again = after.element(matching: before.identity(of: element))
                XCTAssertNotNil(again, name)
                XCTAssertNotEqual(again?.key, element.key, "\(name): a new node, the same control")
                refused.insert(try before.action(.click, on: name).effect)
            }
            let left = Self.offered(on: after, context: CandidateContext(subgoalTerms: [],
                                                                         refused: refused))
            for name in names { XCTAssertNil(left[name], "\(name): refused, not offered again") }
        }
    }
}

/// An engine that presses Stop when it is asked its second question — a
/// made-up list is open then — and answers it as `inner` does.
final class StopsOnItsSecondQuestion: DecisionEngine, @unchecked Sendable {
    let name = "scripted"
    let worstCaseUSD = 0.001
    private let inner: ScriptedEngine
    private let count = Counter()
    @MainActor var stop: () -> Void = {}

    init(_ inner: ScriptedEngine) { self.inner = inner }

    var asked: Int { count.value }

    func choose(_ request: ChooseRequest) async throws -> ChooseAnswer {
        count.add()
        if count.value == 2 { await MainActor.run { stop() } }
        return try await inner.choose(request)
    }

    func risk(of action: AgentAction, on page: PageSummary, goal: String) async throws -> RiskAnswer {
        try await inner.risk(of: action, on: page, goal: goal)
    }
}

/// The agent's hands in Chrome, counting the person's clicks that went out.
@MainActor
final class CountsTheClicks: WrapsChromeBridge {
    let inner: ChromeBridge
    private(set) var clicks = 0

    init(_ inner: ChromeBridge) { self.inner = inner }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        clicks += 1
        try await inner.click(x: x, y: y, in: tab)
    }
}

/// A Jev behind the real decision engine: it answers every question, clicking
/// in turn the targets whose labels `clicking` names — DONE when the next is
/// not offered — and keeps the bytes of every request it was sent.
final class JevStub: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var wanted: [String]
    private var chosen: [String] = []

    init(clicking wanted: [String]) { self.wanted = wanted }

    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    var clicked: [String] { lock.lock(); defer { lock.unlock() }; return chosen }

    var engine: JevDecisionEngine {
        JevDecisionEngine(jev: JevEngine(licenseKey: { "TEST-LICENSE" }, send: { [self] request in try answer(request) },
                                         log: { _ in }),
                          limit: .seconds(10))
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(json["questions"] as? [String: [String: Any]])
        lock.lock()
        bodies.append(body)
        let next = wanted.first
        let targets = questions["click_target"]?["criteria"] as? [String: Any] ?? [:]
        let hit = next.flatMap { label in
            targets.first { (($0.value as? [String: Any])?["element"] as? String)?.hasSuffix("] " + label) == true }?.key
        }
        if hit != nil, let label = next {
            wanted.removeFirst()
            chosen.append(label)
        }
        lock.unlock()
        var answers: [String: Any] = [:]
        for (name, question) in questions {
            if question["type"] as? String == "noul" {
                answers[name] = ["type": "noul", "noul": name.hasPrefix("goal") || name.hasPrefix("stuck") ? 0.1 : 0.02]
                continue
            }
            let options = (question["criteria"] as? [String: Any] ?? [:]).keys.sorted()
            let pick = name == "operation" ? (hit == nil ? "DONE" : "CLICK") : (name == "click_target" ? hit : nil)
                ?? options[0]
            var probabilities = Dictionary(uniqueKeysWithValues: options.map { ($0, 0.1 / Double(max(1, options.count - 1))) })
            probabilities[pick] = options.count == 1 ? 1.0 : 0.9
            answers[name] = ["type": "choice", "choice": pick, "confidence": 0.9, "probabilities": probabilities]
        }
        let reply = try JSONSerialization.data(withJSONObject: [
            "model": "jev-1.13.0", "usage": ["input_tokens": 100, "output_tokens": 5], "answers": answers,
        ])
        return (reply, HTTPURLResponse(url: JevEngine.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
