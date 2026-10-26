import XCTest
@testable import MetaWhisp

/// ITER-076 stage 3 (№ 10, 71, 115) — the user's part waits instead of ending
/// the errand: a sign-in, a CAPTCHA widget (by its frame's address alone, no
/// model asked), a grant or a file the form needs. The run waits up to ten
/// minutes — never past the expiry, none of it counted as work — with its tab
/// open; Continue looks again from scratch; its window, or Stop, ends it. A
/// payment still ends the errand at once. A check that may clear itself is
/// waited out first, the page looked at every half second.
final class AgentRunPauseTests: XCTestCase {

    private func plan(_ site: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Find the order's status", subgoals: [.init(description: "Status", terms: ["order"])],
                                searches: [URL(string: site)!], columns: ["Status"], sheetTitle: "Orders",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// The waits a run asked for, with what each said.
    @MainActor
    private final class Waits {
        var asked: [(handover: ErrandHandover, tab: BrowserTab, window: Duration)] = []
        var kinds: [ErrandHandover.Kind] { asked.map(\.handover.kind) }
    }

    @MainActor
    private func run(_ engine: any DecisionEngine, on site: String, bridge: any BrowserBridge, waits: Waits,
                     pauseWindow: Duration = .seconds(600), checkWait: Duration = .milliseconds(1_200),
                     limits: AgentBudget.Limits = .standard,
                     answer: @escaping @MainActor @Sendable (ErrandHandover, BrowserTab) async -> Bool)
        throws -> AgentRun {
        var parts = AgentRun.Collaborators(bridge: bridge, engine: engine, writer: FakeWriter(), sheet: FixtureSheet(),
                                           confirm: { _ in .no })
        parts.waitForUser = { [waits] handover, tab, window in
            waits.asked.append((handover, tab, window))
            return await answer(handover, tab)
        }
        let plan = try plan(site)
        return AgentRun(goal: plan.goal, planner: FixedPlanner(plan: plan), errandID: UUID(), collaborators: parts,
                        limits: limits, pauseWindow: pauseWindow, checkWait: checkWait)
    }

    /// Picks the first candidate `wanted` finds, else DONE; counts every ask.
    private final class Picks: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ChooseRequest] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var all: [ChooseRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        func add(_ request: ChooseRequest) { lock.lock(); requests.append(request); lock.unlock() }
    }

    /// `irreversible`: Jev's C for every step — an act it calls reversible is
    /// taken without a question.
    private func engine(_ picks: Picks, _ wanted: @escaping @Sendable (Candidate) -> Bool,
                        irreversible: Double = 0.9) -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            picks.add(request)
            return ScriptedEngine.pick(request.candidates.first(where: wanted)
                                           ?? request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in irreversible })
    }

    private static func named(_ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.target?.name == name }
    }

    /// Waits until Stop or its own time: a user who never says Continue.
    private static let neverAnswers: @MainActor @Sendable (ErrandHandover, BrowserTab) async -> Bool = { _, _ in
        try? await Task.sleep(for: .seconds(60))
        return false
    }

    // MARK: - The pause and its window

    /// Paired with the next test: before its window ends, a pause never ends
    /// the errand — the tab stays open, nothing else happens.
    @MainActor
    func testASignInPauseDoesNotEndTheErrandBeforeItsWindow() async throws {
        let waits = Waits()
        let picks = Picks()
        let bridge = WebViewBridge()
        let run = try run(engine(picks, Self.named("Sign in")), on: "https://site-5.test/", bridge: bridge, waits: waits,
                          pauseWindow: .seconds(2), answer: Self.neverAnswers)
        let began = ContinuousClock.now
        let running = Task { await run.run(report: { _ in }) }
        while waits.asked.isEmpty, ContinuousClock.now - began < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(waits.kinds, [.signIn], "a sign-in waits")
        let asked = picks.count
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertNil(run.record.ending, "the errand did not end before its window")
        XCTAssertEqual(picks.count, asked, "and nothing else was asked meanwhile")
        let outcome = await running.value
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .seconds(2))
    }

    /// Paired with the one above: with no Continue, the pause ends the errand
    /// anyway once its window — ten minutes in the app — has run out, as the
    /// user's part, its line today's.
    @MainActor
    func testASignInPauseEndsAnywayAfter10Minutes() async throws {
        XCTAssertEqual(AgentRun.pauseWindow, .seconds(600), "ten minutes")
        let waits = Waits()
        let run = try run(engine(Picks(), Self.named("Sign in")), on: "https://site-5.test/", bridge: WebViewBridge(),
                          waits: waits, pauseWindow: .milliseconds(800), answer: Self.neverAnswers)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(waits.asked.map(\.window), [.milliseconds(800)], "the window is the run's")
        XCTAssertEqual(waits.asked.first?.handover, ErrandHandover(kind: .signIn, host: "site-5.test"))
        XCTAssertFalse(run.record.eventLines.contains("continued"))
        XCTAssertTrue(run.record.events.map(\.shape).contains("handover signIn site-5.test"))
    }

    /// Continue: the step that met the wall ends without acting, and the run
    /// looks at the page again from scratch — here the user signed in, the
    /// wall is gone, and the errand goes on to its end.
    @MainActor
    func testContinueLooksAgainFromScratchAndTheErrandGoesOn() async throws {
        let waits = Waits()
        let picks = Picks()
        let bridge = WebViewBridge()
        let run = try run(engine(picks, Self.named("Sign in")), on: "https://site-5.test/", bridge: bridge, waits: waits,
                          answer: { _, tab in
            // The user signs in in the agent's tab: the form goes.
            _ = try? await bridge.run("document.getElementById('login').remove(); "
                                      + "document.querySelector('h1').textContent = 'Welcome back'; ''", in: tab)
            return true
        })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        XCTAssertEqual(waits.kinds, [.signIn])
        XCTAssertEqual(picks.count, 2, "asked again after Continue")
        XCTAssertEqual(picks.all.dropFirst().first?.candidates.contains { $0.action.target?.name == "Sign in" }, false,
                       "a fresh look")
        let shapes = run.record.events.map(\.shape)
        XCTAssertEqual(shapes.filter { $0 == "continued" }.count, 1)
        let handedOver = try XCTUnwrap(shapes.firstIndex(of: "handover signIn site-5.test"))
        XCTAssertLessThan(handedOver, try XCTUnwrap(shapes.firstIndex(of: "continued")))
        XCTAssertFalse(run.record.steps.contains { $0.outcome == .acted && $0.operation == "click" },
                       "the step that met the wall never acted")
    }

    /// Continue on a page that still shows the wall waits again, a new window.
    @MainActor
    func testContinueOnAPageThatStillShowsTheWallWaitsAgain() async throws {
        let waits = Waits()
        let run = try run(engine(Picks(), Self.named("Sign in")), on: "https://site-5.test/", bridge: WebViewBridge(),
                          waits: waits, answer: { [waits] _, _ in waits.asked.count < 2 })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(waits.kinds, [.signIn, .signIn])
    }

    /// A payment — a page that asks card details — still ends the errand at once (L4): no wait.
    @MainActor
    func testAPaymentStillEndsTheErrandAtOnce() async throws {
        let waits = Waits()
        var reports: [ErrandProgress] = []
        let run = try run(engine(Picks(), Self.named("Pay")), on: "https://site-294.test/", bridge: WebViewBridge(),
                          waits: waits, answer: { _, _ in true })
        let outcome = await run.run(report: { reports.append($0) })
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(waits.asked.count, 0, "a payment is never waited for")
        XCTAssertEqual(reports.last, .needsUser(ErrandHandover(kind: .payment, host: "site-294.test")))
    }

    /// Stop during a pause ends the errand within Stop's limit; nothing more is
    /// asked or done.
    @MainActor
    func testStopDuringAPauseEndsTheErrandAndNothingMoreIsDone() async throws {
        let waits = Waits()
        let picks = Picks()
        let run = try run(engine(picks, Self.named("Sign in")), on: "https://site-5.test/", bridge: WebViewBridge(),
                          waits: waits, answer: Self.neverAnswers)
        let running = Task { await run.run(report: { _ in }) }
        let began = ContinuousClock.now
        while waits.asked.isEmpty, ContinuousClock.now - began < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
        let asked = picks.count
        let stepsBefore = run.record.steps.count
        let pressed = ContinuousClock.now
        run.stop()
        let outcome = await running.value
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertLessThan(ContinuousClock.now - pressed, AgentRun.stopLimit)
        XCTAssertEqual(picks.count, asked, "nothing asked after Stop")
        XCTAssertEqual(run.record.steps.count, stepsBefore, "nothing done after Stop")
        XCTAssertFalse(run.record.eventLines.contains("continued"))
    }

    /// The window never runs past the errand's absolute expiry: one that
    /// starts close to it gets what is left, and the expiry ends the errand
    /// as its ceiling.
    @MainActor
    func testAPauseNeverWaitsPastTheErrandsExpiry() async throws {
        let waits = Waits()
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(3))
        let run = try run(engine(Picks(), Self.named("Sign in")), on: "https://site-5.test/", bridge: WebViewBridge(),
                          waits: waits, limits: limits, answer: Self.neverAnswers)
        let outcome = await run.run(report: { _ in })
        let window = try XCTUnwrap(waits.asked.first?.window)
        XCTAssertLessThan(window, .seconds(3))
        XCTAssertGreaterThan(window, .zero)
        XCTAssertEqual(outcome.ending, .ceiling)
    }

    /// The wait is the user's time, not the errand's work: a pause longer than
    /// the work's whole budget leaves the errand able to go on.
    @MainActor
    func testAPauseSpendsNoneOfTheErrandsWorkTime() async throws {
        let waits = Waits()
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 5, spendMicros: 500_000, expiry: .seconds(60))
        let bridge = WebViewBridge()
        let run = try run(engine(Picks(), Self.named("Sign in")), on: "https://site-5.test/", bridge: bridge,
                          waits: waits, limits: limits, answer: { _, tab in
            try? await Task.sleep(for: .milliseconds(5_500))
            _ = try? await bridge.run("document.getElementById('login').remove(); ''", in: tab)
            return true
        })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
    }

    /// During the pause the tab is the user's: no look, no Jev, no model.
    @MainActor
    func testNothingIsReadOrAskedDuringAPause() async throws {
        let waits = Waits()
        let picks = Picks()
        let bridge = CountsTheRuns()
        let during = Counts()
        let run = try run(engine(picks, Self.named("Sign in")), on: "https://site-5.test/", bridge: bridge, waits: waits,
                          answer: { _, tab in
            let (runs, asks) = (bridge.runs, picks.count)
            try? await Task.sleep(for: .milliseconds(600))
            during.runs = bridge.runs - runs
            during.asks = picks.count - asks
            _ = try? await bridge.inner.run("document.getElementById('login').remove(); ''", in: tab)
            return true
        })
        _ = await run.run(report: { _ in })
        XCTAssertEqual(waits.asked.count, 1)
        XCTAssertEqual(during.runs, 0, "no script ran in the page while the user had it")
        XCTAssertEqual(during.asks, 0, "Jev was not asked")
    }

    /// A grant a page's own dialog named waits too, and is not handed over
    /// again after Continue: the dialog was answered Cancel, and is gone.
    @MainActor
    func testAGrantAPagesDialogNamedWaitsOnceAndTheErrandGoesOn() async throws {
        let waits = Waits()
        let run = try run(engine(Picks(), { _ in false }), on: "https://site-26.test/", bridge: NamesAGrantOnce(),
                          waits: waits, answer: { _, _ in true })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(waits.kinds, [.grant], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .done)
    }

    // MARK: - A CAPTCHA widget, by its frame's address (№ 71, 115)

    /// A control in a CAPTCHA provider's widget is never acted on: the check
    /// is waited out first, the page looked at every half second, and when it
    /// does not clear, the errand waits for the user — no model asked.
    @MainActor
    func testACaptchaWidgetIsNeverClickedAndWaitsForTheUserOnceTheCheckDidNotClear() async throws {
        let waits = Waits()
        let bridge = try await HasAWidget.open()
        let began = ContinuousClock.now
        let run = try run(engine(Picks(), { $0.action.target?.frame != nil }, irreversible: 0.05),
                          on: "https://site-411.test/", bridge: bridge, waits: waits, checkWait: .milliseconds(1_200),
                          answer: { _, _ in false })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(waits.asked.map(\.handover), [ErrandHandover(kind: .captcha, host: "site-411.test")],
                       "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(bridge.actsInTheWidget, 0, "nothing but a look ever ran in the widget")
        XCTAssertGreaterThanOrEqual(bridge.looks, 3, "the page looked at again while the check was waited out")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_200))
    }

    /// A check that clears itself while it is waited out is no one's part:
    /// the run looks again and goes on.
    @MainActor
    func testACheckThatClearsItselfIsWaitedOutAndNeverWaitsForTheUser() async throws {
        let waits = Waits()
        let bridge = try await HasAWidget.open(clearsAfterLooks: 3)
        let run = try run(engine(Picks(), { $0.action.target?.frame != nil }, irreversible: 0.05),
                          on: "https://site-411.test/", bridge: bridge, waits: waits, checkWait: .seconds(5),
                          answer: { _, _ in false })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(waits.asked.count, 0, "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(bridge.actsInTheWidget, 0)
    }

    /// The provider's widget addresses, by their own documentation; any other
    /// address is no CAPTCHA by structure.
    func testTheCaptchaProvidersWidgetsAreKnownByTheirAddress() {
        for address in ["https://www.google.com/recaptcha/api2/anchor?k=abc&size=normal",
                        "https://www.recaptcha.net/recaptcha/api2/bframe?k=abc",
                        "https://newassets.hcaptcha.com/captcha/v1/abc/static/hcaptcha.html#frame=checkbox",
                        "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/turnstile/if/ov2/av0/abc"] {
            XCTAssertTrue(SafetyGuard.isCaptchaWidget(address), address)
        }
        for address in ["https://www.google.com/search?q=recaptcha", "https://site-411.test/recaptcha/",
                        "https://hcaptcha.com.evil.test/captcha", "https://cloudflare.com/challenges/",
                        "https://www.google.com.evil.test/recaptcha/api2/anchor"] {
            XCTAssertFalse(SafetyGuard.isCaptchaWidget(address), address)
        }
    }

    // MARK: - Helpers

    @MainActor
    private final class Counts {
        var runs = 0
        var asks = 0
    }

    /// The fixture browser, counting every script it runs.
    @MainActor
    private final class CountsTheRuns: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var runs = 0

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            runs += 1
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            runs += 1
            return try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser whose page's own dialog named a grant, once, as
    /// the step looked (the bridge answered it Cancel: I-09).
    @MainActor
    private final class NamesAGrantOnce: BrowserBridge {
        let inner = WebViewBridge()
        private var named = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
        func events(in tab: BrowserTab) -> [BrowserEvent] {
            guard !named else { return [] }
            named = true
            return [.dialog(.confirm, accepted: false), .dialogNamed(.grant)]
        }
    }

    /// The fixture browser whose page holds a CAPTCHA provider's widget in a
    /// frame of the provider's own: the frame's look is the widget page's
    /// own report at the provider's address. Anything else run in the frame
    /// is counted, and fails. With `clearsAfterLooks`, the widget is gone
    /// after that many looks at the page — the check cleared itself.
    @MainActor
    private final class HasAWidget: BrowserBridge {
        static let widgetAddress = "https://www.google.com/recaptcha/api2/anchor?k=site-key&size=normal"
        let inner = WebViewBridge()
        private var widget: BrowserTab?
        private let clearsAfterLooks: Int?
        private(set) var looks = 0
        private(set) var actsInTheWidget = 0

        private init(clearsAfterLooks: Int?) { self.clearsAfterLooks = clearsAfterLooks }

        static func open(clearsAfterLooks: Int? = nil) async throws -> HasAWidget {
            let bridge = HasAWidget(clearsAfterLooks: clearsAfterLooks)
            let widget = try await bridge.inner.openTab(URL(string: "https://site-412.test/")!)
            try await bridge.inner.waitUntilLoaded(widget)
            bridge.widget = widget
            return bridge
        }

        private var cleared: Bool { clearsAfterLooks.map { looks >= $0 } ?? false }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }

        func frames(of tab: BrowserTab) async throws -> FrameListing {
            cleared ? FrameListing() : FrameListing(frames: [BrowserFrame(tab: tab.inFrame("widget"),
                                                                         identity: "/https://www.google.com")])
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard tab.frame != nil else {
                if javascript == ObserverScript.source { looks += 1 }
                return try await inner.run(javascript, in: tab)
            }
            guard javascript == ObserverScript.source, let widget else {
                actsInTheWidget += 1
                throw BrowserBridgeError.scriptFailed(code: -1)
            }
            let report = try await inner.run(javascript, in: widget)
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
            object["address"] = Self.widgetAddress
            object["url"] = Self.widgetAddress
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }
}
