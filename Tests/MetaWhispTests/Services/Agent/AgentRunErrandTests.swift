import XCTest
@testable import MetaWhisp

/// ITER-076 I-05 — the run the errand service drives: `AgentRun` as an
/// `ErrandRunner`. It reports its progress, keeps what it collected in its
/// record as it goes, ends with the real reason — the day's limit, no Pro, the
/// service down — never "stuck", takes a failed look for a miss, asks the
/// user about an action once, reads a start page that landed elsewhere, and
/// is made by the factory the app will use.
final class AgentRunErrandTests: XCTestCase {

    private func plan(search: String, rows: Int = 3) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Add three competitor sites to a sheet",
                                subgoals: [.init(description: "Find a competitor's site", terms: ["voice", "notes"])],
                                searches: [URL(string: search)!], columns: ["Name", "URL", "What they do"],
                                sheetTitle: "Competitors", rowsWanted: rows, emptyCell: "n/a"))
    }

    @MainActor
    private func run(_ engine: any DecisionEngine, on search: String, bridge: any BrowserBridge,
                     sheet: (any SheetDestination)? = nil,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .no }, lines: LogLines? = nil, waits: Waits? = nil) throws -> AgentRun {
        var parts = AgentRun.Collaborators(bridge: bridge, engine: engine, writer: FakeWriter(),
                                           sheet: sheet ?? FixtureSheet(), confirm: confirm)
        if let lines { parts.log = lines.sink }
        if let waits {
            parts.waitForUser = { handover, _, _ in
                waits.asked.append(handover)
                return false
            }
        }
        return AgentRun(plan: try plan(search: search), errandID: UUID(), collaborators: parts)
    }

    /// The user's parts a run waited for (ITER-076 stage 3), none said Continue.
    @MainActor
    private final class Waits {
        var asked: [ErrandHandover] = []
    }

    /// An engine that is done at once.
    private static let doneAtOnce = ScriptedEngine(choice: { request in
        ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
    })

    @MainActor
    private final class Reports {
        var all: [ErrandProgress] = []
    }

    // MARK: - 1. The run the service drives

    /// It says it is working when it starts and after each new row, and ends
    /// with an outcome: its ending, every row's source, the rows, the Sheet.
    @MainActor
    func testTheRunReportsItsProgressAndEndsWithItsOutcome() async throws {
        let bridge = WebViewBridge()
        let reports = Reports()
        let run = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes", bridge: bridge)
        let outcome = await run.run(report: { reports.all.append($0) })

        XCTAssertEqual(reports.all, (0...3).map { .working(title: "Competitors", done: $0, wanted: 3) })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.sources.map(\.host), ["site-1.test", "site-2.test", "site-3.test"])
        XCTAssertEqual(outcome.rows, 3)
        XCTAssertNotNil(outcome.sheet)
        XCTAssertEqual(outcome.sheet, run.record.sheet)
        XCTAssertNil(outcome.answer, "the answer is I-17's")
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(run.record.ending, .done)
        XCTAssertEqual(bridge.openTabCount, 0)
    }

    /// A step that is the user's part says what it is and where: a sign-in,
    /// a grant or a payment, with the page's host — a sign-in and a grant as
    /// what the errand waits for, a payment as what ends it (ITER-076 stage
    /// 3).
    @MainActor
    func testTheUsersPartIsReportedWithItsKindAndHost() async throws {
        let cases: [(site: String, name: String, kind: ErrandHandover.Kind)] = [
            ("https://site-5.test/", "Sign in", .signIn),
            ("https://site-29.test/", "Allow access", .grant),
            ("https://site-294.test/", "Pay", .payment),
        ]
        for (site, name, kind) in cases {
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == name })
            }, irreversible: { _ in 0.9 })
            let reports = Reports()
            let waits = Waits()
            let outcome = await (try run(engine, on: site, bridge: WebViewBridge(), waits: waits))
                .run(report: { reports.all.append($0) })
            let handover = ErrandHandover(kind: kind, host: URL(string: site)!.host!)
            XCTAssertEqual(outcome.ending, .needsUser, name)
            if kind == .payment {
                XCTAssertEqual(reports.all.last, .needsUser(handover), name)
                XCTAssertEqual(waits.asked, [], name)
            } else {
                XCTAssertEqual(waits.asked, [handover], name)
                XCTAssertFalse(reports.all.contains { if case .needsUser = $0 { true } else { false } }, name)
            }
        }
    }

    /// A consent page the start address lands on is a grant, waited for.
    @MainActor
    func testAConsentPageIsReportedAsAGrant() async throws {
        let waits = Waits()
        let consent = "https://site-54.test/consent?client_id=app-42&redirect_uri=https%3A%2F%2Fapp-42.test%2Fcb"
        let outcome = await (try run(Self.doneAtOnce, on: consent, bridge: WebViewBridge(), waits: waits))
            .run(report: { _ in })
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(waits.asked, [ErrandHandover(kind: .grant, host: "site-54.test")])
    }

    /// A login form that appears right before the act is a sign-in; a total
    /// that loads right before a commit is no wall (owner decision of
    /// 2026-10-19: a payment is a page that asks card details).
    @MainActor
    func testAWallAtTheActIsReportedForWhatItIs() async throws {
        let signIn = Reports()
        let show = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let password = AddsAtTheAct(
            "document.querySelector('main').insertAdjacentHTML('beforeend', '<input type=password aria-label=Code>'); ''")
        let waits = Waits()
        let blocked = await (try run(show, on: "https://site-26.test/", bridge: password, waits: waits))
            .run(report: { signIn.all.append($0) })
        XCTAssertTrue(password.added)
        XCTAssertEqual(blocked.ending, .needsUser)
        XCTAssertEqual(waits.asked, [ErrandHandover(kind: .signIn, host: "site-26.test")], "a sign-in is waited for")

        let payment = Reports()
        let picked = Counter()
        let order = ScriptedEngine(choice: { request in
            if picked.value < 1, let target = request.candidates.first(where: {
                $0.action.target?.name == "Bestellung abschlie\u{00DF}en"
            }) {
                picked.add()
                return ScriptedEngine.pick(target)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 })
        let total = AddsAtTheAct("document.getElementById('summe').textContent = 'Gesamtsumme: 49,90 \u{20AC}'; ''")
        let ordered = await (try run(order, on: "https://site-116.test/", bridge: total, confirm: { _ in .yes }))
            .run(report: { payment.all.append($0) })
        XCTAssertTrue(total.added)
        XCTAssertFalse(payment.all.contains { if case .needsUser = $0 { true } else { false } }, "\(ordered.ending)")
        XCTAssertTrue(total.inner.navigatedURLs.contains { $0.path == "/paid" }, "the order went with the Yes")
    }

    /// A menu link of a whole-page POST form — a web forms site — opens by
    /// its address (owner default 3.3, ITER-076 stage 3): no Yes, and the form
    /// is never sent.
    @MainActor
    func testAMenuLinkOfAWholePagePostFormOpensByItsAddressWithoutAYes() async throws {
        let menu = ScriptedEngine(choice: { request in
            if request.page.url.hasSuffix("/products") {
                return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Products" })
        })
        let questions = Reports()
        let bridge = WebViewBridge()
        _ = await (try run(menu, on: "https://site-416.test/", bridge: bridge, confirm: { _ in
            questions.all.append(.working(title: "asked", done: 0, wanted: nil))
            return .no
        })).run(report: { _ in })
        XCTAssertEqual(questions.all.count, 0, "no Yes")
        XCTAssertEqual(bridge.navigatedURLs, [URL(string: "https://site-416.test/products")!])
    }

    // MARK: - 2. What was collected is kept live

    /// Each row is in the record the moment it is added: whoever reads the
    /// record when a row is reported finds that row there.
    @MainActor
    func testEachRowIsInTheRecordAsSoonAsItIsAdded() async throws {
        let run = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes", bridge: WebViewBridge())
        var seen: [Int] = []
        _ = await run.run(report: { progress in
            if case .working(_, let done, _) = progress { seen.append(run.record.rows.count - done) }
        })
        XCTAssertEqual(seen, [0, 0, 0, 0], "the record held every row reported")
    }

    // MARK: - 3. Honest endings

    /// A plan on a page with one reversible step, so Jev is asked at once.
    private static let anyPage = "https://site-26.test/"

    /// No Pro, the day's limit, the service down and the server's own
    /// timeout each end the errand as what they are — never as stuck, and
    /// never after more than one wait.
    @MainActor
    func testEachRefusalOfTheServiceEndsTheErrandAsWhatItIs() async throws {
        let cases: [(status: Int, retryAfter: String?, ending: ErrandRecord.Ending, asked: Int, retry: TimeInterval?)] = [
            (401, nil, .noPro, 1, nil),
            (429, "3600", .dailyLimit, 1, 3600),
            (503, "0", .unavailable, 2, 0),
            (504, nil, .unavailable, 2, nil),
        ]
        for (status, retryAfter, ending, asked, retry) in cases {
            let jev = RecordedJev { _, _ in .status(status, retryAfter: retryAfter) }
            let bridge = WebViewBridge()
            let run = try run(jev.engine, on: Self.anyPage, bridge: bridge)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, ending, "\(status)")
            XCTAssertEqual(jev.requests.count, asked, "\(status): asked again only after a service that was down")
            XCTAssertFalse(run.record.steps.contains { $0.outcome == .reconsidered }, "\(status): not a miss")
            XCTAssertEqual(outcome.failure, ending == .unavailable ? .engineUnavailable : nil, "\(status)")
            XCTAssertEqual(run.record.ending, ending, "\(status)")
            XCTAssertEqual(bridge.openTabCount, 0, "\(status)")
            if let retry {
                let when = try XCTUnwrap(outcome.retryAt, "\(status): when the service said to ask again")
                XCTAssertEqual(when.timeIntervalSinceNow, retry, accuracy: 30, "\(status)")
            } else {
                XCTAssertNil(outcome.retryAt, "\(status)")
            }
        }
    }

    /// ITER-076 stage 9d, № 27 — the owner's switch on Jev's route ends the
    /// errand stopped at once: one request, no wait and no second try, no
    /// failure and no time to ask again — so nothing to report — its tab
    /// closed; and the service hears it, once.
    @MainActor
    func testTheOwnersSwitchEndsTheErrandStoppedAtOnce() async throws {
        let jev = RecordedJev { _, _ in .switchedOff }
        let bridge = WebViewBridge()
        let heard = Counter()
        var parts = AgentRun.Collaborators(bridge: bridge, engine: jev.engine, writer: FakeWriter(), sheet: FixtureSheet(),
                                           confirm: { _ in .no })
        parts.switchedOff = { heard.add() }
        let run = AgentRun(plan: try plan(search: Self.anyPage), errandID: UUID(), collaborators: parts)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(jev.requests.count, 1, "no wait, no second try")
        XCTAssertNil(outcome.failure)
        XCTAssertNil(outcome.retryAt)
        XCTAssertFalse(run.record.events.contains { if case .serviceWait = $0 { true } else { false } })
        XCTAssertEqual(run.record.ending, .stopped)
        XCTAssertFalse(AgentService.reportedEndings.contains(outcome.ending), "not reported")
        XCTAssertEqual(heard.value, 1, "the service hears it")
        XCTAssertEqual(bridge.openTabCount, 0, "its tab closed")
    }

    /// The service down once is waited for — as long as it asks — and asked
    /// again; its answer then counts, and the errand goes on.
    @MainActor
    func testAServiceDownOnceIsWaitedForAndAskedAgain() async throws {
        let jev = RecordedJev { _, number in
            number == 0 ? .status(503, retryAfter: "1") : .answers(operation: "DONE")
        }
        let run = try run(jev.engine, on: Self.anyPage, bridge: WebViewBridge())
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(jev.requests.count, 2)
        XCTAssertGreaterThanOrEqual(clock.now - started, .seconds(1), "it waited as long as the service asked")
        XCTAssertNil(outcome.retryAt, "the service came back: nothing to wait for")
        XCTAssertNil(outcome.failure)
    }

    /// A wait the errand has no time for is not begun: the errand ends as
    /// unavailable at once.
    @MainActor
    func testAWaitTheErrandHasNoTimeForEndsItAtOnce() async throws {
        let jev = RecordedJev { _, _ in .status(503, retryAfter: "7200") }
        let run = try run(jev.engine, on: Self.anyPage, bridge: WebViewBridge())
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .unavailable)
        XCTAssertEqual(jev.requests.count, 1)
        XCTAssertLessThan(clock.now - started, .seconds(10))
        let retryAt = try XCTUnwrap(outcome.retryAt, "when the service said to ask again")
        XCTAssertEqual(retryAt.timeIntervalSinceNow, 7200, accuracy: 30)
    }

    /// Stop during the wait for the service ends the errand at once.
    @MainActor
    func testStopDuringTheWaitForTheServiceEndsTheErrandAtOnce() async throws {
        let jev = RecordedJev { _, _ in .status(503, retryAfter: "60") }
        let run = try run(jev.engine, on: Self.anyPage, bridge: WebViewBridge())
        let clock = ContinuousClock()
        let started = clock.now
        let running = Task { await run.run(report: { _ in }) }
        while jev.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        run.stop()
        let outcome = await running.value
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertLessThan(clock.now - started, .seconds(10), "Stop did not wait out the minute")
        XCTAssertEqual(jev.requests.count, 1)
    }

    // MARK: - 4. A failed look is a miss

    /// A look that fails — a script that threw, a report that is not one —
    /// is a miss: the page is read again and the errand goes on.
    @MainActor
    func testAFailedLookIsAMissNotTheErrandsEnd() async throws {
        for failure in [FailsTheLooks.Failure.threw, .garbled] {
            let bridge = FailsTheLooks(times: 1, failure: failure)
            let outcome = await (try run(Self.doneAtOnce, on: Self.anyPage, bridge: bridge)).run(report: { _ in })
            XCTAssertEqual(outcome.ending, .done, "\(failure)")
            XCTAssertEqual(bridge.looks, 2, "\(failure): read again")
            XCTAssertEqual(bridge.inner.openTabCount, 0)
        }
    }

    /// Failed looks count toward the reconsider limit: two in a row are
    /// stuck, not a failure, and cost no call.
    @MainActor
    func testFailedLooksInARowAreStuck() async throws {
        let bridge = FailsTheLooks(times: 10, failure: .threw)
        let engine = Self.doneAtOnce
        let run = try run(engine, on: Self.anyPage, bridge: bridge)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stuck)
        XCTAssertEqual(run.record.steps.map(\.outcome), [.reconsidered, .reconsidered])
        XCTAssertNil(outcome.failure)
    }

    /// Only a lost bridge ends the errand, and it says so by kind alone.
    @MainActor
    func testALostBridgeEndsTheErrandAsBridgeLost() async throws {
        for error in [BrowserBridgeError.connectionLost] {
            let bridge = FailsTheLooks(times: 1, failure: .error(error))
            let run = try run(Self.doneAtOnce, on: Self.anyPage, bridge: bridge)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .failed, "\(error)")
            XCTAssertEqual(outcome.failure, .bridgeLost, "\(error)")
            XCTAssertEqual(run.record.failure, .bridgeLost, "\(error)")
            XCTAssertEqual(bridge.looks, 1, "\(error): not read again")
        }
    }

    /// Each other failure that ends an errand is recorded by its kind: the
    /// tab that would not open, the page that never settled. A Sheet that
    /// fails ends nothing (ITER-076 stage 6, P1-7): the errand keeps its
    /// ending and what it collected, and the Sheet's failure is named beside.
    @MainActor
    func testEachFailureThatEndsAnErrandIsRecordedByItsKind() async throws {
        let refused = try run(Self.doneAtOnce, on: Self.anyPage, bridge: RefusesToOpen())
        let notOpened = await refused.run(report: { _ in })
        XCTAssertEqual(notOpened.ending, .failed)
        XCTAssertEqual(notOpened.failure, .openFailed)

        let blank = try run(Self.doneAtOnce, on: Self.anyPage, bridge: StaysBlank())
        let neverSettled = await blank.run(report: { _ in })
        XCTAssertEqual(neverSettled.ending, .failed)
        XCTAssertEqual(neverSettled.failure, .neverSettled)

        let sheet = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes",
                            bridge: WebViewBridge(), sheet: FormulaSheet())
        let unwritten = await sheet.run(report: { _ in })
        XCTAssertEqual(unwritten.ending, .done)
        XCTAssertNil(unwritten.failure)
        XCTAssertEqual(unwritten.sheetFailure, .mismatch)
        XCTAssertEqual(unwritten.rows, 3, "what was collected is kept")
    }

    // MARK: - 5. A No is final

    /// An action the user said No to — or let the question lapse on — is
    /// never offered again on that page: the same question is never asked
    /// twice, and the errand goes on.
    @MainActor
    func testANoIsFinalForThatActionOnThatPage() async throws {
        let answers: [ConfirmationRequest.Answer?] = [.no, nil]
        for answer in answers {
            let asked = Counter()
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                    ?? request.candidates.first { $0.action.operation == .done })
            })
            let bridge = WebViewBridge()
            let run = try run(engine, on: "https://site-7.test/", bridge: bridge,
                              confirm: { _ in asked.add(); return answer })
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(asked.value, 1, "asked once: \(String(describing: answer))")
            XCTAssertEqual(outcome.ending, .done, "the errand went on")
            XCTAssertEqual(run.record.steps.map(\.outcome), [.refused, .acted])
            XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" })
        }
    }

    // MARK: - 6. A start page that lands elsewhere

    /// A start address that lands on another site — a consent or regional
    /// page — is read as it loaded, and the errand goes on.
    @MainActor
    func testAStartPageThatLandsOnAnotherSiteIsRead() async throws {
        let bridge = Redirects(from: "https://site-2.test/", to: "https://site-26.test/")
        let seen = Counter()
        let engine = ScriptedEngine(choice: { request in
            seen.add()
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let outcome = await (try run(engine, on: "https://site-2.test/", bridge: bridge)).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(seen.value, 1, "the page it landed on was read")
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// Where it lands, the rules hold: a consent page is the user's.
    @MainActor
    func testAStartPageThatLandsOnAConsentPageIsTheUsers() async throws {
        let consent = "https://site-54.test/consent?client_id=app-42&redirect_uri=https%3A%2F%2Fapp-42.test%2Fcb"
        let bridge = Redirects(from: "https://site-2.test/", to: consent)
        let run = try run(Self.doneAtOnce, on: "https://site-2.test/", bridge: bridge)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertTrue(run.record.steps.isEmpty)
    }

    // MARK: - 7. The factory the app will use

    /// The factory makes each errand's run from its setup: its id, its
    /// words, its bridge and its question to the user.
    @MainActor
    func testTheFactoryMakesTheRunFromTheErrandsSetup() async throws {
        let planner = RecordingPlanner(plan: try plan(search: "https://site-7.test/"))
        let make = AgentRun.factory(planner: planner, engine: ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                ?? request.candidates.first { $0.action.operation == .done })
        }), writer: FakeWriter(), sheet: { _ in FixtureSheet() })
        let bridge = WebViewBridge()
        let asked = Counter()
        let id = UUID()
        let runner = make(ErrandSetup(id: id, goal: "Send the message on site seven", bridge: bridge,
                                      confirm: { _ in asked.add(); return .no }))
        XCTAssertTrue(runner is AgentRun)
        XCTAssertEqual(runner.record.errandID, id)
        XCTAssertEqual(runner.record.goal, "Send the message on site seven")
        let outcome = await runner.run(report: { _ in })
        XCTAssertEqual(planner.goals, ["Send the message on site seven"], "planned from the user's words")
        XCTAssertEqual(bridge.openedURLs, [URL(string: "https://site-7.test/")!], "in the errand's browser")
        XCTAssertEqual(asked.value, 1, "the errand's own question")
        XCTAssertEqual(outcome.ending, .done)
    }

    /// A planner that fails ends the errand by that kind, before any page.
    @MainActor
    func testAPlannerThatFailsEndsTheErrandAsPlanFailed() async throws {
        let bridge = WebViewBridge()
        let make = AgentRun.factory(planner: FailingPlanner(), engine: Self.doneAtOnce, writer: FakeWriter(),
                                    sheet: { _ in FixtureSheet() })
        let runner = make(ErrandSetup(id: UUID(), goal: "Find three sites", bridge: bridge, confirm: { _ in nil }))
        let reports = Reports()
        let outcome = await runner.run(report: { reports.all.append($0) })
        XCTAssertEqual(outcome.ending, .failed)
        XCTAssertEqual(outcome.failure, .planFailed)
        XCTAssertEqual(runner.record.failure, .planFailed)
        XCTAssertTrue(bridge.openedURLs.isEmpty, "no page before a plan")
        XCTAssertTrue(reports.all.isEmpty)
    }

    // MARK: - Review round 1

    /// P1-2: the browser lost while the last row is read ends the errand as
    /// bridge lost — never done — and keeps the rows collected before.
    @MainActor
    func testABridgeLostWhileReadingARowEndsAsBridgeLost() async throws {
        let engine = ScriptedEngine(choice: { request in
            let onResults = request.candidates.contains {
                ($0.action.destination ?? "").hasPrefix("https://search.test/") && !$0.action.isPlannedSearch
            }
            let next = "https://site-\(request.rowsCollected + 1).test/"
            if onResults, let open = request.candidates.first(where: { $0.action.destination == next }) {
                return ScriptedEngine.pick(open)
            }
            let end: AgentOperation = request.rowsCollected == 2 ? .done : .back
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == end }, goalMet: 0.95)
        })
        for error in [BrowserBridgeError.connectionLost] {
            let bridge = LosesTheBridge(error, atExcerpt: 3)
            let run = try run(engine, on: "https://search.test/?q=voice+notes", bridge: bridge)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .failed, "\(error)")
            XCTAssertEqual(outcome.failure, .bridgeLost, "\(error)")
            XCTAssertEqual(outcome.sources.map(\.host), ["site-1.test", "site-2.test"], "\(error)")
            XCTAssertEqual(run.record.rows.count, 2, "\(error)")
        }
    }

    /// P1-2: the browser lost while the page settles again after a failed
    /// look ends the errand as bridge lost — never stuck.
    @MainActor
    func testABridgeLostWhileRecoveringFromAFailedLookEndsAsBridgeLost() async throws {
        for error in [BrowserBridgeError.connectionLost] {
            let bridge = LosesTheBridge(error, afterFailedLooks: 2)
            let run = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes", bridge: bridge)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .failed, "\(error)")
            XCTAssertEqual(outcome.failure, .bridgeLost, "\(error)")
            XCTAssertEqual(outcome.rows, 2, "\(error): the rows before are kept")
        }
    }

    /// ITER-076 stage 8a, № 117 — the user closing the agent's tab is the
    /// user's stop, wherever the run finds it gone: at a look, at a row's
    /// read, as the page settles after a failed look, at the start page. The
    /// errand ends stopped — "Stopped." — with what it found, no failure on
    /// record and none reported.
    @MainActor
    func testTheAgentsTabClosedIsTheUsersStopNotAFailure() async throws {
        let cases: [(String, any BrowserBridge, any DecisionEngine, rows: Int)] = [
            ("at a look", FailsTheLooks(times: 1, failure: .error(.tabNotFound)), Self.doneAtOnce, 0),
            ("at a row's read", LosesTheBridge(.tabNotFound, atExcerpt: 3), ScriptedEngine.collectSites(), 2),
            ("after a failed look", LosesTheBridge(.tabNotFound, afterFailedLooks: 2), ScriptedEngine.collectSites(), 2),
            ("at the start page", LosesTheBridge(.tabNotFound, atOnce: true), Self.doneAtOnce, 0),
        ]
        for (when, bridge, engine, rows) in cases {
            let run = try run(engine, on: rows > 0 ? "https://search.test/?q=voice+notes" : Self.anyPage, bridge: bridge)
            let outcome = await run.run(report: { _ in })
            XCTAssertEqual(outcome.ending, .stopped, when)
            XCTAssertNil(outcome.failure, when)
            XCTAssertEqual(run.record.ending, .stopped, when)
            XCTAssertNil(run.record.failure, when)
            XCTAssertEqual(outcome.rows, rows, "\(when): what it found is kept")
            XCTAssertEqual(outcome.sources.compactMap(\.host), Array(["site-1.test", "site-2.test"].prefix(rows)), when)
            XCTAssertEqual(ChatService.errandEndingLine(outcome), "Stopped.", when)
            XCTAssertFalse(AgentService.reportedEndings.contains(outcome.ending), "\(when): not reported")
        }
    }

    /// P2-1: the Sheet's address is kept the moment it is made; a paste that
    /// fails leaves it, made but not written — and the errand done, the
    /// Sheet's failure named beside it (ITER-076 stage 6, P1-7).
    @MainActor
    func testAPasteThatFailsKeepsTheSheetItMade() async throws {
        let sheet = PasteFails()
        let run = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes",
                          bridge: WebViewBridge(), sheet: sheet)
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.sheetFailure, .mismatch)
        let made = try XCTUnwrap(sheet.made)
        XCTAssertEqual(outcome.sheet, made, "the Sheet exists: its address is not lost")
        XCTAssertEqual(run.record.sheet, made)
        XCTAssertEqual(run.record.sheetWrite, .created, "made, and the rows not known to be in it")
    }

    /// P2-1: a Sheet written and read back says so.
    @MainActor
    func testASheetReadBackIntactIsVerified() async throws {
        let run = try run(ScriptedEngine.collectSites(), on: "https://search.test/?q=voice+notes", bridge: WebViewBridge())
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.sheetWrite, .verified)
    }

    /// P2-2: a No holds when the page draws the same action again — under
    /// another heading, on an address with another fragment.
    @MainActor
    func testANoHoldsWhenThePageRedrawsTheSameAction() async throws {
        let asked = Counter()
        let bridge = WebViewBridge()
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                ?? request.candidates.first { $0.action.operation == .done })
        })
        let redraw = "history.replaceState(null, '', '#moved');"
            + "document.getElementById('message').insertAdjacentHTML('beforebegin', '<h2>Your message</h2>'); ''"
        let run = try run(engine, on: "https://site-7.test/", bridge: bridge, confirm: { request in
            asked.add()
            _ = try? await bridge.run(redraw, in: request.tab)
            return .no
        })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.value, 1, "the redrawn Continue is the same action: not asked again")
        XCTAssertEqual(outcome.ending, .done)
    }

    /// P2-4: Stop pressed while the run reports a row ends it there: nothing
    /// more is reported, asked or done — not even the user's part the step
    /// had chosen.
    @MainActor
    func testNothingIsReportedOrDoneAfterStopInsideAProgressReport() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Allow access" }, goalMet: 0.95)
        })
        let run = try run(engine, on: "https://site-29.test/", bridge: WebViewBridge())
        let reports = Reports()
        let outcome = await run.run(report: { progress in
            reports.all.append(progress)
            if case .working(_, 1, _) = progress { run.stop() }
        })
        XCTAssertEqual(reports.all, [.working(title: "Competitors", done: 0, wanted: 3),
                                     .working(title: "Competitors", done: 1, wanted: 3)], "nothing after Stop")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.rows, 1)
        XCTAssertTrue(run.record.steps.isEmpty, "no step after Stop")
        XCTAssertTrue(engine.riskQuestions.isEmpty, "nothing more asked")
    }

    /// P2-5: a retry that fits the wait is still cut off at the ceiling of
    /// work — not at its own deadline.
    @MainActor
    func testARetryIsCutOffAtTheActiveTimeCeiling() async throws {
        let jev = RecordedJev { _, number in
            number == 0 ? .status(503, retryAfter: "1") : .after(.seconds(8), .answers(operation: "DONE"))
        }
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 2.5, spendMicros: 500_000, expiry: .seconds(1_800))
        let run = AgentRun(plan: try plan(search: Self.anyPage), errandID: UUID(),
                           collaborators: .init(bridge: WebViewBridge(), engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }),
                           limits: limits)
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .ceiling)
        XCTAssertEqual(jev.requests.count, 2, "the retry was sent")
        XCTAssertLessThan(clock.now - started, .seconds(4), "cut off at 2.5 s of work, not at the call's 10 s")
    }

    /// P2-5: a call cut off by the errand's own time ends the errand at the
    /// ceiling — never as a failed plan or a service that is down.
    @MainActor
    func testACallCutOffByTheErrandsOwnTimeEndsAtTheCeiling() async throws {
        let plan = try plan(search: Self.anyPage)
        let run = AgentRun(goal: plan.goal, planner: CostlyPlanner(plan: plan, fails: false, takes: .seconds(5)),
                           errandID: UUID(),
                           collaborators: .init(bridge: WebViewBridge(), engine: Self.doneAtOnce, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }),
                           limits: AgentBudget.Limits(steps: 40, activeSeconds: 0.3, spendMicros: 500_000,
                                                      expiry: .seconds(1_800)))
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .ceiling, "the plan was cut at 0.3 s of work: the ceiling, not a failed plan")
        XCTAssertNil(outcome.failure)
        XCTAssertLessThan(clock.now - started, .seconds(2))
    }

    /// P2-6: what the plan cost is kept in the record — when it is made,
    /// when it fails, and at Stop — and counts toward the spend ceiling.
    @MainActor
    func testThePlansSpendIsKeptOnSuccessFailureAndStop() async throws {
        let plan = try plan(search: Self.anyPage)
        func errand(_ planner: any ErrandPlanner, spend: Int = 500_000) -> AgentRun {
            AgentRun(goal: plan.goal, planner: planner, errandID: UUID(),
                     collaborators: .init(bridge: WebViewBridge(), engine: Self.doneAtOnce, writer: FakeWriter(),
                                          sheet: FixtureSheet(), confirm: { _ in .no }),
                     limits: AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: spend,
                                                expiry: .seconds(1_800)))
        }
        let made = errand(CostlyPlanner(plan: plan, fails: false))
        let done = await made.run(report: { _ in })
        XCTAssertEqual(done.ending, .done)
        XCTAssertEqual(made.record.spentUSD ?? -1, 0.02 + 0.0005, accuracy: 1e-9, "the plan and the one step")

        let failed = errand(CostlyPlanner(plan: plan, fails: true))
        let planFailed = await failed.run(report: { _ in })
        XCTAssertEqual(planFailed.failure, .planFailed)
        XCTAssertEqual(failed.record.spentUSD ?? -1, 0.02, accuracy: 1e-9, "a failed plan is paid for too")

        let stopped = errand(CostlyPlanner(plan: plan, fails: false, takes: .seconds(5)))
        let running = Task { await stopped.run(report: { _ in }) }
        try await Task.sleep(for: .milliseconds(200))
        stopped.stop()
        let atStop = await running.value
        XCTAssertEqual(atStop.ending, .stopped)
        XCTAssertEqual(stopped.record.spentUSD ?? -1, 0.02, accuracy: 1e-9, "a plan stopped is paid for as asked")

        // The plan's spend counts toward the ceiling: the step after it would
        // cross $0.0205, so it is not asked.
        let capped = errand(CostlyPlanner(plan: plan, fails: false), spend: 20_500)
        let ceiling = await capped.run(report: { _ in })
        XCTAssertEqual(ceiling.ending, .ceiling)
        XCTAssertEqual(capped.record.spentUSD ?? -1, 0.02, accuracy: 1e-9)
    }

    /// ITER-076 stage 8a — only a call that left the Mac is charged. One
    /// refused before its request went out — no license, a body over the
    /// server's limit — costs nothing, the model's and Jev's alike, and so does
    /// one the owner's switch turned away at the server's door, which reads
    /// none of it. A call that went out and said nothing of its cost still
    /// counts whole (§8).
    @MainActor
    func testOnlyACallThatLeftTheMacIsCharged() async throws {
        let rows = try plan(search: Self.anyPage)
        func errand(_ planner: any ErrandPlanner, goal: String? = nil,
                    engine: any DecisionEngine = Self.doneAtOnce) -> AgentRun {
            AgentRun(goal: goal ?? rows.goal, planner: planner, errandID: UUID(),
                     collaborators: .init(bridge: WebViewBridge(), engine: engine, writer: FakeWriter(),
                                          sheet: FixtureSheet(), confirm: { _ in .no }))
        }
        let model = RecordedModel { _, _ in .status(400) }

        let unlicensed = errand(TextPlanner(client: ProLLMClient(licenseKey: { nil }, send: { try await model.send($0) },
                                                                 log: { _ in })))
        let noPro = await unlicensed.run(report: { _ in })
        XCTAssertEqual(noPro.ending, .noPro)
        XCTAssertEqual(unlicensed.record.spentUSD ?? -1, 0, accuracy: 1e-12, "no license: the plan's call never left")

        let large = errand(model.planner, goal: String(repeating: "x", count: ProLLMClient.maxBodyBytes))
        let unsent = await large.run(report: { _ in })
        XCTAssertEqual(unsent.failure, .planFailed)
        XCTAssertEqual(large.record.spentUSD ?? -1, 0, accuracy: 1e-12, "over the server's limit: never sent")
        XCTAssertTrue(model.requests.isEmpty, "the premise: neither call went out")

        let jev = RecordedJev { _, _ in .answers(operation: "done") }
        let step = AgentRun(plan: rows, errandID: UUID(),
                            collaborators: .init(bridge: WebViewBridge(),
                                                 engine: JevDecisionEngine(jev: JevEngine(licenseKey: { nil },
                                                                                          send: { try await jev.send($0) },
                                                                                          log: { _ in })),
                                                 writer: FakeWriter(), sheet: FixtureSheet(), confirm: { _ in .no }))
        let jevNoPro = await step.run(report: { _ in })
        XCTAssertEqual(jevNoPro.ending, .noPro)
        XCTAssertEqual(step.record.spentUSD ?? -1, 0, accuracy: 1e-12, "no license: Jev's call never left")
        XCTAssertTrue(jev.requests.isEmpty, "the premise: it did not go out")

        let switchedOff = RecordedModel { _, _ in .switchedOff }
        let off = errand(switchedOff.planner)
        let stopped = await off.run(report: { _ in })
        XCTAssertEqual(stopped.ending, .stopped)
        XCTAssertEqual(off.record.spentUSD ?? -1, 0, accuracy: 1e-12, "the switch turned it away before any model")
        XCTAssertEqual(switchedOff.requests.count, 1, "the premise: it went out")

        let sent = errand(model.planner)
        let refusedThere = await sent.run(report: { _ in })
        XCTAssertEqual(refusedThere.failure, .planFailed)
        XCTAssertEqual(sent.record.spentUSD ?? -1, model.planner.worstCaseUSD(goal: rows.goal), accuracy: 1e-6,
                       "sent, and no cost said: all of its worst case, in the budget's millionths")
        XCTAssertEqual(model.requests.count, 1, "the premise: it went out")
    }

    /// P2-3: whatever a collaborator does after Stop — a paste that takes
    /// its time and does not hear Stop — `run` returns within Stop's limit.
    @MainActor
    func testRunReturnsWithinStopsLimitWhateverACollaboratorTakes() async throws {
        let sheet = SlowPaste()
        let run = AgentRun(plan: try plan(search: "https://search.test/?q=voice+notes"), errandID: UUID(),
                           collaborators: .init(bridge: WebViewBridge(), engine: ScriptedEngine.collectSites(),
                                                writer: FakeWriter(), sheet: sheet, confirm: { _ in .no }),
                           stopLimit: .milliseconds(500))
        let stoppedAt = Box<ContinuousClock.Instant>()
        sheet.onPaste = {
            run.stop()
            stoppedAt.value = .now
        }
        let outcome = await run.run(report: { _ in })
        let stop = try XCTUnwrap(stoppedAt.value)
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertLessThan(ContinuousClock.now - stop, .milliseconds(1_500), "Stop's limit, not the paste's 5 s")
        XCTAssertNotNil(outcome.sheet, "the Sheet made before Stop is kept")
    }

    /// P2-4: Stop pressed while the run reads the page to name the user's
    /// part: that part is not reported.
    @MainActor
    func testAHandoverStopInterruptsIsNotReported() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let bridge = StopsWhileNamingTheWall()
        let run = try run(engine, on: "https://site-26.test/", bridge: bridge)
        bridge.stop = { run.stop() }
        let reports = Reports()
        let outcome = await run.run(report: { reports.all.append($0) })
        XCTAssertTrue(bridge.stopped, "Stop came while the page was read")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(reports.all, [.working(title: "Competitors", done: 0, wanted: 3)], "no handover after Stop")
    }

    // MARK: - ITER-076 I-06a: every event on record and in the log

    /// The log said what the record holds, under the errand's id.
    @MainActor
    private func assertTheLogMatches(_ run: AgentRun, _ lines: LogLines, _ what: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(run.record.events.isEmpty, what, file: file, line: line)
        XCTAssertEqual(lines.events(of: run.record.errandID), run.record.eventLines, what, file: file, line: line)
    }

    /// A plan that could not be written is on record by its kind, with the
    /// ending it caused — and the factory's run says it in the log it is given.
    @MainActor
    func testAPlanThatFailedIsOnRecordByItsKind() async throws {
        let lines = LogLines()
        let make = AgentRun.factory(planner: FailingPlanner(), engine: Self.doneAtOnce, writer: FakeWriter(),
                                    sheet: { _ in FixtureSheet() })
        let id = UUID()
        let runner = make(ErrandSetup(id: id, goal: "Find three sites", bridge: WebViewBridge(), confirm: { _ in nil },
                                      log: lines.sink))
        _ = await runner.run(report: { _ in })
        XCTAssertEqual(runner.record.events.map(\.shape), ["plan failed", "ending failed planFailed rows=0"])
        XCTAssertEqual(lines.events(of: id), runner.record.eventLines)
    }

    /// Each answer of the service is on record: a wait for it — unanswered
    /// when it stayed down — and the ending it caused, never a step.
    @MainActor
    func testTheServicesAnswersAreOnRecordAsWaitsAndEndings() async throws {
        let cases: [(status: Int, retryAfter: String?, shapes: [String])] = [
            (401, nil, ["plan ok", "ending noPro rows=0"]),
            (429, "3600", ["plan ok", "ending dailyLimit rows=0"]),
            (503, "0", ["plan ok", "wait unanswered", "ending unavailable engineUnavailable rows=0"]),
        ]
        for (status, retryAfter, shapes) in cases {
            let jev = RecordedJev { _, _ in .status(status, retryAfter: retryAfter) }
            let lines = LogLines()
            let run = try run(jev.engine, on: Self.anyPage, bridge: WebViewBridge(), lines: lines)
            _ = await run.run(report: { _ in })
            XCTAssertEqual(run.record.events.map(\.shape), shapes, "\(status)")
            assertTheLogMatches(run, lines, "\(status)")
        }
    }

    /// A wait Stop cuts short is on record as cut: whether the service would
    /// have answered is not known.
    @MainActor
    func testAWaitStopCutsShortIsOnRecordAsCut() async throws {
        let jev = RecordedJev { _, _ in .status(503, retryAfter: "60") }
        let lines = LogLines()
        let run = try run(jev.engine, on: Self.anyPage, bridge: WebViewBridge(), lines: lines)
        let running = Task { await run.run(report: { _ in }) }
        while jev.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        run.stop()
        _ = await running.value
        XCTAssertEqual(run.record.events.map(\.shape), ["plan ok", "wait cut", "ending stopped rows=0"])
        guard case .serviceWait(let seconds, _)? = run.record.events.dropFirst().first else { return XCTFail() }
        XCTAssertEqual(seconds, 60, "as long as the service asked")
        assertTheLogMatches(run, lines)
    }

    /// A question to the user and the answer — No, or none in time — are on
    /// record, then the step it decided.
    @MainActor
    func testAQuestionAndItsAnswerAreOnRecord() async throws {
        let answers: [(ConfirmationRequest.Answer?, String)] = [(.no, "answer no"), (nil, "answer expired")]
        for (answer, said) in answers {
            let engine = ScriptedEngine(choice: { request in
                ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                    ?? request.candidates.first { $0.action.operation == .done })
            })
            let lines = LogLines()
            let run = try run(engine, on: "https://site-7.test/", bridge: WebViewBridge(), confirm: { _ in answer },
                              lines: lines)
            _ = await run.run(report: { _ in })
            XCTAssertEqual(run.record.events.map(\.shape),
                           ["plan ok", "question click button", said, "step click refused", "step done acted",
                            "ending done rows=0"], said)
            assertTheLogMatches(run, lines, said)
        }
    }

    /// The user's part is on record by its kind and the page's host alone —
    /// nothing of its address beyond the host.
    @MainActor
    func testAHandoverIsOnRecordByItsKindAndHostAlone() async throws {
        let consent = "https://site-54.test/consent?client_id=app-42&redirect_uri=https%3A%2F%2Fapp-42.test%2Fcb"
        let lines = LogLines()
        let run = try run(Self.doneAtOnce, on: consent, bridge: WebViewBridge(), lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.events.map(\.shape),
                       ["plan ok", "handover grant site-54.test", "ending needsUser rows=0"])
        assertTheLogMatches(run, lines)
        let said = (lines.all + [String(decoding: try JSONEncoder().encode(run.record.events), as: UTF8.self)])
            .joined(separator: "\n")
        for part in ["consent", "client_id", "app-42", "redirect"] { XCTAssertFalse(said.contains(part), part) }
    }

    /// A read of the page that failed is on record by its kind — the script
    /// failed, or what it answered is not a report — and so is a page that
    /// never settled.
    @MainActor
    func testPageMissesAreOnRecordByTheirKind() async throws {
        let failures: [(FailsTheLooks.Failure, String)] = [(.threw, "miss read"), (.garbled, "miss report")]
        for (failure, said) in failures {
            let lines = LogLines()
            let run = try run(Self.doneAtOnce, on: Self.anyPage, bridge: FailsTheLooks(times: 1, failure: failure),
                              lines: lines)
            _ = await run.run(report: { _ in })
            XCTAssertEqual(run.record.events.map(\.shape),
                           ["plan ok", said, "step none reconsidered", "step done acted", "ending done rows=0"], said)
            assertTheLogMatches(run, lines, said)
        }
        let lines = LogLines()
        let blank = try run(Self.doneAtOnce, on: Self.anyPage, bridge: StaysBlank(), lines: lines)
        _ = await blank.run(report: { _ in })
        XCTAssertEqual(blank.record.events.map(\.shape),
                       ["plan ok", "miss settle", "ending failed neverSettled rows=0"])
        assertTheLogMatches(blank, lines)
    }

    /// A look that fails after a paid step is a miss that cost nothing: a
    /// step's cost is its own, never the step before's (review of I-06a).
    @MainActor
    func testAMissAfterAPaidStepCostsNothing() async throws {
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            asked.add()
            return ScriptedEngine.pick(request.candidates.first {
                $0.action.operation == (asked.value == 1 ? .wait : .done)
            })
        })
        let lines = LogLines()
        let run = try run(engine, on: Self.anyPage, bridge: FailsTheLooks(times: 1, failure: .threw, after: 1),
                          lines: lines)
        _ = await run.run(report: { _ in })
        let paid = try XCTUnwrap(run.record.steps.first { $0.operation == "wait" })
        XCTAssertGreaterThan(paid.costUSD ?? 0, 0, "the paid step keeps its cost")
        let missed = try XCTUnwrap(run.record.steps.first { $0.operation == "none" })
        XCTAssertEqual(missed.costUSD, 0, "the miss after it paid nothing")
        assertTheLogMatches(run, lines)
    }

    /// A row's excerpt that could not be read, or that is not a report, is on
    /// record by its kind; the errand goes on.
    @MainActor
    func testAnExcerptThatCouldNotBeReadIsOnRecordByItsKind() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done }, goalMet: 0.95)
        })
        let failures: [(SpoilsTheExcerpt.Failure, String)] = [(.threw, "miss read"), (.garbled, "miss report")]
        for (failure, said) in failures {
            let lines = LogLines()
            let run = try run(engine, on: Self.anyPage, bridge: SpoilsTheExcerpt(failure), lines: lines)
            _ = await run.run(report: { _ in })
            XCTAssertEqual(run.record.events.map(\.shape), ["plan ok", said, "step done acted", "ending done rows=0"],
                           said)
            assertTheLogMatches(run, lines, said)
        }
    }

    /// A Yes whose fresh look is not a report is on record — the question,
    /// the Yes, the look that failed — and the action is not taken on it.
    @MainActor
    func testALookAfterAYesThatIsNotAReportIsOnRecord() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                ?? request.candidates.first { $0.action.operation == .done })
        })
        let bridge = GarblesALook()
        let asked = Counter()
        let lines = LogLines()
        let run = try run(engine, on: "https://site-7.test/", bridge: bridge, confirm: { _ in
            asked.add()
            guard asked.value == 1 else { return .no }
            bridge.garbleNextLook = true
            return .yes
        }, lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.events.map(\.shape),
                       ["plan ok", "question click button", "answer yes", "miss report", "step click refused",
                        "question click button", "answer no", "step click refused", "step done acted",
                        "ending done rows=0"])
        assertTheLogMatches(run, lines)
        XCTAssertFalse(bridge.navigatedURLs.contains { $0.path == "/send-message" }, "not taken on a failed look")
    }

    /// A step whose postcondition does not hold is corrected in the record
    /// and said again in the log under its number.
    @MainActor
    func testACorrectedStepIsSaidAgainInTheLog() async throws {
        let steps = Counter()
        let engine = ScriptedEngine(choice: { request in
            steps.add()
            let operation: AgentOperation = steps.value == 1 ? .scroll : .done
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == operation })
        })
        let lines = LogLines()
        let run = try run(engine, on: "https://site-7.test/", bridge: WebViewBridge(), lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.events.map(\.shape),
                       ["plan ok", "step scroll failed", "step done acted", "ending done rows=0"],
                       "a page too short to scroll")
        let said = lines.numbered(of: run.record.errandID)
        XCTAssertEqual(said.count, 5)
        XCTAssertTrue(said[1].contains("#2 step op=scroll outcome=acted "), said[1])
        XCTAssertEqual(said[2], run.record.logLine(at: 1), "said again, corrected")
        assertTheLogMatches(run, lines)
    }

    /// A step recorded as it went out and taken back — Stop came before the
    /// call did — is said so in the log, under the step's own number.
    @MainActor
    func testAStepTakenBackIsSaidSoInTheLog() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let bridge = StopsBeforeTheAct()
        let lines = LogLines()
        let run = try run(engine, on: "https://site-26.test/", bridge: bridge, lines: lines)
        bridge.stop = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertTrue(run.record.steps.isEmpty, "nothing went out")
        // I-06a review, P2-1: numbers only grow — the step's event becomes
        // "taken back" under its own number, and the ending takes the next.
        XCTAssertEqual(run.record.events.map(\.shape), ["plan ok", "taken back", "ending stopped rows=0"])
        let said = lines.numbered(of: run.record.errandID).map { $0.split(separator: " ").dropFirst(3).prefix(2) }
        XCTAssertEqual(said.map { $0.joined(separator: " ") },
                       ["plan result=ok", "step op=click", "taken back", "ending kind=stopped"])
        XCTAssertEqual(lines.numbered(of: run.record.errandID).map { $0.split(separator: " ")[2] },
                       ["#1", "#2", "#2", "#3"])
        assertTheLogMatches(run, lines)
    }

    /// ITER-076 I-09, round 5: Stop while an act's lookup is out — the
    /// lookup answers, found — sends nothing after it: the act never goes.
    @MainActor
    func testStopWhileAnActsLookupIsOutSendsNothing() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Show details" })
        })
        let bridge = StopsAtTheLookup()
        let run = try run(engine, on: "https://site-26.test/", bridge: bridge)
        bridge.stop = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertTrue(bridge.lookedUp, "the act was looked up alone first")
        XCTAssertEqual(bridge.actsAfterStop, 0, "nothing sent after Stop")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertFalse(run.record.steps.contains { $0.outcome == .acted }, "nothing went out")
    }

    /// I-06a review, P2-3: a read that fails while the page settles is on
    /// record once, where it failed: the start page's settle is cut short.
    @MainActor
    func testAReadThatFailsWhileThePageSettlesIsOnRecordOnce() async throws {
        let lines = LogLines()
        let run = try run(Self.doneAtOnce, on: Self.anyPage, bridge: FailsTheFirstLoadingCheck(), lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertEqual(run.record.events.map(\.shape), ["plan ok", "miss read", "ending failed neverSettled rows=0"])
        assertTheLogMatches(run, lines)
    }

    /// I-06a review, P2-3: the look that checks a click, when what it
    /// answered is not a report, is on record once, by its kind — and the
    /// click is corrected as not held.
    @MainActor
    func testAMissedLookAfterAClickIsOnRecordOnce() async throws {
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            asked.add()
            return ScriptedEngine.pick(asked.value == 1
                ? request.candidates.first { $0.action.target?.name == "Show details" }
                : request.candidates.first { $0.action.operation == .done })
        })
        let bridge = SpoilsAfterTheAct(.look)
        let lines = LogLines()
        let run = try run(engine, on: "https://site-26.test/", bridge: bridge, lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertTrue(bridge.spoiled)
        XCTAssertEqual(run.record.events.map(\.shape),
                       ["plan ok", "step click failed", "miss report", "step done acted", "ending done rows=0"])
        assertTheLogMatches(run, lines)
    }

    /// I-06a review, P2-3: a navigation that never settles after an open is
    /// on record once, by its kind — and the open is corrected as not held.
    /// It waits out the page's deadline.
    @MainActor
    func testANavigationThatNeverSettlesIsOnRecordOnce() async throws {
        let asked = Counter()
        let engine = ScriptedEngine(choice: { request in
            asked.add()
            return ScriptedEngine.pick(asked.value == 1
                ? request.candidates.first { $0.action.target?.name == "Next page" }
                : request.candidates.first { $0.action.operation == .done })
        })
        let bridge = SpoilsAfterTheAct(.settle)
        let lines = LogLines()
        let run = try run(engine, on: "https://site-26.test/", bridge: bridge, lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertTrue(bridge.spoiled)
        XCTAssertEqual(run.record.events.map(\.shape),
                       ["plan ok", "step open failed", "miss settle", "step done acted", "ending done rows=0"])
        assertTheLogMatches(run, lines)
    }

    /// Nothing of the page — its text, a label, a value already typed in a
    /// field, an address beyond its host — nor the goal is in the record's
    /// events or in any line; the record as a whole holds the goal, as it
    /// did, and nothing of the page.
    @MainActor
    func testNoPageTextLabelTypedValueOrGoalReachesTheRecordOrTheLog() async throws {
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.target?.name == "Continue" }
                ?? request.candidates.first { $0.action.operation == .done })
        })
        let lines = LogLines()
        let run = try run(engine, on: "https://site-7.test/", bridge: WebViewBridge(), lines: lines)
        _ = await run.run(report: { _ in })
        XCTAssertGreaterThanOrEqual(run.record.events.count, 5)
        let record = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        let events = String(decoding: try JSONEncoder().encode(run.record.events), as: UTF8.self)
        let page = ["Site Seven", "Contact us", "Your message", "Draft text already typed", "Continue", "Decoy",
                    "Clobbered", "Override", "send-message", "real-destination", "/search"]
        for fixture in page {
            XCTAssertFalse(record.contains(fixture), "record: \(fixture)")
            for line in lines.all { XCTAssertFalse(line.contains(fixture), "\(fixture) in \(line)") }
        }
        for goal in ["Add three competitor sites", "competitor"] {
            XCTAssertFalse(events.contains(goal), goal)
            for line in lines.all { XCTAssertFalse(line.contains(goal), "\(goal) in \(line)") }
        }
    }

    // MARK: - Helpers

    /// A planner that keeps the goals it was asked for.
    private final class RecordingPlanner: ErrandPlanner, @unchecked Sendable {
        func worstCaseUSD(goal: String) -> Double { 0 }
        private let planned: AgentPlan
        private let lock = NSLock()
        private var asked: [String] = []

        init(plan: AgentPlan) { planned = plan }

        var goals: [String] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        func plan(goal: String) async throws -> AgentPlan {
            keep(goal)
            return planned
        }

        private func keep(_ goal: String) {
            lock.lock()
            defer { lock.unlock() }
            asked.append(goal)
        }
    }

    /// A planner that costs $0.02 at worst and reports no usage — so all of
    /// it counts — and may fail, or take its time.
    private struct CostlyPlanner: ErrandPlanner {
        struct Refused: Error {}
        let plan: AgentPlan
        let fails: Bool
        var takes: Duration = .zero
        func worstCaseUSD(goal: String) -> Double { 0.02 }

        func plan(goal: String) async throws -> AgentPlan {
            if takes > .zero { try await Task.sleep(for: takes) }
            if fails { throw Refused() }
            return plan
        }
    }

    /// The fixture browser, lost for good: at the `atExcerpt`-th read of a
    /// row's excerpt, or — `afterFailedLooks` — once that many looks after the
    /// second row have failed, or — `atOnce` — as soon as its tab is open,
    /// every call from then on throws `error`.
    @MainActor
    private final class LosesTheBridge: BrowserBridge {
        let inner = WebViewBridge()
        private let error: BrowserBridgeError
        private let atExcerpt: Int?
        private let afterFailedLooks: Int?
        private var excerpts = 0
        private var failedLooks = 0
        private var lost: Bool

        init(_ error: BrowserBridgeError, atExcerpt: Int? = nil, afterFailedLooks: Int? = nil, atOnce: Bool = false) {
            self.error = error
            self.atExcerpt = atExcerpt
            self.afterFailedLooks = afterFailedLooks
            lost = atOnce
        }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            if lost { throw error }
            return try await inner.isLoading(tab)
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if lost { throw error }
            if javascript.contains("observe({ excerpt:") {
                excerpts += 1
                if excerpts == atExcerpt {
                    lost = true
                    throw error
                }
            }
            if let afterFailedLooks, excerpts >= 2, javascript == ObserverScript.source {
                failedLooks += 1
                if failedLooks == afterFailedLooks { lost = true }
                throw BrowserBridgeError.scriptFailed(code: -3)
            }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if lost { throw error }
            return try await inner.runAwaiting(javascript, in: tab)
        }
        func history(of tab: BrowserTab) async throws -> BrowserHistory {
            if lost { throw error }
            return try await inner.history(of: tab)
        }
        func goBack(to entry: Int, in tab: BrowserTab) async throws {
            if lost { throw error }
            try await inner.goBack(to: entry, in: tab)
        }
    }

    /// A fixture Sheet whose paste calls `onPaste`, then takes 5 s and does
    /// not hear Stop.
    @MainActor
    private final class SlowPaste: SheetDestination {
        private let inner = FixtureSheet()
        var onPaste: (@MainActor () -> Void)?

        func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
            try await inner.create(title: title, made: made)
        }

        func paste(_ text: String, into sheet: URL) async throws {
            onPaste?()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { continuation.resume() }
            }
            try await inner.paste(text, into: sheet)
        }

        func readBack(_ sheet: URL) async throws -> SheetReadBack { try await inner.readBack(sheet) }
    }

    /// The fixture browser, where a password field comes right before the
    /// act — a wall — and the look that names it presses Stop and gets no
    /// report back.
    @MainActor
    private final class StopsWhileNamingTheWall: BrowserBridge {
        let inner = WebViewBridge()
        var stop: (@MainActor () -> Void)?
        private var walled = false
        private(set) var stopped = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if walled, !stopped, javascript == ObserverScript.source {
                stopped = true
                stop?()
                return "{}"
            }
            if !walled, javascript.contains("const expected") {
                walled = true
                _ = try await inner.run("document.querySelector('main').insertAdjacentHTML('beforeend', "
                                        + "'<input type=password aria-label=Code>'); ''", in: tab)
            }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A fixture Sheet whose paste fails once the Sheet is made.
    @MainActor
    private final class PasteFails: SheetDestination {
        struct Failed: Error {}
        private let inner = FixtureSheet()
        private(set) var made: URL?

        func create(title: String, made receipt: @escaping @MainActor (URL) -> Void) async throws -> URL {
            let address = try await inner.create(title: title, made: receipt)
            made = address
            return address
        }

        func paste(_ text: String, into sheet: URL) async throws { throw Failed() }
        func readBack(_ sheet: URL) async throws -> SheetReadBack { try await inner.readBack(sheet) }
    }

    private struct FailingPlanner: ErrandPlanner {
        struct Refused: Error {}
        func worstCaseUSD(goal: String) -> Double { 0 }
        func plan(goal: String) async throws -> AgentPlan { throw Refused() }
    }

    /// The fixture browser, failing the observer's first looks: the script
    /// throws, its report is garbled, or the bridge fails with `error`.
    @MainActor
    private final class FailsTheLooks: BrowserBridge {
        enum Failure { case threw, garbled, error(BrowserBridgeError) }

        let inner = WebViewBridge()
        private let times: Int
        private let failure: Failure
        private let after: Int
        private(set) var looks = 0

        /// Spoils `times` looks, after the first `after` that read as they are.
        init(times: Int, failure: Failure, after: Int = 0) {
            self.times = times
            self.failure = failure
            self.after = after
        }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard javascript == ObserverScript.source else { return try await inner.run(javascript, in: tab) }
            looks += 1
            guard looks > after, looks <= after + times else { return try await inner.run(javascript, in: tab) }
            switch failure {
            case .threw: throw BrowserBridgeError.scriptFailed(code: -3)
            case .garbled: return "{\"url\":"
            case .error(let error): throw error
            }
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, spoiling the first read of a row's excerpt: the
    /// script throws, or its answer is not a report.
    @MainActor
    private final class SpoilsTheExcerpt: BrowserBridge {
        enum Failure { case threw, garbled }

        let inner = WebViewBridge()
        private let failure: Failure
        private var spoiled = false

        init(_ failure: Failure) { self.failure = failure }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard !spoiled, javascript.contains("observe({ excerpt:") else { return try await inner.run(javascript, in: tab) }
            spoiled = true
            switch failure {
            case .threw: throw BrowserBridgeError.scriptFailed(code: -3)
            case .garbled: return "{\"url\":"
            }
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, answering the look after `garbleNextLook` is set
    /// with what is not a report.
    @MainActor
    private final class GarblesALook: BrowserBridge {
        let inner = WebViewBridge()
        var garbleNextLook = false
        var navigatedURLs: [URL] { inner.navigatedURLs }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            guard garbleNextLook, javascript == ObserverScript.source else { return try await inner.run(javascript, in: tab) }
            garbleNextLook = false
            return "{}"
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, spoiling only what checks the first act: the
    /// look after it answers what is not a report, or the page stays loading
    /// past the page's deadline.
    @MainActor
    private final class SpoilsAfterTheAct: BrowserBridge {
        enum Spoil { case look, settle }

        let inner = WebViewBridge()
        private let spoil: Spoil
        private var actedAt: ContinuousClock.Instant?
        private(set) var spoiled = false

        init(_ spoil: Spoil) { self.spoil = spoil }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            if spoil == .settle, let actedAt, ContinuousClock.now - actedAt < AgentRun.pageDeadline + .seconds(1) {
                spoiled = true
                return true
            }
            return try await inner.isLoading(tab)
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if actedAt == nil, javascript.contains("const expected") {
                actedAt = .now
                return try await inner.run(javascript, in: tab)
            }
            if spoil == .look, actedAt != nil, !spoiled, javascript == ObserverScript.source {
                spoiled = true
                return "{}"
            }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// The fixture browser, whose first answer to whether the page loads is
    /// a script that failed.
    @MainActor
    private final class FailsTheFirstLoadingCheck: BrowserBridge {
        let inner = WebViewBridge()
        private var failed = false

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }

        func isLoading(_ tab: BrowserTab) async throws -> Bool {
            guard failed else {
                failed = true
                throw BrowserBridgeError.scriptFailed(code: -3)
            }
            return try await inner.isLoading(tab)
        }
    }

    /// The fixture browser, where Stop comes while an act's lookup is out:
    /// the lookup answers as it would. It counts the acts sent after.
    @MainActor
    private final class StopsAtTheLookup: BrowserBridge {
        let inner = WebViewBridge()
        var stop: (@MainActor () -> Void)?
        private(set) var lookedUp = false
        private(set) var actsAfterStop = 0

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            let isLookup = javascript.contains(#""operation":"found""#)
            if lookedUp, javascript.contains("const expected"), !isLookup { actsAfterStop += 1 }
            let result = try await inner.run(javascript, in: tab)
            if !lookedUp, isLookup {
                lookedUp = true
                stop?()
            }
            return result
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A browser that cannot open a tab.
    @MainActor
    private final class RefusesToOpen: BrowserBridge {
        func openTab(_ url: URL) async throws -> BrowserTab { throw BrowserBridgeError.timedOut }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { false }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { "" }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String { #"{"stable":true}"# }
        func closeTab(_ tab: BrowserTab) async throws {}
    }

    /// A tab that stays on a blank page: it never lands on the web.
    @MainActor
    private final class StaysBlank: BrowserBridge {
        func openTab(_ url: URL) async throws -> BrowserTab { BrowserTab(windowID: "w", tabID: "t") }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { false }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            javascript == "document.readyState" ? "complete" : "about:blank\n1"
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String { #"{"stable":true}"# }
        func closeTab(_ tab: BrowserTab) async throws {}
    }

    /// The fixture browser, where one address lands on another, as a server
    /// redirect does.
    @MainActor
    private final class Redirects: BrowserBridge {
        let inner = WebViewBridge()
        private let from: URL
        private let to: URL

        init(from: String, to: String) {
            self.from = URL(string: from)!
            self.to = URL(string: to)!
        }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url == from ? to : url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
    }

    /// The fixture browser, running `script` in the page right before the
    /// first action script runs.
    @MainActor
    private final class AddsAtTheAct: BrowserBridge {
        let inner = WebViewBridge()
        private let script: String
        private(set) var added = false

        init(_ script: String) { self.script = script }

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if !added, javascript.contains("const expected") {
                added = true
                _ = try await inner.run(script, in: tab)
            }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
    }

    /// A fixture Sheet whose read back shows a formula.
    @MainActor
    private final class FormulaSheet: SheetDestination {
        private let inner = FixtureSheet()
        func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
            try await inner.create(title: title, made: made)
        }
        func paste(_ text: String, into sheet: URL) async throws { try await inner.paste(text, into: sheet) }
        func readBack(_ sheet: URL) async throws -> SheetReadBack {
            SheetReadBack(cells: try await inner.readBack(sheet).cells, holdsFormula: true)
        }
    }
}
