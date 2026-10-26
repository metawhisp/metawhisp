import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-09, review round 2 — in a real Chrome (headless, a profile of
/// its own, the fixture pages served from inside Chrome): what a secret
/// field — one the page marks secret by its structure — names as its lists,
/// however many it names, never reaches Jev, read in the observer's report,
/// the writer's excerpt and the bytes of every request to Jev; a total
/// around a frame, or a saved card, makes a payment; a page read in part is
/// acted on as it was shown. Skipped without Chrome.
final class ChromeSecrecyLiveTests: XCTestCase {

    // MARK: - Helpers

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look", terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// The bytes of every request the errand sent Jev from `start`, Jev
    /// answering DONE at once.
    @MainActor
    private func jevBytes(from start: String, _ world: ChromeWorld,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let jev = RecordedJev { _, _ in .answers(operation: "DONE") }
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: world.bridge, engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let sent = jev.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(sent.isEmpty, "\(record.eventLines)", file: file, line: line)
        return sent
    }

    /// The observer's report and the writer's excerpt, as the page gives
    /// them, unparsed.
    @MainActor
    private func readings(of address: String, _ world: ChromeWorld) async throws -> (tab: BrowserTab, report: String,
                                                                                      excerpt: String) {
        let tab = try await world.bridge.openTab(URL(string: address)!)
        try await world.waitUntilLoaded(tab)
        let report = try await world.bridge.run(ObserverScript.source, in: tab)
        let excerpt = try await world.bridge.run(ObserverScript.excerptSource(), in: tab)
        return (tab, report, excerpt)
    }

    // MARK: - A total around a frame (Claude review of I-09, kept 3)

    private static func engine(clicking name: String) -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            let target = request.candidates.first { $0.action.operation == .click && $0.action.target?.name == name }
            return ScriptedEngine.pick(target ?? request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 })
    }

    /// Clicks `name` once, rated irreversible, then is done.
    private static func engine(clickingOnce name: String) -> ScriptedEngine {
        let picked = Counter()
        return ScriptedEngine(choice: { request in
            if picked.value < 1, let target = request.candidates.first(where: {
                $0.action.operation == .click && $0.action.target?.name == name
            }) {
                picked.add()
                return ScriptedEngine.pick(target)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 })
    }

    /// The order button of a frame, the total in the page around it; the
    /// order button of the page, the total in a frame of it: no payment — a
    /// payment is a page that asks card details (owner decision of
    /// 2026-10-19) — asked about as any send, and ordered with the Yes.
    @MainActor
    func testATotalAroundAFrameOrInOneIsNoPaymentTheOrderGoesWithTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (start, name) in [("https://site-251.test/", "Zahlungspflichtig bestellen"),
                              ("https://site-251.test/reverse", "Jetzt bestellen")] {
            let hands = KeepsTheTab(world.bridge)
            let asked = Counter()
            let run = AgentRun(plan: try plan(start), errandID: UUID(),
                               collaborators: .init(bridge: hands, engine: Self.engine(clickingOnce: name),
                                                    writer: FakeWriter(), sheet: FixtureSheet(), confirm: { _ in
                                                        asked.add()
                                                        return .yes
                                                    }))
            let record = await run.run()
            XCTAssertFalse(record.events.contains(.handover(.payment, host: "site-251.test")), "\(name): \(record.eventLines)")
            XCTAssertEqual(asked.value, 1, "\(name): asked once")
            let page = try await world.look(try XCTUnwrap(hands.kept.first))
            let button = try XCTUnwrap(page.elements.first { $0.name == name }, name)
            let log = try await world.bridge.run("document.getElementById('log').textContent",
                                                 in: try XCTUnwrap(hands.kept.first).inFrame(button.frame))
            XCTAssertEqual(log, "ordered;", "\(name): ordered with the Yes: \(record.eventLines)")
        }
    }

    /// A total written with its currency's name beside a form sent by POST:
    /// a committing click there is no payment (Codex review 1 of I-09, P1-3
    /// read it as one; owner decision of 2026-10-19): asked about, and sent
    /// with the Yes.
    @MainActor
    func testATotalWrittenWithItsCurrencysNameIsNoPayment() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-251.test/euros")
        XCTAssertEqual(page.elements.first { $0.name == "Continue" }?.showsAmount, true)
        let hands = KeepsTheTab(world.bridge)
        let asked = Counter()
        let run = AgentRun(plan: try plan("https://site-251.test/euros"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: Self.engine(clickingOnce: "Continue"),
                                                writer: FakeWriter(), sheet: FixtureSheet(), confirm: { _ in
                                                    asked.add()
                                                    return .yes
                                                }))
        let record = await run.run()
        XCTAssertFalse(record.events.contains(.handover(.payment, host: "site-251.test")), "\(record.eventLines)")
        XCTAssertEqual(asked.value, 1, "asked once")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "ordered;", "sent with the Yes: \(record.eventLines)")
    }

    /// A total the page shows around a frame only as the frame is brought on
    /// screen for the press — after the Yes, after the look the Yes came on:
    /// no wall; the order goes with the Yes.
    @MainActor
    func testATotalThatComesAroundAFrameAtTheActIsNoWall() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let run = AgentRun(plan: try plan("https://site-251.test/late"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: Self.engine(clickingOnce: "Bestellen"),
                                                writer: FakeWriter(), sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        XCTAssertFalse(record.events.contains(.handover(.payment, host: "site-251.test")), "\(record.eventLines)")
        let tab = try XCTUnwrap(hands.kept.first)
        let page = try await world.look(tab)
        let button = try XCTUnwrap(page.elements.first { $0.name == "Bestellen" })
        let log = try await world.bridge.run("document.getElementById('log').textContent", in: tab.inFrame(button.frame))
        XCTAssertEqual(log, "ordered;", "ordered with the Yes: \(record.eventLines)")
    }

    // MARK: - Every list a secret field names (Codex review 1 of I-09, P1-2)

    /// A secret field — one that draws dots — that names eleven lists (by
    /// `aria-controls`, by `aria-owns`, and split between them), the eleventh
    /// a plain list of buttons holding document numbers: nothing of it in the
    /// report, the
    /// excerpt or Jev's bytes. Nor a box inside a secret field's list that a
    /// label outside it reports (GLM review of I-09, P1-3), nor an option
    /// nested deeper than fifty levels in one (Claude review of I-09, kept
    /// 13). An ordinary control is still offered.
    @MainActor
    func testEveryListASecretFieldNamesIsWithheldEverywhere() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let secrets = ["X1234567", "Y7654321", "Z1111111", "W2222222", "AB1234567", "Q9999999"]
        let (_, report, excerpt) = try await readings(of: "https://site-250.test/", world)
        for secret in secrets {
            XCTAssertFalse(report.contains(secret), "report: \(secret)")
            XCTAssertFalse(excerpt.contains(secret), "excerpt: \(secret)")
        }
        let page = try ObservedPage.decode(report)
        XCTAssertTrue(page.elements.contains { $0.name == "Search" }, "\(page.elements.map(\.name))")
        XCTAssertFalse(page.elements.contains { $0.name == "Keep this document" }, "reported as the box it stands for")
        let sent = try await jevBytes(from: "https://site-250.test/", world)
        for secret in secrets {
            XCTAssertFalse(sent.contains { $0.contains(secret) }, "Jev: \(secret)")
        }
        XCTAssertTrue(sent.allSatisfy { $0.contains("Search") })
    }

    /// A secret field — one that draws dots — that names more lists than any
    /// widget does: who owns what is unknown, the page is not checked whole,
    /// and the last list's numbers reach nobody (Codex review 1 of I-09,
    /// P1-2).
    @MainActor
    func testASecretFieldThatNamesTooManyListsLeavesWhoOwnsWhatUnknown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, report, excerpt) = try await readings(of: "https://site-250.test/many", world)
        XCTAssertFalse(report.contains("V3333333"))
        XCTAssertFalse(excerpt.contains("V3333333"))
        XCTAssertTrue(try ObservedPage.decode(report).truncated)
        let sent = try await jevBytes(from: "https://site-250.test/many", world)
        XCTAssertFalse(sent.contains { $0.contains("V3333333") })
    }

    /// Who a dropdown's options are of, however it names its list: twice
    /// (Claude review of I-09, kept 15), or as the eleventh it names — then
    /// its POST form goes with them (Codex review 1 of I-09, P1-2). One that
    /// names more than any widget does leaves its options unbound, and they
    /// are not offered.
    @MainActor
    func testADropdownsOptionsAreItsOwnHoweverItNamesItsList() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-250.test/")
        func named(_ name: String) throws -> ObservedElement {
            try XCTUnwrap(page.elements.first { $0.name == name }, name)
        }
        XCTAssertEqual(try named("Archived").listOf, try named("Status").index)
        XCTAssertEqual(try named("Pro").listOf, try named("Plan").index)
        XCTAssertEqual(try named("Pro").listForm?.method, "post")
        XCTAssertEqual(try named("Gold").listOf, try named("Tier").index, "however deep in its list")
        let (_, unbound) = try await world.open("https://site-250.test/claims")
        XCTAssertFalse(unbound.elements.contains { $0.name == "Large" }, "\(unbound.elements.map(\.name))")
    }

    /// A field whose suggestions come in the eleventh list it names, the
    /// first ten empty: the typing waits for them there, and sees them come
    /// (Codex review 1 of I-09, P1-2).
    @MainActor
    func testAFieldsSuggestionsAreReadInEveryListItNames() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-250.test/")
        let action = try page.action(.type, on: "Destination", payload: "Pa")
        let aim = try await world.outcome(ActionScript.aim(for: action, on: page), in: tab)
        XCTAssertEqual(aim.outcome, .aim)
        try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
        let bridge = world.bridge
        let typed = try await TrustedTyping.type(action, on: page, approval: nil,
                                                 read: { try? await bridge.run($0, in: tab) }, stopping: { false })
        XCTAssertEqual(typed, .typed(.init(held: true, suggests: true)))
        let listed = try await world.outcome(ActionScript.suggestions(action, on: page), in: tab)
        XCTAssertEqual(listed.outcome, .held, "Paris, in the eleventh list")
    }

    // MARK: - Review round 3, part A: lists, saved cards and pages read in part

    /// An errand from `start` whose engine picks `name` once when it is
    /// offered, then DONE: its record, and the names offered at each step.
    @MainActor
    private func errand(from start: String, clicking name: String? = nil, bridge: any BrowserBridge,
                        _ world: ChromeWorld) async throws -> (record: ErrandRecord, offered: [[String]]) {
        let offered = Requests()
        let picked = Counter()
        let engine = ScriptedEngine(choice: { request in
            _ = offered.add(request)
            if let name, picked.value == 0, let target = request.candidates.first(where: {
                $0.action.operation == .click && $0.action.target?.name == name
            }) {
                picked.add()
                return ScriptedEngine.pick(target)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        return (record, offered.all.map { $0.candidates.compactMap(\.action.target?.name) })
    }

    /// Decision 2 (Codex review 2, P1-2): a list one claimant names among
    /// more lists than anyone uses is no one's — an ordinary dropdown that
    /// claims it too does not make it its own: its option is not offered,
    /// and the POST form beside a total is never sent.
    @MainActor
    func testAListWhoseOtherClaimantOverflowedIsNoOnesToOffer() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, page) = try await world.open("https://site-261.test/claims")
        XCTAssertFalse(page.elements.contains { $0.name == "Large" }, "\(page.elements.map(\.name))")
        let hands = KeepsTheTab(world.bridge)
        let (record, offered) = try await errand(from: "https://site-261.test/claims", clicking: "Large",
                                                    bridge: hands, world)
        XCTAssertFalse(offered.joined().contains("Large"), "\(offered): \(record.eventLines)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "", "nothing ordered")
    }

    /// Claude review c8, #5: a saved card's last digits make the page take a
    /// payment, read where they stand — a code's word right after them, in
    /// the next region or the same text.
    @MainActor
    func testASavedCardIsAPaymentWhereverACodesWordStandsAfterIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for address in ["https://site-261.test/saved-card", "https://site-261.test/saved-card-code"] {
            let (_, page) = try await world.open(address)
            XCTAssertTrue(page.flags.paymentForm, "\(address): \(page.text)")
        }
    }

    /// Claude review c8, #3: a long page's text cut inside a number — a
    /// control whose name holds what the cut leaves ("4821" of "…Ticket
    /// 4821|37") reaches Jev as it is, and is clicked.
    @MainActor
    func testAControlHoldingWhatACutLeavesIsActedOnAsShown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (record, offered) = try await errand(from: "https://site-262.test/long", clicking: "Room 4821",
                                                 bridge: hands, world)
        XCTAssertTrue(offered.first?.contains("Room 4821") == true, "\(offered)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "room;", "\(record.eventLines)")
    }

    /// Claude review c8, #8: on a page with more words than a look reads,
    /// a control is offered as a person sees it — "Room 4821" — and the hands
    /// find it so, and click it.
    @MainActor
    func testAPageNotReadWholeIsActedOnAsItWasShown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (record, offered) = try await errand(from: "https://site-262.test/unread-long", clicking: "Room 4821",
                                                 bridge: hands, world)
        XCTAssertTrue(offered.first?.contains("Room 4821") == true, "\(offered)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "room;", "\(record.eventLines)")
    }

    /// The hands find a target as the report showed it — a button under a
    /// heading with a number in it (a frame beside it unread), a frame's
    /// button whose words hold a code its page shows, and an option of a
    /// dropdown whose name holds it: each is clicked. The unread frame is of
    /// a third site, so it can hold no twin of the frame button (Claude
    /// review c8, #21).
    @MainActor
    func testControlsBesideAnUnreadFrameAreActedOnAsShown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, logged) in [("Track package", "tracked;"), ("Copy 481920", "copied;"), ("Use it", "picked;")] {
            let hands = FailsTheReadAt("/unread", world.bridge)
            let (record, offered) = try await errand(from: "https://site-262.test/touched", clicking: name,
                                                        bridge: hands, world)
            XCTAssertTrue(offered.first?.contains(name) == true, "\(name): \(offered)")
            let tab = try XCTUnwrap(hands.kept.first)
            var log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
            if name != "Track package" {
                log = ""
                for frame in try await world.bridge.frames(of: tab).frames
                    where (try? await world.bridge.run("location.pathname", in: frame.tab)) == "/send" {
                    log = try await world.bridge.run("document.getElementById('log').textContent", in: frame.tab)
                }
            }
            XCTAssertEqual(log, logged, "\(name): \(record.eventLines)")
        }
    }

    /// A button beside a frame the step's look read, which the look at the act cannot read — an ad still
    /// loading, as an ad-heavy page's are: no wall (2026-10-16: every press beside a loading ad was the user's
    /// "sign-in"; owner decision of 2026-10-19: a payment is a page that asks card details, what a frame may show
    /// of a total is nothing to wait for). The click goes.
    @MainActor
    func testAFrameUnreadOnlyAtTheActIsNoWallThePressGoes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = FailsTheReadAt("/unread", world.bridge, from: 2)
        let picked = Counter()
        let engine = ScriptedEngine(choice: { request in
            if picked.value < 1, let target = request.candidates.first(where: {
                $0.action.operation == .click && $0.action.target?.name == "Track package"
            }) {
                picked.add()
                return ScriptedEngine.pick(target)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        let run = AgentRun(plan: try plan("https://site-262.test/touched"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        XCTAssertGreaterThan(hands.failed, 0, "the look at the act read no frame: \(record.eventLines)")
        XCTAssertFalse(record.events.contains { if case .handover = $0 { return true } else { return false } },
                       "\(record.eventLines)")
        // The frame the act's look could not read keeps the page's answer unread too: the record says so, the
        // page shows the press went.
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "tracked;", "\(record.eventLines)")
    }

    /// The same page, a press that needs the user's Yes, beside a frame no look at the act can read: it goes
    /// with the Yes — a total that frame may show names no payment (owner decision of 2026-10-19).
    @MainActor
    func testAnApprovedPressBesideAFrameUnreadAtTheActGoesWithTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = FailsTheReadAt("/unread", world.bridge, fails: { $0.isMultiple(of: 2) })
        let picked = Counter()
        let engine = ScriptedEngine(choice: { request in
            if picked.value < 1, let target = request.candidates.first(where: {
                $0.action.operation == .click && $0.action.target?.name == "Track package"
            }) {
                picked.add()
                return ScriptedEngine.pick(target)
            }
            return ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        }, irreversible: { _ in 0.9 })
        let run = AgentRun(plan: try plan("https://site-262.test/touched"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .yes }))
        let record = await run.run()
        XCTAssertFalse(record.events.contains { if case .handover = $0 { return true } else { return false } },
                       "\(record.eventLines)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                   in: try XCTUnwrap(hands.kept.first))
        XCTAssertEqual(log, "tracked;", "pressed with the Yes: \(record.eventLines)")
    }
}

/// ITER-076 I-09, review round 4, part A (I-09-r4.md, decision 4; Claude
/// review c9, #1): a row longer than its cut is acted on as it was shown.
extension ChromeSecrecyLiveTests {

    // MARK: - Decision 4: a row longer than its cut

    /// What Jev was sent, and the page's log, for an errand that clicks
    /// "Details" on `start` — every risk answered reversible — then is done.
    @MainActor
    private func clickingDetails(on start: String, _ world: ChromeWorld) async throws -> (sent: [String], log: String) {
        let jev = RecordedJev { asked, _ in
            guard asked.isStep else { return .answers() }
            guard asked.recentLabels.isEmpty else { return .answers(operation: "DONE") }
            return .answers(operation: "CLICK", target: asked.key(labelled: "Details"))
        }
        let hands = FailsTheReadAt("/none", world.bridge)
        let run = AgentRun(plan: try plan(start), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: jev.engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { _ in .no }))
        let record = await run.run()
        let tab = try XCTUnwrap(hands.kept.first, "\(record.eventLines)")
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        return (jev.bodies.map { String(decoding: $0, as: UTF8.self) }, log)
    }

    /// A row longer than the 80 characters it is cut to, beside a frame of
    /// another site: the row is cut as the hands cut it, and the row's button
    /// is clicked (Claude review c9, #1).
    @MainActor
    func testARowLongerThanItsCutIsStillActedOn() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (sent, log) = try await clickingDetails(on: "https://site-277.test/row", world)
        XCTAssertFalse(sent.isEmpty)
        XCTAssertEqual(log, "details;", "\(sent)")
    }

    /// An option of a made-up dropdown in a row longer than its cut at 80:
    /// who its dropdown is is read from the row cut as the hands cut it — the
    /// option is chosen (decision 4).
    @MainActor
    func testAnOptionOfADropdownInARowLongerThanItsCutIsStillChosen() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = FailsTheReadAt("/none", world.bridge)
        let (record, offered) = try await errand(from: "https://site-277.test/owner", clicking: "Use it", bridge: hands,
                                                 world)
        XCTAssertTrue(offered.first?.contains("Use it") == true, "\(offered)")
        let tab = try XCTUnwrap(hands.kept.first)
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "picked;", "\(record.eventLines)")
    }
}

/// ITER-076 I-09, round 7 (Claude review c11, #1): Jev sees what a person
/// sees — and a person sees dots where the page draws text as dots.
extension ChromeSecrecyLiveTests {

    /// Text a person sees only as dots — a key in a table's row, a button's
    /// words — is in no report, no request to Jev and no excerpt; the same
    /// kind of text drawn as it is reaches all three.
    @MainActor
    func testTextDrawnAsDotsNeverReachesJev() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (_, report, excerpt) = try await readings(of: "https://site-314.test/", world)
        let sent = try await jevBytes(from: "https://site-314.test/", world)
        for dotted in ["KEY-DOTS-7Q4M", "481920"] {
            XCTAssertFalse(report.contains(dotted), "report: \(dotted)")
            XCTAssertFalse(excerpt.contains(dotted), "excerpt: \(dotted)")
            XCTAssertFalse(sent.contains { $0.contains(dotted) }, "Jev: \(dotted)")
        }
        for shown in ["KEY-SHOWN-8R5N", "735102"] {
            XCTAssertTrue(report.contains(shown), "report: \(shown)")
            XCTAssertTrue(excerpt.contains(shown), "excerpt: \(shown)")
            XCTAssertTrue(sent.contains { $0.contains(shown) }, "Jev: \(shown)")
        }
    }

    /// ITER-076 brain, step 2: the reader's lines are the excerpt's words, in
    /// Chrome too — no text drawn as dots, no field's value, nothing someone
    /// wrote; the words a person reads are there, each block on its line.
    @MainActor
    func testTheReadersLinesHoldNoTextDrawnAsDotsNorAFieldsValue() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        var read: [String: (json: String, capture: ErrandModel.Capture)] = [:]
        for address in ["https://site-314.test/", "https://site-405.test/"] {
            let tab = try await world.bridge.openTab(URL(string: address)!)
            try await world.waitUntilLoaded(tab)
            let json = try await world.bridge.run(ObserverScript.blocksSource(limit: 12_000), in: tab)
            read[address] = (json, try XCTUnwrap(ErrandModel.Capture.decode(json), address))
        }
        let dots = try XCTUnwrap(read["https://site-314.test/"])
        XCTAssertEqual(dots.capture.blocks.first, .init(label: "main/:1", kind: "heading", text: "Access keys"))
        for dotted in ["KEY-DOTS-7Q4M", "481920"] { XCTAssertFalse(dots.json.contains(dotted), dotted) }
        for shown in ["KEY-SHOWN-8R5N", "735102"] {
            XCTAssertTrue(dots.capture.blocks.contains { $0.text.contains(shown) }, shown)
        }
        let secrets = try XCTUnwrap(read["https://site-405.test/"])
        for kept in ["PASS-SECRET-4051", "TYPED-VALUE-4052", "4111 1111 1111 1111", "4111111111111111",
                     "WRITTEN-NOTE-4053", "DOTS-SECRET-4054", "EDITED-TEXT-4055"] {
            XCTAssertFalse(secrets.json.contains(kept), kept)
        }
        XCTAssertTrue(secrets.capture.blocks.contains { $0.text == "PUBLIC-WORDS-4050 a joke a person can read" })
        XCTAssertTrue(secrets.capture.blocks.contains { $0.text == "PUBLIC-WORDS-4056 the last line" })
    }
}

/// A writer that keeps every excerpt it is given (ITER-076 I-09, review round
/// 3): what reached it, read by the test.
final class RecordingWriter: TextWriter, @unchecked Sendable {
    let name = "recording-writer"
    let worstCaseUSD = 0.002
    private let lock = NSLock()
    private var kept: [PageExcerpt] = []

    var excerpts: [PageExcerpt] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    func row(columns: [String], subgoal: AgentPlan.Subgoal, excerpt: PageExcerpt) async throws -> WriterRow {
        lock.lock()
        kept.append(excerpt)
        lock.unlock()
        return WriterRow(cells: columns.map { _ in "row" }, usage: EngineUsage(costUSD: 0.001))
    }
}

/// The agent's hands in Chrome, whose look into a frame at `path` fails, as a
/// frame's script that threw does; the tab is kept open when the errand ends.
@MainActor
final class FailsTheReadAt: WrapsChromeBridge {
    let inner: ChromeBridge
    let path: String
    /// The first read of that frame that fails, from 1: every one by default.
    let from: Int
    /// Which reads of that frame fail, from 1, when given — in place of `from` (2026-10-18: an ad-heavy page's frame
    /// read at each step's look and still loading at each act).
    let fails: ((Int) -> Bool)?
    private var reads = 0
    private(set) var failed = 0
    private(set) var kept: [BrowserTab] = []

    init(_ path: String, _ inner: ChromeBridge, from: Int = 1, fails: ((Int) -> Bool)? = nil) {
        self.path = path
        self.inner = inner
        self.from = from
        self.fails = fails
    }

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
    func closeTab(_ tab: BrowserTab) async throws { kept.append(tab) }
    func click(x: Double, y: Double, in tab: BrowserTab) async throws { try await inner.click(x: x, y: y, in: tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        if tab.frame != nil, javascript == ObserverScript.source,
           (try? await inner.run("location.pathname", in: tab)) == path {
            reads += 1
            if fails?(reads) ?? (reads >= from) {
                failed += 1
                throw BrowserBridgeError.scriptFailed(code: -3)
            }
        }
        return try await inner.run(javascript, in: tab)
    }
}
