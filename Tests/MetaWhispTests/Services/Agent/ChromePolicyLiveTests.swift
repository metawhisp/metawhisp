import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-09, review round 3, part C — a page's own dialogs, the payment
/// policy and the act, in a real Chrome (headless, a profile of its own, the
/// fixture pages served from inside Chrome): a dialog is OK'd only for the
/// act the user said Yes to and never once it names, or shows, what the
/// user did not see; the agent never pays; the press goes where the last
/// check looked; a Yes taken back is taken back at the wire. Skipped without
/// Chrome.
final class ChromePolicyLiveTests: XCTestCase {

    // MARK: - Helpers

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

    private static func on(_ operation: AgentOperation, _ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == operation && $0.action.target?.name == name }
    }

    private static let waits: @Sendable (Candidate) -> Bool = { $0.action.operation == .wait }

    @MainActor
    private func run(_ world: ChromeWorld, from start: String, engine: ScriptedEngine, bridge: any BrowserBridge,
                     confirm: @escaping @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
                        = { _ in .yes }) async throws -> ErrandRecord {
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: confirm))
        return await run.run()
    }

    /// The page's own log, in its own world — what it did.
    @MainActor
    private func pageLog(_ tab: BrowserTab, _ bridge: ChromeBridge) async throws -> String {
        try await bridge.runInPage("document.getElementById('log').textContent", in: tab)
    }

    /// The page's log once it holds `count` entries, or as it is after 10 s.
    @MainActor
    private func pageLog(_ tab: BrowserTab, _ bridge: ChromeBridge, entries count: Int) async throws -> String {
        var log = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            log = try await pageLog(tab, bridge)
            if log.split(separator: ";").count >= count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return log
    }

    private static func isDialog(_ event: ErrandRecord.Event) -> Bool {
        if case .dialog = event { true } else { false }
    }

    /// A person's click on the control the page names `name`.
    @MainActor
    private func press(_ name: String, on page: ObservedPage, in tab: BrowserTab, _ world: ChromeWorld) async throws {
        let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim, name)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
    }

    // MARK: - Decision 3: a dialog that names its payment in any form of the word

    /// The user's Yes for "Renew", whose page then confirms, in words the
    /// control shares, a charge of the saved card — "Renew by charging the
    /// saved card?": OK, as any confirm bound to the approved act (owner
    /// decision of 2026-10-19: a payment is a page that asks card details,
    /// which no dialog's words are), and the errand goes on. The dialog's
    /// words are kept nowhere.
    @MainActor
    func testAConfirmThatNamesAChargeInTheActsOwnWordsIsOKUnderTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, logged) in [("Renew", "charged;"), ("Renew now", "billed;")] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let record = try await run(world, from: "https://site-267.test/", engine: engine, bridge: hands)
            XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: true)],
                           "\(name): \(record.eventLines)")
            XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } },
                           "\(name): \(record.eventLines)")
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
            XCTAssertEqual(log, logged, name)
            XCTAssertFalse(record.eventLines.contains { $0.contains("saved card") }, "the dialog's words are kept nowhere")
        }
    }

    // MARK: - Decision 11: a number the control did not show; the act's own word; the act's own form

    /// The user's Yes for a renewal whose page then confirms a price in the
    /// letters its currency is printed in — a number the approved control
    /// never showed — or confirms another act that shares a word with the
    /// approved one, or the act of the form's other button: Cancel, and the
    /// step fails honestly (Claude review c8 of I-09, #9, #11, #12).
    @MainActor
    func testAConfirmTheApprovedControlDidNotShowIsCancelAndTheStepFails() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let renew = "\u{041F}\u{0440}\u{043E}\u{0434}\u{043B}\u{0438}\u{0442}\u{044C}"
        let cases = [("F\u{00F6}rnya", "not renewed;"), (renew, "not extended;"), ("Obnovi", "not renewed;"),
                     ("Remove item", "not sent;"), ("Archive", "not sent to all;")]
        for (name, logged) in cases {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let asked = Counter()
            let record = try await run(world, from: "https://site-267.test/", engine: engine, bridge: hands,
                                       confirm: { _ in
                asked.add()
                return .yes
            })
            XCTAssertEqual(asked.value, 1, "\(name): \(record.eventLines)")
            XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)],
                           "\(name): \(record.eventLines)")
            XCTAssertEqual(record.steps.first?.outcome, .failed, "\(name): \(record.eventLines)")
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
            XCTAssertEqual(log, logged, name)
        }
    }

    // MARK: - Claude c8 #15: a declined confirm outlasts a flood of alerts

    /// The user's Yes for "Archive all", whose page confirms another act —
    /// Cancel — then shows more alerts than the tab keeps: the step still
    /// fails, and the confirm not accepted is on record.
    @MainActor
    func testAConfirmDeclinedBeforeAFloodOfAlertsStillFailsTheStep() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Archive all")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-267.test/", engine: engine, bridge: hands)
        XCTAssertEqual(record.steps.first?.outcome, .failed, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "not sent to all;done;")
    }

    // MARK: - Claude c8 #16, #26: the Yes is the act's document's

    /// Under the Yes for "Delete" in the page, a widget of another site asks
    /// on its own: Cancel, and the Yes is not spent — the page's own confirm
    /// about the act is OK'd after it.
    @MainActor
    func testAWidgetsConfirmIsNeverAnsweredUnderThePagesYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-267.test/framed")
        world.bridge.approve(ApprovedAct(words: ["Delete"]), in: tab)
        try await press("Delete", on: page, in: tab, world)
        let log = try await pageLog(tab, world.bridge, entries: 2)
        XCTAssertEqual(log, "widget cancel;deleted;")
    }

    // MARK: - Decision 4: the press goes where the last check looked

    /// The user's Yes for "Archive" on a page with a frame; while the agent
    /// looks at the page once more before the press, the page swaps
    /// "Archive" and "Delete everything": the press never lands on "Delete
    /// everything" (Codex review 2 of I-09, P1-4; Claude review c8, #18).
    @MainActor
    func testThePressGoesWhereTheLastCheckLooked() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheLastLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("swap(), 'swapped'", in: tab)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Archive")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-269.test/", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "the page changed during the last look: \(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertFalse(log.contains("deleted"), "\(log) \(record.eventLines)")
    }

    /// The user's Yes for an order whose button the page pushes off screen
    /// while the agent looks once more before the press, and whose total
    /// shows only when the page is scrolled there: the point measured after
    /// the look is not where the look checked, and nothing is pressed.
    @MainActor
    func testAPressNeverGoesWhereTheLastCheckDidNotLook() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheLastLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("push(), 'pushed'", in: tab)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Bestellen")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-270.test/moving", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "", "never ordered: \(record.eventLines)")
    }

    // MARK: - Claude c8 #14, #25: what the last look sees stops the press

    /// While the agent looks at the page once more before the press, the
    /// page asks, in its own dialog, for a payment — "Pay EUR 5 now?" —
    /// before the Yes is armed: Cancel, as any confirm then is, and the
    /// user's part of no one (owner decision of 2026-10-19: a dialog's words
    /// name no payment); the act the Yes was for goes.
    @MainActor
    func testAChargeAskedForInADialogDuringTheLastLookIsCancelAndNoOnesPart() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheLastLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("setTimeout(() => confirm('Pay EUR 5 now?'), 0), 'asked'", in: tab)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Archive")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-269.test/", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "the act went: \(record.eventLines)")
    }

    /// While the agent looks at the page once more before the press, the
    /// page asks a confirm of its own — before the Yes is armed, so Cancel:
    /// the act that then goes out and changes the page did not fail.
    @MainActor
    func testAConfirmDeclinedDuringTheLastLookIsNoFailureOfTheAct() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheLastLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("setTimeout(() => confirm('Are you sure?'), 0), 'asked'", in: tab)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Archive")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-269.test/", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .confirmed, "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "archived;")
    }

    /// While the agent looks at the page once more before the press, a
    /// widget of another site shows its sign-in: the button in it is the
    /// user's part, and nothing is pressed.
    @MainActor
    func testASignInShownDuringTheLastLookIsTheUsersPart() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheLastLook(world.bridge) { bridge, tab in
            guard let widget = try? await bridge.frames(of: tab).frames.first(where: { $0.identity.contains("site-256") })
            else { return }
            _ = try? await bridge.run("document.getElementById('signin').hidden = false, 'shown'", in: widget.tab)
        }
        let (engine, _) = Self.engine([Self.on(.click, "Continue")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-255.test/signin", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.signIn, host: "site-255.test")), "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let listing = try await world.bridge.frames(of: tab)
        let widget = try XCTUnwrap(listing.frames.first { $0.identity.contains("site-256") })
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: widget.tab)
        XCTAssertEqual(log, "", "never pressed")
    }

    // MARK: - Claude c8 #19, #20, #24: a total or a card anywhere on the page

    /// A saved card the page shows, outside the order's frame, as the act
    /// scrolls to the order: the look at the act reads the whole page's card
    /// evidence, and the press never goes out (Claude review c8 of I-09,
    /// #24).
    @MainActor
    func testACardTheActBringsAnywhereOnThePageStopsThePress() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Bestellen")], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-270.test/late-card", engine: engine, bridge: hands)
        XCTAssertTrue(record.events.contains(.handover(.payment, host: "site-270.test")), "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "", "never ordered")
    }

    // MARK: - Claude c8 #21: a twin in a frame the look did not read

    /// The same widget in each of three rows, two of whose frames the look
    /// could not read: the one read may have a twin there, and is never
    /// offered (Claude review c8 of I-09, #21).
    @MainActor
    func testAControlWhoseTwinMayStandInAFrameNotReadIsNeverOffered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = MissesFrameReads(world.bridge) { identities in
            let widgets = identities.indices.filter { identities[$0].contains("site-256") }
            return Set(widgets.dropLast())
        }
        let (engine, requests) = Self.engine([Self.waits, Self.waits, Self.waits])
        let record = try await run(world, from: "https://site-255.test/team-widget", engine: engine, bridge: hands,
                                   confirm: { _ in .no })
        XCTAssertGreaterThan(hands.missed, 0, "\(record.eventLines)")
        XCTAssertGreaterThanOrEqual(requests.all.count, 2, "\(record.eventLines)")
        XCTAssertFalse(requests.all.contains { $0.candidates.contains { $0.action.target?.name == "Remove member" } },
                       "never offered: \(record.eventLines)")
    }

    /// The same widget in each of three rows, two of whose frames are not
    /// listed at all — not running yet, their setup failed — though the page
    /// holds them: the one listed may have a twin there, and is never
    /// offered (Claude review c8 of I-09, #21).
    @MainActor
    func testAControlBesideAFrameNeverListedIsNeverOffered() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = HidesFrames(world.bridge) { identities in
            let widgets = identities.indices.filter { identities[$0].contains("site-256") }
            return Set(widgets.dropLast())
        }
        let (engine, requests) = Self.engine([Self.waits, Self.waits])
        let record = try await run(world, from: "https://site-255.test/team-widget", engine: engine, bridge: hands,
                                   confirm: { _ in .no })
        XCTAssertGreaterThan(hands.hidden, 0, "\(record.eventLines)")
        XCTAssertFalse(requests.all.contains { $0.candidates.contains { $0.action.target?.name == "Remove member" } },
                       "never offered: \(record.eventLines)")
    }

    // MARK: - Claude c8 #23: a priced switch of no form

    // MARK: - Decision 5: the permit is checked at the wire

    /// The page's confirm about the approved act is decided OK, and its
    /// answer is held right before it is handed to the socket; Stop comes
    /// there, then the answer goes: what goes out is Cancel, and nothing is
    /// deleted (Codex review 2 of I-09, P1-5).
    @MainActor
    func testAYesTakenBackBeforeTheAnswerReachesTheWireSendsCancel() async throws {
        let chrome = try await TestChrome.launch()
        let proxy = try await CDPProxy.start(to: chrome.endpoint.webSocketURL)
        let stop = StopHolder()
        let connection = CDPConnection(url: proxy.url, beforeWrite: { method in
            guard method == "Page.handleJavaScriptDialog" else { return }
            await stop.fire()
        })
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
        let hands = KeepsTheTab(bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Delete")], irreversible: { _ in 0.9 })
        let run = AgentRun(plan: try plan("https://site-207.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        stop.action = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(stop.fired, 1, "the answer was held at the wire, and Stop came there")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), bridge, entries: 1)
        XCTAssertEqual(log, "kept;", "Cancel went out")
        let answers = proxy.messages.filter { $0.contains("\"Page.handleJavaScriptDialog\"") }
        XCTAssertEqual(answers.count, 1, "\(answers)")
        XCTAssertFalse(answers.contains { $0.contains("\"accept\":true") }, "\(answers)")
    }

    // MARK: - Review round 4, decision 13: the socket's queue holds the answer before it is made

    /// The page's confirm about the approved act is decided OK, and its
    /// answer is handed to the socket, whose queue is held right before the
    /// answer's message is made; Stop comes there, then the queue goes on:
    /// what goes out is Cancel, and nothing is deleted (Codex review 3 of
    /// I-09, P2-2).
    @MainActor
    func testAYesTakenBackWhileTheSocketHoldsTheAnswerSendsCancel() async throws {
        let chrome = try await TestChrome.launch()
        let proxy = try await CDPProxy.start(to: chrome.endpoint.webSocketURL)
        let stop = StopHolder()
        let connection = CDPConnection(url: proxy.url, onTheSocketQueue: { method in
            guard method == "Page.handleJavaScriptDialog" else { return }
            // The socket's queue waits here until Stop has run, or 10 s.
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                stop.fire()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
        })
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
        let hands = KeepsTheTab(bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Delete")], irreversible: { _ in 0.9 })
        let run = AgentRun(plan: try plan("https://site-207.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        stop.action = { run.stop() }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(stop.fired, 1, "the answer was held on the socket's queue, and Stop came there")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), bridge, entries: 1)
        XCTAssertEqual(log, "kept;", "Cancel went out")
        let answers = proxy.messages.filter { $0.contains("\"Page.handleJavaScriptDialog\"") }
        XCTAssertEqual(answers.count, 1, "\(answers)")
        XCTAssertFalse(answers.contains { $0.contains("\"accept\":true") }, "\(answers)")
    }

    // MARK: - Review round 4, decision 8: grant and payment words inside words and in every form

    /// The user's Yes for a control whose page then confirms, in words the
    /// control shares, a grant named inside a word or by another form of it
    /// — giving access, sharing with, preauthorize, permission: Cancel, the
    /// errand ends at the user's part, and the page did nothing (Codex
    /// review 3 of I-09, P1-3; Claude review c9, #12). A payment word inside
    /// a word — prepaid, autopay — names no one's part: the confirm is OK.
    @MainActor
    func testAConfirmThatNamesAGrantOrAPaymentInsideAWordIsCancelAndHandedOver() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let cases: [(String, String, ErrandHandover.Kind?, String)] = [
            ("/giving", "Renew", .grant, "not granted;"), ("/sharing", "Renew", .grant, "not granted;"),
            ("/prepaid", "Renew", nil, "paid;"), ("/autopay", "Turn on autopay", nil, "paid;"),
            ("/preauthorize", "Preauthorize renewal", .grant, "not granted;"), ("/permission", "Post", .grant, "not granted;"),
        ]
        for (path, name, kind, logged) in cases {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let record = try await run(world, from: "https://site-283.test" + path, engine: engine, bridge: hands)
            if let kind {
                XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)],
                               "\(path): \(record.eventLines)")
                XCTAssertEqual(record.ending, .needsUser, "\(path): \(record.eventLines)")
                XCTAssertTrue(record.events.contains(.handover(kind, host: "site-283.test")), "\(path): \(record.eventLines)")
            } else {
                // A payment word inside a word names no one's part (owner decision of 2026-10-19): the confirm,
                // bound to the act's own words, is OK under the Yes.
                XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: true)],
                               "\(path): \(record.eventLines)")
                XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } },
                               "\(path): \(record.eventLines)")
            }
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
            XCTAssertEqual(log, logged, path)
        }
    }

    // MARK: - Review round 4, decision 9: binding per sentence, by acts in an act's position

    /// The user's Yes for "Remove", "Delete" or "Send", whose page then
    /// confirms another act in a sentence of its own, another act of leaving
    /// or undoing, or the act's own word only as a thing: Cancel, and the
    /// step fails honestly (Claude review c9 of I-09, #11).
    @MainActor
    func testAConfirmThatNamesAnotherActInAnySentenceIsCancel() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let cases = [("/sentences", "Remove", "not sent;"), ("/unsubscribe", "Delete", "not unsubscribed;"),
                     ("/limit", "Send", "not upgraded;")]
        for (path, name, logged) in cases {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, name)], irreversible: { _ in 0.9 })
            let asked = Counter()
            let record = try await run(world, from: "https://site-283.test" + path, engine: engine, bridge: hands,
                                       confirm: { _ in
                asked.add()
                return .yes
            })
            XCTAssertEqual(asked.value, 1, "\(path): \(record.eventLines)")
            XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)],
                           "\(path): \(record.eventLines)")
            XCTAssertEqual(record.steps.first?.outcome, .failed, "\(path): \(record.eventLines)")
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
            XCTAssertEqual(log, logged, path)
        }
    }

    // MARK: - Review round 4, decision 10: what a dialog named is on record when it is decided

    /// The user's Yes for a box in the page; as the agent aims, a widget of
    /// another site — in a process of its own, so the page's aim still
    /// answers — asks for a grant, and its answer is held before it reaches
    /// the wire: what the dialog named is on record already, the errand ends
    /// at the user's part and nothing is pressed (Claude review c9 of I-09,
    /// #13, #15).
    @MainActor
    func testAWidgetsGrantAskedDuringTheAimEndsTheErrandWhileItsAnswerIsHeld() async throws {
        let chrome = try await TestChrome.launch()
        let release = Latch()
        let held = Counter()
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL, beforeWrite: { method in
            guard method == "Page.handleJavaScriptDialog" else { return }
            held.add()
            // Held until the errand has ended, or for 8 s at most.
            for _ in 0..<160 where !release.isOpen { try? await Task.sleep(for: .milliseconds(50)) }
        })
        try await connection.open()
        let fixtures = ChromeFixtures(connection: connection)
        await fixtures.start()
        let bridge = ChromeBridge(connection: connection, prepareTab: { try await fixtures.serve($0) },
                                  resolve: ChromeFixtures.resolve)
        defer {
            release.open()
            fixtures.stop()
            Task { await connection.close() }
            chrome.quit()
        }
        let hands = ActsAtTheLastLook(bridge, atTheFirstAim: true) { bridge, tab in
            _ = try? await bridge.runInPage("askGrant(), 'asked'", in: tab)
            try? await Task.sleep(for: .milliseconds(600))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Archive")], irreversible: { _ in 0.9 })
        let run = AgentRun(plan: try plan("https://site-285.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        release.open()
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertEqual(held.value, 1, "the widget's answer was held at the wire: \(record.eventLines)")
        XCTAssertTrue(record.events.contains(.handover(.grant, host: "site-285.test")), "\(record.eventLines)")
        // The Cancel is on record beside what the dialog named, though its
        // answer was still held when the errand ended (round 5; Claude review
        // c10, #12).
        XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)], "\(record.eventLines)")
        XCTAssertTrue(record.steps.isEmpty, "nothing sent: \(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), bridge, entries: 1)
        XCTAssertEqual(log, "widget cancel;", "never pressed, and the widget's ask was Cancel")
    }

    // MARK: - Review round 4, decision 12: the re-look at the act reads what the act's aim sees

    // MARK: - Review round 4, decision 13: frames a look leaves unread, and what is read before the act goes

    /// The user's Yes for opening "Upgrade"; as the agent reads where the
    /// tab is, right before the address goes out, the page asks, in its own
    /// dialog, for a payment: Cancel — before the Yes is armed — and no
    /// one's part (owner decision of 2026-10-19); the address then opens
    /// (Claude review c9 of I-09, #18: an act sent by script).
    @MainActor
    func testAChargeAskedForRightBeforeAnOpenIsCancelAndTheAddressGoes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let picked = Latch()
        let hands = ActsAtTheMarker(world.bridge, after: picked) { bridge, tab in
            _ = try? await bridge.runInPage("setTimeout(() => confirm('Pay EUR 5 now?'), 0), 'asked'", in: tab)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let opens: @Sendable (Candidate) -> Bool = { candidate in
            guard candidate.action.operation == .open, candidate.action.target?.name == "Upgrade" else { return false }
            picked.open()
            return true
        }
        let (engine, _) = Self.engine([opens], irreversible: { _ in 0.9 })
        let record = try await run(world, from: "https://site-287.test/start", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertTrue(record.steps.contains { $0.operation == "open" }, "the address went: \(record.eventLines)")
        let address = try await world.bridge.runInPage("location.href", in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(address, "https://site-287.test/upgraded", "opened with the Yes")
    }

    /// After a link to the next page, back to where the errand began; as the
    /// agent reads where the tab is, right before it goes back, the page asks
    /// for a payment: Cancel, the errand ends at the user's payment, and the
    /// tab never goes back (Claude review c9 of I-09, #18: back).
    @MainActor
    func testAChargeAskedForRightBeforeBackIsCancelAndBackGoes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let picked = Latch()
        let hands = ActsAtTheMarker(world.bridge, after: picked) { bridge, tab in
            _ = try? await bridge.runInPage("setTimeout(() => confirm('Pay EUR 5 now?'), 0), 'asked'", in: tab)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let goesBack: @Sendable (Candidate) -> Bool = { candidate in
            guard candidate.action.operation == .back else { return false }
            picked.open()
            return true
        }
        let (engine, _) = Self.engine([Self.on(.open, "Next"), goesBack])
        let record = try await run(world, from: "https://site-287.test/start", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertTrue(record.events.contains(.dialog(.confirm, accepted: false)), "\(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
        XCTAssertEqual(Array(record.steps.map(\.operation).prefix(2)), ["open", "back"], "\(record.eventLines)")
        let address = try await world.bridge.runInPage("location.href", in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(address, "https://site-287.test/start", "went back")
    }

    // MARK: - Round 5, Claude review c10, #13: the Yes is the document's, not only the frame's

    /// The user's Yes for "Delete", which asks nothing itself and loads the
    /// next page; that page asks a bare confirmation as it loads, in the same
    /// frame: another document, never answered under the Yes — Cancel.
    @MainActor
    func testABareConfirmOfThePageTheApprovedClickLoadedIsCancel() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, _) = Self.engine([Self.on(.click, "Delete")], irreversible: { _ in 0.9 })
        let asked = Counter()
        let record = try await run(world, from: "https://site-302.test/", engine: engine, bridge: hands,
                                   confirm: { _ in
            asked.add()
            return .yes
        })
        XCTAssertEqual(asked.value, 1, "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        try await world.waitUntilPageIs("/next complete", in: tab)
        let log = try await pageLog(tab, world.bridge, entries: 1)
        XCTAssertEqual(log, "not continued;", "the next page's confirm was Cancel")
        XCTAssertEqual(record.events.filter(Self.isDialog), [.dialog(.confirm, accepted: false)], "\(record.eventLines)")
    }

    /// The Yes for an act in a frame of another site, a process of its own:
    /// that frame's own confirm is its document's, and OK'd once — the
    /// document a frame holds is known in every process.
    @MainActor
    func testTheYesForAnActInAFrameOfAnotherSiteAnswersThatFramesConfirm() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, _) = try await world.open("https://site-267.test/framed")
        let listing = try await world.bridge.frames(of: tab)
        let widget = try XCTUnwrap(listing.frames.first { $0.identity.contains("site-268") })
        world.bridge.approve(ApprovedAct(words: ["Comments"], frame: widget.tab.frame), in: tab)
        _ = try await world.bridge.runInPage("document.querySelector('iframe').contentWindow.postMessage('ask', '*'), 'x'",
                                             in: tab)
        let log = try await pageLog(tab, world.bridge, entries: 1)
        XCTAssertEqual(log, "widget ok;")
    }

    // MARK: - Round 5, Claude review c10, #14: a select and an open get the look at the act

    /// The same select and link; the page frames its total only once the
    /// act's lookup found none, right before the act goes: the act finds a
    /// frame no check read, and nothing goes — the step is gone.
    @MainActor
    func testATotalFramedRightBeforeASelectOrAnOpenGoesMakesItGone() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (path, operation, name) in [("/select", AgentOperation.select, "Tarif"), ("/open", .open, "Bestellen")] {
            let picked = Latch()
            let hands = ActsAtTheMarker(world.bridge, after: picked) { bridge, tab in
                _ = try? await bridge.runInPage("addTotal(), 'added'", in: tab)
                try? await Task.sleep(for: .milliseconds(800))
            }
            let pick: @Sendable (Candidate) -> Bool = { candidate in
                guard candidate.action.operation == operation, candidate.action.target?.name == name,
                      operation != .select || candidate.action.payload == "Jaehrlich" else { return false }
                picked.open()
                return true
            }
            let (engine, _) = Self.engine([pick], irreversible: { _ in 0.05 })
            let record = try await run(world, from: "https://site-301.test" + path, engine: engine, bridge: hands)
            XCTAssertTrue(hands.acted, "\(path): \(record.eventLines)")
            XCTAssertEqual(record.steps.first?.outcome, .gone, "\(path): \(record.eventLines)")
            let tab = try XCTUnwrap(hands.kept.first)
            let address = try await world.bridge.runInPage("location.href", in: tab)
            XCTAssertEqual(address, "https://site-301.test" + path, "never opened: \(path)")
            let log = try await pageLog(tab, world.bridge)
            XCTAssertEqual(log, "", "never ordered: \(path)")
        }
    }

    // MARK: - Round 5, Claude review c10, #15: only a submit button a person can press sends a change

    // MARK: - Round 5, Claude review c10, #16: the aim after the look at the act is read

    /// The same order beside its own frame; as the agent aims after the look
    /// at the act, the page brings frames no one sees — not shown, as an
    /// ad-heavy page keeps bringing them: they show no total to anyone, so
    /// the press goes. Counted, every press on such a page was gone, the
    /// next look met newer ones, and the errand stuck (2026-10-16). A frame
    /// shown still stops it (the test below).
    @MainActor
    func testFramesNoOneSeesBroughtAsTheAgentAimsLeaveThePressToGo() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheAimAfterTheLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("addHiddenFrame(), addHiddenFrame(), 'added'", in: tab)
            try? await Task.sleep(for: .milliseconds(800))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Bestellen")], irreversible: { _ in 0.05 })
        let record = try await run(world, from: "https://site-301.test/framed", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        // The press went: the order is in the page's log. Its page shows nothing new, which its check reads
        // as a step that did nothing — not a step that never went.
        XCTAssertNotEqual(record.steps.first?.outcome, .gone, "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "ordered;", "\(record.eventLines)")
    }

    /// An order Jev rates reversible, beside a frame of the page's own, so
    /// the page and its frames are looked at once more before the press; as
    /// the agent aims after that look, the page frames its total: the aim
    /// counts a frame the look did not read, the press never goes, and the
    /// step is gone.
    @MainActor
    func testAFrameBroughtAsTheAgentAimsAfterTheLookStopsThePress() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = ActsAtTheAimAfterTheLook(world.bridge) { bridge, tab in
            _ = try? await bridge.runInPage("addTotal(), 'added'", in: tab)
            try? await Task.sleep(for: .milliseconds(800))
        }
        let (engine, _) = Self.engine([Self.on(.click, "Bestellen")], irreversible: { _ in 0.05 })
        let record = try await run(world, from: "https://site-301.test/framed", engine: engine, bridge: hands)
        XCTAssertTrue(hands.acted, "\(record.eventLines)")
        XCTAssertEqual(record.steps.first?.outcome, .gone, "\(record.eventLines)")
        let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
        XCTAssertEqual(log, "", "never ordered")
    }

    // MARK: - Round 7, Claude review c11, #3: a card's detail marked secret is a card's by its words

    /// A checkout whose card detail the page marks secret by its structure
    /// and names a card's only by its words — a security code typed as a
    /// password, a card number drawn as dots — while "Confirm" sends another
    /// form and the total stands beside the page's main content only: the
    /// page takes a payment, the step is handed over as one, never asked
    /// about, and nothing is paid after a Yes.
    @MainActor
    func testACardDetailMarkedSecretAndNamedByItsWordsMakesThePageAPayment() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for path in ["/cvv", "/dotted"] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.on(.click, "Confirm")])
            let asked = Counter()
            let record = try await run(world, from: "https://site-310.test" + path, engine: engine, bridge: hands,
                                       confirm: { _ in
                asked.add()
                return .yes
            })
            XCTAssertEqual(asked.value, 0, "\(path): \(record.eventLines)")
            XCTAssertTrue(record.events.contains(.handover(.payment, host: "site-310.test")),
                          "\(path): \(record.eventLines)")
            let log = try await pageLog(try XCTUnwrap(hands.kept.first), world.bridge)
            XCTAssertEqual(log, "", "never paid: \(path)")
        }
    }

    // MARK: - Round 7, Claude review c11, #11: a submit button no one can press still names its form

}

/// The agent's hands in Chrome, where the page acts — as `act` makes it —
/// once `after` has opened, the first time the agent runs an act's lookup or
/// reads where the tab is: right before an act sent by script, or its lookup
/// made alone, goes out (ITER-076 I-09, round 5, part C). It keeps every tab
/// it is asked to close.
@MainActor
final class ActsBeforeTheAct: WrapsChromeBridge {
    let inner: ChromeBridge
    private let after: Latch
    private let act: @MainActor (ChromeBridge, BrowserTab) async -> Void
    private(set) var kept: [BrowserTab] = []
    private(set) var acted = false

    init(_ inner: ChromeBridge, after: Latch, act: @escaping @MainActor (ChromeBridge, BrowserTab) async -> Void) {
        self.inner = inner
        self.after = after
        self.act = act
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if after.isOpen, !acted, javascript.contains("const expected") || javascript.contains("performance.timeOrigin") {
            acted = true
            await act(inner, tab.inFrame(nil))
        }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }
}

/// The agent's hands in Chrome, where the page acts — as `act` makes it —
/// as the agent aims for the first time after it has looked at the tab's
/// frames once it aimed: the aim made after the look at the act (ITER-076
/// I-09, round 5, part C). It keeps every tab it is asked to close.
@MainActor
final class ActsAtTheAimAfterTheLook: WrapsChromeBridge {
    let inner: ChromeBridge
    private let act: @MainActor (ChromeBridge, BrowserTab) async -> Void
    private(set) var kept: [BrowserTab] = []
    private var aims = 0
    private var looked = false
    private(set) var acted = false

    init(_ inner: ChromeBridge, act: @escaping @MainActor (ChromeBridge, BrowserTab) async -> Void) {
        self.inner = inner
        self.act = act
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"aim\"") {
            aims += 1
            if looked, !acted {
                acted = true
                await act(inner, tab.inFrame(nil))
            }
        }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func frames(of tab: BrowserTab) async throws -> FrameListing {
        if aims > 0 { looked = true }
        return try await inner.frames(of: tab)
    }
}

/// The agent's hands in Chrome, where the page acts — as `act` makes it —
/// the first time the agent reads where the tab is once `after` has opened:
/// right before an act sent by script, or back, goes out (ITER-076 I-09,
/// review round 4, part C). It keeps every tab it is asked to close.
@MainActor
final class ActsAtTheMarker: WrapsChromeBridge {
    let inner: ChromeBridge
    private let after: Latch
    private let act: @MainActor (ChromeBridge, BrowserTab) async -> Void
    private(set) var kept: [BrowserTab] = []
    private(set) var acted = false

    init(_ inner: ChromeBridge, after: Latch, act: @escaping @MainActor (ChromeBridge, BrowserTab) async -> Void) {
        self.inner = inner
        self.after = after
        self.act = act
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if after.isOpen, !acted, javascript.contains("performance.timeOrigin") {
            acted = true
            await act(inner, tab)
        }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }
}

/// Open once opened, read from any thread.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
}

/// The agent's hands in Chrome, where the page acts — as `act` makes it —
/// while an act is readied (ITER-076 I-09, review round 3, part C): the first
/// time the agent looks at the tab's frames after it has aimed — during the
/// look made once more right before a press — or, `atTheFirstAim`, as the
/// first aim is made, or, `atAim`, as that aim is made, counted from one
/// (review round 4, part C). It keeps every tab it is asked to close.
@MainActor
final class ActsAtTheLastLook: WrapsChromeBridge {
    let inner: ChromeBridge
    private let atAim: Int?
    private let act: @MainActor (ChromeBridge, BrowserTab) async -> Void
    private(set) var kept: [BrowserTab] = []
    private var aims = 0
    private(set) var acted = false

    init(_ inner: ChromeBridge, atTheFirstAim: Bool = false, atAim: Int? = nil,
         act: @escaping @MainActor (ChromeBridge, BrowserTab) async -> Void) {
        self.inner = inner
        self.atAim = atAim ?? (atTheFirstAim ? 1 : nil)
        self.act = act
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if javascript.contains("\"operation\":\"aim\"") {
            aims += 1
            if aims == atAim, !acted {
                acted = true
                await act(inner, tab.inFrame(nil))
            }
        }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func frames(of tab: BrowserTab) async throws -> FrameListing {
        if aims > 0, atAim == nil, !acted {
            acted = true
            await act(inner, tab)
        }
        return try await inner.frames(of: tab)
    }
}

/// The agent's hands in Chrome, whose listing of a tab's frames leaves out
/// the frames `hides` names among those it found — by their places in it,
/// given who each is — and does not count them: frames that do not run yet,
/// or whose setup failed. It keeps every tab it is asked to close.
@MainActor
final class HidesFrames: WrapsChromeBridge {
    let inner: ChromeBridge
    private let hides: ([String]) -> Set<Int>
    private(set) var kept: [BrowserTab] = []
    private(set) var hidden = 0

    init(_ inner: ChromeBridge, hides: @escaping ([String]) -> Set<Int>) {
        self.inner = inner
        self.hides = hides
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String { try await inner.run(javascript, in: tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func frames(of tab: BrowserTab) async throws -> FrameListing {
        var listing = try await inner.frames(of: tab)
        let chosen = hides(listing.frames.map(\.identity))
        hidden += chosen.count
        listing.frames = listing.frames.indices.filter { !chosen.contains($0) }.map { listing.frames[$0] }
        return listing
    }
}

/// The agent's hands in Chrome, where the frames `misses` names among those
/// a listing found — by their places in it, given who each is — cannot be
/// read: the observer's script fails there, as one in a frame that is going
/// does. It keeps every tab it is asked to close.
@MainActor
final class MissesFrameReads: WrapsChromeBridge {
    let inner: ChromeBridge
    private let misses: ([String]) -> Set<Int>
    private var unreadable: Set<String> = []
    private(set) var kept: [BrowserTab] = []
    private(set) var missed = 0

    init(_ inner: ChromeBridge, misses: @escaping ([String]) -> Set<Int>) {
        self.inner = inner
        self.misses = misses
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if let frame = tab.frame, javascript == ObserverScript.source, unreadable.contains(frame) {
            missed += 1
            throw BrowserBridgeError.scriptFailed(code: -3)
        }
        return try await inner.run(javascript, in: tab)
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func frames(of tab: BrowserTab) async throws -> FrameListing {
        let listing = try await inner.frames(of: tab)
        let chosen = misses(listing.frames.map(\.identity))
        unreadable = Set(chosen.compactMap { listing.frames[$0].tab.frame })
        return listing
    }
}
