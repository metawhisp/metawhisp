import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 98; owner default 3.1) — a cookie window: the least
/// consent it offers — reject all, then necessary only, then close — is
/// clicked by code, with no Yes and no model asked; a window that offers none
/// of them, or still shows after its own was clicked, is the user's part and
/// waits for them. "Accept" is never the agent's to give. A dialog that is not
/// about cookies is left to Jev, as any page.
final class AgentRunCookieTests: XCTestCase {

    private func plan(_ site: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Read today's menu", subgoals: [.init(description: "Menu", terms: ["menu"])],
                                searches: [URL(string: site)!], columns: ["Dish"], sheetTitle: "Menu",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// What the run asked: the steps Jev was asked about — from any thread —
    /// the questions to the user, the waits.
    @MainActor
    private final class Asked {
        let jev = Steps()
        var steps: [ChooseRequest] { jev.all }
        var questions: [ConfirmationRequest] = []
        var waits: [ErrandHandover] = []
    }

    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ChooseRequest] = []
        var all: [ChooseRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        func add(_ request: ChooseRequest) { lock.lock(); requests.append(request); lock.unlock() }
    }

    /// Jev, done at once on whatever page it is asked about.
    @MainActor
    private func doneAtOnce(_ asked: Asked) -> ScriptedEngine {
        let jev = asked.jev
        return ScriptedEngine(choice: { request in
            jev.add(request)
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
    }

    @MainActor
    private func errand(on site: String, engine: ScriptedEngine, bridge: KeepsItsTab, asked: Asked) throws -> AgentRun {
        var parts = AgentRun.Collaborators(bridge: bridge, engine: engine, writer: FakeWriter(), sheet: FixtureSheet(),
                                           confirm: { request in
            asked.questions.append(request)
            return .no
        })
        parts.waitForUser = { handover, _, _ in
            asked.waits.append(handover)
            return false
        }
        return AgentRun(plan: try plan(site), errandID: UUID(), collaborators: parts)
    }

    /// What the page logged of the clicks it got, read once the run is over.
    @MainActor
    private func clicks(on bridge: KeepsItsTab) async throws -> String {
        let tab = try XCTUnwrap(bridge.tab)
        return try await bridge.inner.run("document.getElementById('log').textContent", in: tab)
    }

    /// The fixture browser, whose tab stays open when the run closes it: the
    /// test reads what the page logged.
    @MainActor
    private final class KeepsItsTab: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var tab: BrowserTab?

        func openTab(_ url: URL) async throws -> BrowserTab {
            let opened = try await inner.openTab(url)
            tab = opened
            return opened
        }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws {}
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    @MainActor
    func testACookieWindowIsRejectedWithoutAYesAndWithNoModelAsked() async throws {
        let asked = Asked()
        let engine = doneAtOnce(asked)
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-413.test/?offer=reject", engine: engine, bridge: bridge, asked: asked)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "reject;")
        XCTAssertEqual(asked.questions.count, 0, "no Yes")
        XCTAssertEqual(engine.riskQuestions.count, 0, "no risk question")
        XCTAssertEqual(asked.steps.count, 1, "Jev was asked once, about the page with the window gone")
        XCTAssertFalse(asked.steps.first?.candidates.contains { $0.action.target?.name == "Reject all" } ?? true)
        XCTAssertEqual(run.record.steps.first?.operation, "click")
        XCTAssertEqual(run.record.steps.first?.outcome, .acted)
    }

    /// With no reject, necessary only; with neither, close.
    @MainActor
    func testWithoutARejectNecessaryOnlyThenCloseIsClicked() async throws {
        for (offer, logged) in [("necessary,close", "necessary;"), ("close", "close;")] {
            let asked = Asked()
            let bridge = KeepsItsTab()
            let run = try errand(on: "https://site-413.test/?offer=\(offer)", engine: doneAtOnce(asked), bridge: bridge,
                                 asked: asked)
            _ = await run.run(report: { _ in })
            let log = try await clicks(on: bridge)
            XCTAssertEqual(log, logged, offer)
            XCTAssertEqual(asked.questions.count, 0, offer)
        }
    }

    /// A window that offers nothing but its accept waits for the user: the
    /// agent never accepts.
    @MainActor
    func testACookieWindowThatOffersOnlyAcceptWaitsForTheUser() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-413.test/?offer=none", engine: doneAtOnce(asked), bridge: bridge,
                             asked: asked)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.waits.map(\.kind), [.cookies], "\(run.record.eventLines)")
        XCTAssertEqual(asked.waits.first?.host, "site-413.test")
        XCTAssertEqual(outcome.ending, .needsUser)
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "", "never accepted")
        XCTAssertEqual(asked.steps.count, 0)
    }

    /// A window still shown after its own reject was clicked is not clicked
    /// again by code: it is left to Jev, as any control — never a loop.
    @MainActor
    func testACookieWindowThatStaysAfterItsRejectIsLeftToJev() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-413.test/?offer=reject&sticky=1", engine: doneAtOnce(asked),
                             bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "reject;", "clicked once")
        XCTAssertEqual(asked.waits, [])
        XCTAssertEqual(asked.steps.count, 1, "then Jev was asked")
        XCTAssertEqual(asked.steps.first?.candidates.contains { $0.action.target?.name == "Reject all" }, true)
    }

    /// A dialog not about cookies — its "Decline" a reject word — is left to
    /// Jev, as any page is.
    @MainActor
    func testADialogThatIsNotAboutCookiesIsLeftToJev() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let words = "Join%20the%20team%20workspace%3F"
        let run = try errand(on: "https://site-413.test/?offer=decline&words=\(words)", engine: doneAtOnce(asked),
                             bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "")
        XCTAssertEqual(asked.waits, [])
        XCTAssertEqual(asked.steps.first?.candidates.contains { $0.action.target?.name == "Decline" }, true)
    }

    /// The window is found by the dialog's own words and buttons: what the
    /// observer reports of it.
    func testACookieWindowIsReadFromItsDialogsOwnWords() {
        func element(_ index: Int, _ name: String, dialog: String?) -> ObservedElement {
            var element = ObservedElement(index: index, role: "button", name: name, text: name, href: nil, inputType: nil,
                                          heading: nil, region: dialog == nil ? .main : .dialog, inViewport: true,
                                          context: nil, formAction: nil, formMethod: nil, formSubmitLabel: nil,
                                          options: nil, checked: nil)
            element.dialogText = dialog
            return element
        }
        let words = "We use cookies to improve the site. Reject all Accept all"
        let page = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                elements: [element(0, "Sign in", dialog: nil), element(1, "Reject all", dialog: words),
                                           element(2, "Accept all", dialog: words)])
        XCTAssertEqual(CookieBanner.window(on: page)?.least?.name, "Reject all")
        let acceptOnly = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                      elements: [element(0, "Accept all", dialog: "We use cookies. Accept all")])
        XCTAssertNotNil(CookieBanner.window(on: acceptOnly), "a cookie window")
        XCTAssertNil(CookieBanner.window(on: acceptOnly)?.least, "with nothing the agent may click")
        let invitation = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                      elements: [element(0, "Decline", dialog: "Join the team? Decline Accept"),
                                                 element(1, "Accept", dialog: "Join the team? Decline Accept")])
        XCTAssertNil(CookieBanner.window(on: invitation))
        let outside = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none,
                                   elements: [element(0, "Reject all", dialog: nil)])
        XCTAssertNil(CookieBanner.window(on: outside), "a button outside any dialog is no window")
        // Whether the window blocks the page is the eyes' word: a dialog does; a bar fixed to the viewport does
        // not; a report made by hand says nothing, and the window is taken for blocking (2026-10-19).
        XCTAssertEqual(CookieBanner.window(on: acceptOnly)?.blocksPage, true)
        var bar = element(0, "Got it", dialog: "Cookie notice Got it")
        bar.dialogBlocks = false
        let notice = ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none, elements: [bar])
        XCTAssertEqual(CookieBanner.window(on: notice)?.blocksPage, false)
        XCTAssertNil(CookieBanner.window(on: notice)?.least)
    }

    // MARK: - The way to the least consent (blind task b08, 2026-10-21)

    private static let firstLayer = "By clicking Accept all cookies, you agree to the storing of cookies on your device."
    private static let settingsLayer = "Privacy Preference Center When you visit any website, it may store information "
        + "on your browser, mostly in the form of cookies."

    /// A control of a cookie window drawn by hand, that window's words `dialog`.
    private func control(_ index: Int, _ role: String, _ name: String, in dialog: String, checked: Bool? = nil,
                         disabled: Bool? = nil, expanded: Bool? = nil) -> ObservedElement {
        let presses = ["button", "link"].contains(role)
        var made = ObservedElement(index: index, role: role, name: name, text: presses ? name : "", href: nil,
                                   inputType: nil, heading: nil, region: .dialog, inViewport: true, context: nil,
                                   formAction: nil, formMethod: nil, formSubmitLabel: nil, options: nil,
                                   checked: checked)
        made.dialogText = dialog
        made.disabled = disabled
        made.expanded = expanded
        return made
    }

    private func page(_ elements: [ObservedElement]) -> ObservedPage {
        ObservedPage(url: "https://a.test/", title: "A", truncated: false, flags: .none, elements: elements)
    }

    /// A consent platform's settings open over its first layer, drawn by hand: the first layer's settings and
    /// accept; the settings' close, "Allow All", each category's header — a button that only shows its description —
    /// with its switch, the necessary one always active, with no switch; and the save, unless `save` is false.
    private func settingsOpen(on: Set<String> = [], save: Bool = true) -> ObservedPage {
        var elements = [control(0, "button", "Cookies settings", in: Self.firstLayer),
                        control(1, "button", "Accept all cookies", in: Self.firstLayer),
                        control(2, "button", "Close preference center", in: Self.settingsLayer),
                        control(3, "button", "Allow All", in: Self.settingsLayer)]
        for name in ["Targeting Cookies", "Functional Cookies"] {
            elements.append(control(elements.count, "button", name, in: Self.settingsLayer, expanded: false))
            elements.append(control(elements.count, "switch", name, in: Self.settingsLayer, checked: on.contains(name)))
        }
        elements.append(control(elements.count, "button", "Strictly Necessary Cookies Always Active", in: Self.settingsLayer,
                                expanded: false))
        if save { elements.append(control(elements.count, "button", "Confirm My Choices", in: Self.settingsLayer)) }
        return page(elements)
    }

    /// A first layer that offers only its settings and its accept: the settings are the way to the least consent,
    /// pressed with no Yes; the accept never is. With "Reject all" there, reject all comes first and the settings
    /// are no way.
    func testAFirstLayerThatOffersOnlyItsSettingsOffersTheWayToTheLeastConsent() throws {
        let window = try XCTUnwrap(CookieBanner.window(on: page([
            control(0, "button", "Cookies settings", in: Self.firstLayer),
            control(1, "button", "Accept all cookies", in: Self.firstLayer)])))
        XCTAssertEqual(window.least?.name, "Cookies settings")
        XCTAssertEqual(window.way, .settings)
        XCTAssertEqual(window.free.map(\.name), ["Cookies settings"])
        XCTAssertTrue(window.blocksPage)
        let rejecting = try XCTUnwrap(CookieBanner.window(on: page([
            control(0, "button", "Reject all", in: Self.firstLayer),
            control(1, "button", "Cookies settings", in: Self.firstLayer),
            control(2, "button", "Accept all cookies", in: Self.firstLayer)])))
        XCTAssertEqual(rejecting.free.map(\.name), ["Reject all"])
        XCTAssertEqual(rejecting.way, .consent)
    }

    /// The settings open: both layers are one window, and its save is the least consent while every switch that is
    /// on is a necessary one — by its words, or because no one can change it. Not the first layer's settings, spent
    /// once its settings show; not "Allow All"; not a category's header, whatever its words.
    func testASettingsLayerWithOnlyNecessarySwitchesOnOffersItsSave() throws {
        let open = settingsOpen()
        let window = try XCTUnwrap(CookieBanner.window(on: open))
        XCTAssertEqual(window.least?.name, "Confirm My Choices")
        XCTAssertEqual(window.way, .consent)
        XCTAssertEqual(window.free.map(\.name), ["Confirm My Choices"])
        XCTAssertTrue(window.holds(try XCTUnwrap(open.elements.first { $0.name == "Accept all cookies" })))
        XCTAssertTrue(window.holds(try XCTUnwrap(open.elements.first { $0.name == "Allow All" })))
        var locked = settingsOpen()
        locked.elements.append(control(locked.elements.count, "switch", "Session", in: Self.settingsLayer, checked: true,
                                       disabled: true))
        locked.elements.append(control(locked.elements.count, "switch", "Strictly necessary", in: Self.settingsLayer,
                                       checked: true))
        XCTAssertEqual(CookieBanner.window(on: locked)?.least?.name, "Confirm My Choices")
    }

    /// A non-essential switch on: turning it off is free — a consent taken away — and so is turning off any other
    /// one on; the save is not, until they are off. A switch whose state no one knows may be on: the save waits for
    /// it, and it is never turned.
    func testANonEssentialSwitchOnIsTurnedOffBeforeTheSave() throws {
        let window = try XCTUnwrap(CookieBanner.window(on: settingsOpen(on: ["Functional Cookies", "Targeting Cookies"])))
        XCTAssertEqual(window.least?.role, "switch")
        XCTAssertEqual(window.least?.name, "Targeting Cookies")
        XCTAssertEqual(window.way, .turnOff)
        XCTAssertEqual(window.free.map(\.role), ["switch", "switch"])
        XCTAssertEqual(window.free.map(\.name), ["Targeting Cookies", "Functional Cookies"])
        var unknown = settingsOpen()
        unknown.elements.append(control(unknown.elements.count, "switch", "Advertising", in: Self.settingsLayer))
        let waiting = try XCTUnwrap(CookieBanner.window(on: unknown))
        XCTAssertNil(waiting.least)
        XCTAssertEqual(waiting.free, [])
    }

    /// The window is the cookie dialogs' own controls: a field of its settings is one of them; a control of another
    /// dialog on the page is not, whatever the window offers.
    func testTheWindowHoldsItsOwnControlsOnly() throws {
        var open = settingsOpen()
        let invitation = "Join the newsletter? We send one letter a week."
        open.elements.append(control(open.elements.count, "button", "Subscribe", in: invitation))
        open.elements.append(control(open.elements.count, "textbox", "Cookie list search", in: Self.settingsLayer))
        let window = try XCTUnwrap(CookieBanner.window(on: open))
        XCTAssertFalse(window.holds(try XCTUnwrap(open.elements.first { $0.name == "Subscribe" })))
        XCTAssertTrue(window.holds(try XCTUnwrap(open.elements.first { $0.name == "Cookie list search" })))
        XCTAssertFalse(window.frees(try XCTUnwrap(open.elements.first { $0.name == "Cookie list search" })))
    }

    /// Settings with no save offer nothing to press: no switch is turned, the first layer's settings are spent, and
    /// the window, blocking the page, is the user's part.
    func testASettingsLayerWithNoSaveOffersNothing() throws {
        let window = try XCTUnwrap(CookieBanner.window(on: settingsOpen(on: ["Targeting Cookies"], save: false)))
        XCTAssertNil(window.least)
        XCTAssertEqual(window.free, [])
        XCTAssertTrue(window.blocksPage)
    }

    /// The window as a consent platform draws it on a prize site (blind task b08, 2026-10-21): the code opens its
    /// settings and saves them as they come — the non-essential switches off — with no Yes and no model asked about
    /// the window; Jev is asked once, about the page with the window gone. The accept is never pressed.
    @MainActor
    func testAWindowThatOffersOnlyItsSettingsIsSavedNecessaryOnly() async throws {
        let asked = Asked()
        let engine = doneAtOnce(asked)
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-520.test/", engine: engine, bridge: bridge, asked: asked)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "settings;save:targeting=off,functional=off,performance=off;", "\(run.record.eventLines)")
        XCTAssertEqual(asked.questions.count, 0, "no Yes")
        XCTAssertEqual(engine.riskQuestions.count, 0, "no risk question")
        XCTAssertEqual(asked.waits, [])
        XCTAssertEqual(asked.steps.count, 1, "Jev was asked once, about the page with the window gone")
    }

    /// A non-essential switch on by default is turned off first, then the choices are saved; a box no one can
    /// change, named by no necessary word, is left on — in settings drawn over the first layer, and in settings that
    /// take its place.
    @MainActor
    func testANonEssentialSwitchOnIsTurnedOffThenTheChoicesAreSaved() async throws {
        for (site, logged) in [
            ("https://site-520.test/?on=targeting", "settings;off:targeting;save:targeting=off,functional=off,performance=off;"),
            ("https://site-521.test/", "customize;off:marketing;save:session=on,analytics=off,marketing=off;"),
        ] {
            let asked = Asked()
            let engine = doneAtOnce(asked)
            let bridge = KeepsItsTab()
            let run = try errand(on: site, engine: engine, bridge: bridge, asked: asked)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .done, "\(site): \(run.record.eventLines)")
            let log = try await clicks(on: bridge)
            XCTAssertEqual(log, logged, site)
            XCTAssertEqual(asked.questions.count, 0, site)
            XCTAssertEqual(engine.riskQuestions.count, 0, site)
        }
    }

    /// Settings with no save: once they are open the window is the user's part, and nothing else is pressed — no
    /// switch turned, no accept.
    @MainActor
    func testSettingsWithNoSaveAreTheUsersPart() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-520.test/?nosave=1&on=targeting", engine: doneAtOnce(asked), bridge: bridge,
                             asked: asked)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.waits.map(\.kind), [.cookies], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "settings;")
        XCTAssertEqual(asked.steps.count, 0)
    }

    /// "Reject all" on the first layer is chosen, as before: the settings are no way then.
    @MainActor
    func testARejectOnTheFirstLayerIsChosenOverItsSettings() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-520.test/?reject=1", engine: doneAtOnce(asked), bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "reject;")
        XCTAssertEqual(asked.questions.count, 0)
    }

    /// Settings that open nothing are pressed once on a page: the window still there after is left to Jev, as any
    /// control — never a loop.
    @MainActor
    func testSettingsThatOpenNothingArePressedOnce() async throws {
        let asked = Asked()
        let bridge = KeepsItsTab()
        let run = try errand(on: "https://site-520.test/?dead=1", engine: doneAtOnce(asked), bridge: bridge, asked: asked)
        _ = await run.run(report: { _ in })
        let log = try await clicks(on: bridge)
        XCTAssertEqual(log, "settings;", "pressed once")
        XCTAssertEqual(asked.waits, [])
        XCTAssertEqual(asked.steps.count, 1, "then Jev was asked")
    }

    // MARK: - The brain's errand on that window (2026-10-21)

    /// The index the brain's state gives the control of `role` named `name`: by its name, or its words under it.
    private static func index(of name: String, role: String, in state: String) -> Int {
        let lines = state.components(separatedBy: "\n")
        for (place, line) in lines.enumerated() where line.contains("]<\(role) ") {
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close,
                  let number = Int(line[line.index(after: open)..<close]) else { continue }
            let words = place + 1 < lines.count ? lines[place + 1].trimmingCharacters(in: .whitespaces) : ""
            if line.contains("name=\(name)") || words == name { return number }
        }
        return -1
    }

    /// What the brain read at its `step`-th step, from 0: nothing when it took fewer.
    @MainActor
    private static func state(_ step: Int, of brain: AgentRunBrainModeTests.StateBrain) -> String {
        step < brain.states.count ? brain.states[step] : ""
    }

    /// A brain step that clicks the control of `role` named `name`.
    private static func click(_ name: String, role: String = "button") -> (String) -> String {
        { state in #"[{"click": {"index": \#(index(of: name, role: role, in: state))}}]"# }
    }

    /// The brain's errand on `site`: Jev calls every act irreversible but those named `reversible`, so any act of the
    /// window asked about is asked of the user, who says no.
    @MainActor
    private func brainErrand(_ brain: AgentRunBrainModeTests.StateBrain, on site: String,
                             browser: AgentRunBrainModeTests.Browser, questions: AgentRunBrainModeTests.Questions,
                             reversible: Set<String> = []) throws -> (run: AgentRun, engine: ScriptedEngine) {
        let engine = ScriptedEngine(choice: { _ in ChooseAnswer(candidateID: "", confidence: 0, goalMet: nil, usage: nil) },
                                    irreversible: { reversible.contains($0.target?.name ?? "") ? 0.05 : 0.9 })
        var parts = AgentRun.Collaborators(bridge: browser, engine: engine, writer: nil, sheet: nil, confirm: { request in
            questions.asked.append(request)
            return .no
        }, log: { _ in })
        parts.brain = brain
        let plan = try XCTUnwrap(AgentPlan(goal: "Read the award summary",
                                           requirements: [.init(id: "r1", text: "Read", kind: .action)],
                                           answerExpected: false))
        let run = AgentRun(goal: "Read the award summary at \(site)", planner: FixedPlanner(plan: plan), errandID: UUID(),
                           collaborators: parts, startPage: URL(string: site)!)
        return (run, engine)
    }

    /// The brain goes for the accept first (blind task b08, 2026-10-21: "Accept cookies and navigate", and the
    /// errand ended as the user's part): refused, never pressed, it hears where the least consent is; the settings
    /// and the save go with no Yes and no Jev; "Allow All" in the settings is refused too — never handed over as a
    /// grant — and the errand goes on to its task.
    @MainActor
    func testTheBrainsErrandOpensTheSettingsSavesNecessaryOnlyAndGoesOn() async throws {
        let browser = AgentRunBrainModeTests.Browser()
        let questions = AgentRunBrainModeTests.Questions()
        let brain = AgentRunBrainModeTests.StateBrain([Self.click("Accept all cookies"), Self.click("Cookies settings"),
                                                       Self.click("Allow All"), Self.click("Confirm My Choices"),
                                                       Self.click("Show the winners")])
        let (run, engine) = try brainErrand(brain, on: "https://site-520.test/", browser: browser, questions: questions,
                                            reversible: ["Show the winners"])
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "no Yes: \(run.record.eventLines)")
        XCTAssertEqual(engine.riskQuestions.map { $0.action.target?.name }, ["Show the winners"], "no Jev for the window")
        let log = try await browser.read("document.getElementById('log').textContent")
        XCTAssertEqual(log, "settings;save:targeting=off,functional=off,performance=off;", "\(run.record.eventLines)")
        let accepted = try await browser.read("String(window.accepted)")
        XCTAssertEqual(accepted, "0", "never accepted")
        let shown = try await browser.read("String(window.shown || 0)")
        XCTAssertEqual(shown, "1", "the errand went on to its task: \(run.record.eventLines)")
        XCTAssertFalse(run.record.events.contains { if case .handover = $0 { return true } else { return false } },
                       "\(run.record.eventLines)")
        XCTAssertEqual(brain.states.count, 6, "\(run.record.eventLines)")
        XCTAssertTrue(Self.state(1, of: brain).contains("it is in the window's settings: ["), Self.state(1, of: brain))
        XCTAssertTrue(Self.state(3, of: brain).contains("only the least consent may be chosen: ["), Self.state(3, of: brain))
    }

    /// A non-essential switch on: the brain's save is refused until it is off — the brain hears which to turn off —
    /// and turning it off goes with no Yes and no Jev.
    @MainActor
    func testTheBrainTurnsANonEssentialSwitchOffBeforeTheSave() async throws {
        let browser = AgentRunBrainModeTests.Browser()
        let questions = AgentRunBrainModeTests.Questions()
        let brain = AgentRunBrainModeTests.StateBrain([Self.click("Cookies settings"), Self.click("Confirm My Choices"),
                                                       Self.click("Targeting Cookies", role: "switch"),
                                                       Self.click("Confirm My Choices")])
        let (run, engine) = try brainErrand(brain, on: "https://site-520.test/?on=targeting", browser: browser,
                                            questions: questions)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "no Yes: \(run.record.eventLines)")
        XCTAssertEqual(engine.riskQuestions.count, 0, "no Jev for the window")
        let log = try await browser.read("document.getElementById('log').textContent")
        XCTAssertEqual(log, "settings;off:targeting;save:targeting=off,functional=off,performance=off;",
                       "\(run.record.eventLines)")
        let accepted = try await browser.read("String(window.accepted)")
        XCTAssertEqual(accepted, "0")
        XCTAssertTrue(Self.state(2, of: brain).contains("first turn off ["), Self.state(2, of: brain))
    }

    /// Settings that open nothing, pressed again on the page, are decided as any control: the second press is asked
    /// about, and a No leaves it unpressed.
    @MainActor
    func testTheBrainsSecondPressOfSettingsThatOpenNothingIsAskedAbout() async throws {
        let browser = AgentRunBrainModeTests.Browser()
        let questions = AgentRunBrainModeTests.Questions()
        let brain = AgentRunBrainModeTests.StateBrain([Self.click("Cookies settings"), Self.click("Cookies settings")])
        let (run, _) = try brainErrand(brain, on: "https://site-520.test/?dead=1", browser: browser, questions: questions)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.map { $0.action.target?.name }, ["Cookies settings"], "\(run.record.eventLines)")
        let clicks = try await browser.read("String(window.settingsClicks)")
        XCTAssertEqual(clicks, "1", "\(run.record.eventLines)")
    }

    /// Settings with no save: what the brain goes for there — "Allow All" — ends the errand as the user's part, a
    /// cookie window's, never a grant; nothing is pressed.
    @MainActor
    func testTheBrainMeetsSettingsWithNoSaveAsTheUsersPart() async throws {
        let browser = AgentRunBrainModeTests.Browser()
        let questions = AgentRunBrainModeTests.Questions()
        let brain = AgentRunBrainModeTests.StateBrain([Self.click("Cookies settings"), Self.click("Allow All")])
        let (run, _) = try brainErrand(brain, on: "https://site-520.test/?nosave=1", browser: browser, questions: questions)
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.cookies, host: "site-520.test")), "\(run.record.eventLines)")
        XCTAssertFalse(run.record.events.contains(.handover(.grant, host: "site-520.test")), "\(run.record.eventLines)")
        XCTAssertEqual(run.record.ending, .needsUser)
        XCTAssertEqual(questions.asked.count, 0)
        let log = try await browser.read("document.getElementById('log').textContent")
        XCTAssertEqual(log, "settings;")
    }

    /// "Reject all" on the first layer comes first: the brain's settings are refused, and its reject goes with no Yes.
    @MainActor
    func testTheBrainIsToldARejectOnTheFirstLayerComesFirst() async throws {
        let browser = AgentRunBrainModeTests.Browser()
        let questions = AgentRunBrainModeTests.Questions()
        let brain = AgentRunBrainModeTests.StateBrain([Self.click("Cookies settings"), Self.click("Reject all")])
        let (run, _) = try brainErrand(brain, on: "https://site-520.test/?reject=1", browser: browser, questions: questions)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 0, "\(run.record.eventLines)")
        let log = try await browser.read("document.getElementById('log').textContent")
        XCTAssertEqual(log, "reject;", "\(run.record.eventLines)")
        XCTAssertTrue(Self.state(1, of: brain).contains("only the least consent may be chosen: ["), Self.state(1, of: brain))
    }
}
