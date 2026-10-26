import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 I-09, review round 2 — what an act on a control does, in a real
/// Chrome (headless, a profile of its own, the fixture pages served from
/// inside Chrome): an option whose click sends a POST form is judged as that
/// form's send; a native control inside a label for another control is
/// clicked as itself; the choice an option made after a Yes is read back on
/// its own dropdown. Skipped without Chrome.
final class ChromeActsLiveTests: XCTestCase {

    private func plan(_ start: String) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: "Look around the page", subgoals: [.init(description: "Look", terms: ["page"])],
                                searches: [URL(string: start)!], columns: ["Name"], sheetTitle: "Page",
                                rowsWanted: 1, emptyCell: "n/a"))
    }

    /// An engine that picks, in turn, the first candidate each of `picks`
    /// finds, then DONE, keeping every request; every act it is asked about
    /// is irreversible.
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
        }, irreversible: { _ in 0.9 })
        return (engine, requests)
    }

    private static func click(_ name: String) -> @Sendable (Candidate) -> Bool {
        { $0.action.operation == .click && $0.action.target?.name == name }
    }

    // MARK: - An option that sends its dropdown's POST form (Claude review of I-09, kept 14)

    /// An option of a dropdown in a POST form with no submit button, a total
    /// on the page: choosing it sends the form — asked about, and sent with
    /// the Yes (owner decision of 2026-10-19: a payment is a page that asks
    /// card details). The same dropdown in a form sent by its own button: a
    /// plain Yes, and choosing sends nothing.
    @MainActor
    func testAnOptionWhoseClickSendsItsDropdownsPostFormIsAskedAboutAndSent() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        for (name, paid) in [("Pro", true), ("5 seats", false)] {
            let hands = KeepsTheTab(world.bridge)
            let (engine, _) = Self.engine([Self.click(name)])
            let asked = Counter()
            let run = AgentRun(plan: try plan("https://site-252.test/"), errandID: UUID(),
                               collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                    sheet: FixtureSheet(), confirm: { _ in
                                                        asked.add()
                                                        return .yes
                                                    }))
            let record = await run.run()
            if paid {
                XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } }, "\(record.eventLines)")
                XCTAssertEqual(asked.value, 1, "asked once: \(record.eventLines)")
            } else {
                XCTAssertEqual(asked.value, 1, "\(record.eventLines)")
                XCTAssertEqual(record.steps.first?.operation, "click", "\(record.eventLines)")
                XCTAssertFalse(record.events.contains { if case .handover = $0 { true } else { false } },
                               "\(record.eventLines)")
            }
            let log = try await world.bridge.runInPage("document.getElementById('log').textContent",
                                                       in: try XCTUnwrap(hands.kept.first))
            XCTAssertEqual(log, paid ? "charged;" : "", "\(name): \(paid ? "sent with the Yes" : "nothing sent")")
        }
    }

    // MARK: - A native control inside a label for another (Claude review of I-09, kept 16)

    /// A button inside a label whose control is a radio, or another button:
    /// Chrome runs no label activation for a click on native interactive
    /// content — the button's own handler runs, the label's control is left
    /// as it was. Such a button is aimed at and clicked; a control of the
    /// page's own making there is still refused (site-221).
    @MainActor
    func testANativeButtonInsideALabelForAnotherControlIsClickedAsItself() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let (tab, page) = try await world.open("https://site-253.test/")
        for name in ["Edit", "+"] {
            let aim = try await world.outcome(ActionScript.aim(for: try page.action(.click, on: name), on: page), in: tab)
            XCTAssertEqual(aim.outcome, .aim, name)
            if aim.outcome == .aim {
                try await world.bridge.click(x: try XCTUnwrap(aim.x), y: try XCTUnwrap(aim.y), in: tab)
            }
        }
        let log = try await world.bridge.runInPage("document.getElementById('log').textContent", in: tab)
        XCTAssertEqual(log, "edit;plus;")
        let radio = try await world.bridge.runInPage("String(document.querySelector('[name=address]').checked)", in: tab)
        XCTAssertEqual(radio, "false", "the label's radio is left as it was")
        let (other, covered) = try await world.open("https://site-221.test/")
        let refused = try await world.outcome(ActionScript.aim(for: try covered.action(.click, on: "Archive"), on: covered),
                                              in: other)
        XCTAssertEqual(refused.outcome, .covered, "a control of the page's own making in a label for another")
    }

    // MARK: - A choice read back by its dropdown's identity (Claude review of I-09, kept 17)

    /// An option of a frame's dropdown, chosen with a Yes while the page adds
    /// a control of its own — every frame control's place in the look moves:
    /// the choice is read back on that dropdown, and kept as the errand's, so
    /// the option is not offered again while it shows.
    @MainActor
    func testAChoiceMadeAfterAYesIsReadBackOnItsOwnDropdown() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let (engine, requests) = Self.engine([Self.click("Archived")])
        let bridge = world.bridge
        let run = AgentRun(plan: try plan("https://site-254.test/"), errandID: UUID(),
                           collaborators: .init(bridge: hands, engine: engine, writer: FakeWriter(),
                                                sheet: FixtureSheet(), confirm: { request in
                                                    _ = try? await bridge.runInPage(
                                                        "const added = document.createElement('button'); "
                                                            + "added.type = 'button'; added.textContent = 'Undo'; "
                                                            + "document.querySelector('main').prepend(added); 'x'",
                                                        in: request.tab)
                                                    return .yes
                                                }))
        let record = await run.run()
        XCTAssertEqual(record.events.filter { if case .question = $0 { true } else { false } }.count, 1,
                       "\(record.eventLines)")
        XCTAssertGreaterThanOrEqual(requests.all.count, 2, "\(record.eventLines)")
        guard requests.all.count >= 2 else { return }
        let offered = requests.all[1].candidates.compactMap { $0.action.target?.name }
        XCTAssertTrue(offered.contains("Active"), "\(offered)")
        XCTAssertFalse(offered.contains("Archived"), "chosen there and still shown: \(offered)")
    }
}
