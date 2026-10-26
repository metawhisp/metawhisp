import AppKit
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 6 — the Sheet of an answer errand, the owner's task №2: asked for a table, the errand's answer
/// also goes into a new Sheet — a header, then one row per item of the answer, its quote and its page's link — read
/// back and checked. Not asked, no Sheet. A Sheet that fails never takes the answer with it: the errand keeps its
/// ending and its answer, and the Sheet's failure is named beside them (P1-7). A Google sign-in on the way waits for
/// the user; at a ceiling what was collected is written (owner default 6.1); Stop closes the Sheet's tab and writes
/// nothing more. The app's own brain on one page of jokes, the reader resting r1 on its first three.
@MainActor
final class AgentRunSheetTests: XCTestCase {

    private static let goal = "Find 3 jokes"
    private static let start = URL(string: "https://site-404.test/")!
    private static let jokes = ["Joke 1: The calendar felt nervous because its days were numbered.",
                                "Joke 2: The bicycle fell over because it was two tired.",
                                "Joke 3: The scarecrow won an award for being outstanding in his field."]
    /// The answer's items as the Sheet holds them, under its header.
    private static let table = [["Result", "Source"]] + jokes.map { [$0, start.absoluteString] }
    private static let answer = jokes.map { $0 + "\n" + start.absoluteString }.joined(separator: "\n\n")

    /// The text model: the plan of r1; sub-goals named in turn, then none; the reader rests r1 on the page's first
    /// three jokes; the verifier says done.
    private static func model(subgoals: [String] = ["Read the jokes"]) -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "plan": return .text(RecordedModel.plan([("r1", "Find 3 jokes", "information")]))
            case "subgoal": return n < subgoals.count ? .calls([RecordedModel.goal(subgoals[n])]) : .text("Done.")
            case "read":
                return .text(RecordedModel.reading([RecordedModel.claim(
                    cite: nil, records: [("main/:2", "main/:2"), ("main/:3", "main/:3"), ("main/:4", "main/:4")],
                    requirement: "r1")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
    }

    /// The app's own run for one errand of `output`, its Sheet made by `sheet` from the errand's browser.
    private func errand(_ output: ErrandOutput, bridge: (any BrowserBridge)? = nil,
                        sheet: @escaping @MainActor (any BrowserBridge) -> any SheetDestination,
                        sheetMade: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
                        waitForUser: @escaping @MainActor @Sendable (ErrandHandover, BrowserTab, Duration) async -> Bool
                            = { _, _, _ in false }) -> any ErrandRunner {
        let model = Self.model()
        let jev = RecordedJev { asked, _ in asked.isStep ? .answers(operation: "DONE") : .answers() }
        let make = AgentRun.answering(client: model.client, engine: jev.engine, startPage: Self.start, sheet: sheet)
        return make(ErrandSetup(id: UUID(), goal: Self.goal, bridge: bridge ?? WebViewBridge(), confirm: { _ in nil },
                                sheetMade: sheetMade, waitForUser: waitForUser, output: output))
    }

    // MARK: - A table when asked (№ 50, 168, 169)

    /// Asked for a table: a new Sheet, named after the user's words, holds the header and one row per item of the
    /// answer — its quote, then its page's link — read back as pasted. The answer is the errand's as ever.
    func testATableRequestPutsTheAnswersItemsUnderAHeaderIntoANewSheet() async throws {
        let fixture = FixtureSheet()
        let run = errand(.sheet, sheet: { _ in fixture })
        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.answer)
        let sheet = try XCTUnwrap(outcome.sheet)
        let written = try await fixture.readBack(sheet)
        XCTAssertEqual(written.cells, Self.table)
        XCTAssertEqual(fixture.title, Self.goal)
        XCTAssertEqual(run.record.sheetWrite, .verified)
        XCTAssertNil(outcome.sheetFailure)
        XCTAssertNil(outcome.failure)
    }

    /// Not asked for a table: the answer, as ever — no Sheet is made.
    func testWithoutATableRequestNoSheetIsMade() async throws {
        let fixture = FixtureSheet()
        let outcome = await errand(.answer, sheet: { _ in fixture }).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.answer)
        XCTAssertNil(outcome.sheet)
        XCTAssertNil(fixture.title, "no Sheet was made")
        XCTAssertNil(outcome.sheetFailure)
    }

    /// The header is the one the owner approved on 2026-10-06 (the approval page, row 11), byte for byte.
    func testTheHeaderIsTheOneTheOwnerApproved() {
        XCTAssertEqual(AgentRun.sheetHeader, ["Result", "Source"])
    }

    // MARK: - A Sheet that fails keeps the answer (№ 174)

    /// A Sheet that cannot be made: the errand is done with its answer and sources, and says the Sheet was not made.
    func testASheetThatCannotBeMadeKeepsTheAnswerAndSaysSo() async throws {
        let outcome = await errand(.sheet, sheet: { _ in NeverMade() }).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.answer)
        XCTAssertEqual(outcome.sources, [Self.start])
        XCTAssertNil(outcome.sheet)
        XCTAssertNil(outcome.failure, "a Sheet's failure ends nothing")
        XCTAssertEqual(outcome.sheetFailure, .notMade)
        XCTAssertEqual(ChatService.errandResultText(outcome),
                       Self.answer + "\n\nSources:\n1. https://site-404.test/\n\n" + ChatService.sheetNotMadeLine)
    }

    /// A read-back that does not show what was pasted is named, never hidden: the Sheet is kept, the answer
    /// arrives, and MetaChat says the Sheet may not match.
    func testAReadBackThatDiffersIsNamedNotHidden() async throws {
        let shows = ShowsSomethingElse()
        let run = errand(.sheet, sheet: { _ in shows })
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.answer)
        let sheet = try XCTUnwrap(outcome.sheet, "the Sheet exists: kept")
        XCTAssertEqual(outcome.sheetFailure, .mismatch)
        XCTAssertEqual(run.record.sheetWrite, .pasted, "pasted, not read back as pasted")
        XCTAssertEqual(ChatService.errandResultText(outcome),
                       Self.answer + "\n\nSources:\n1. https://site-404.test/\n\nSheet: " + sheet.absoluteString
                       + "\n\n" + ChatService.sheetMismatchLine)
    }

    // MARK: - In the user's Chrome (№ 163, 26, 170-172)

    /// With Google Sheets: the Sheet is made in a tab of its own, the rows pasted and read back only there, the
    /// user's clipboard untouched, and that tab closed once the Sheet is written.
    func testTheRowsGoOnlyIntoTheSheetsOwnTabWhichClosesAfter() async throws {
        let bridge = SheetTabBridge()
        let clipboard = NSPasteboard.general.changeCount
        let outcome = await errand(.sheet, bridge: bridge, sheet: { GoogleSheet(bridge: $0) }).run(report: { _ in })

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertNil(outcome.sheetFailure)
        XCTAssertEqual(outcome.sheet, URL(string: "https://docs.google.com/spreadsheets/d/SHEET-1/edit"))
        let tab = try XCTUnwrap(bridge.sheetTabs.first)
        XCTAssertEqual(bridge.sheetTabs, [tab])
        XCTAssertEqual(bridge.pastedText(in: tab), SheetCells.pasteText(rows: Self.table, empty: ""))
        XCTAssertTrue(bridge.ran.allSatisfy { $0.tab == tab }, "every Sheet script ran in the Sheet's own tab")
        XCTAssertEqual(bridge.ran.filter { $0.kind == "paste" }.count, 1)
        XCTAssertEqual(bridge.closed.map(\.tab), [tab], "its tab is closed")
        XCTAssertEqual(bridge.inner.openTabCount, 0, "and the errand's own")
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard, "the user's clipboard is never touched")
    }

    /// Stop during the paste: the Sheet's tab closes within Stop's limit — 10 s — and nothing more is written or
    /// read there; the errand ends stopped with its answer and the Sheet it made, and no failure is named.
    func testStopDuringThePasteClosesTheSheetsTabWithinTenSecondsAndWritesNothingMore() async throws {
        let bridge = SheetTabBridge()
        bridge.pasteHolds = true
        let stoppedAt = Box<ContinuousClock.Instant>()
        let run = errand(.sheet, bridge: bridge, sheet: { GoogleSheet(bridge: $0) })
        bridge.onPaste = {
            stoppedAt.value = .now
            run.stop()
        }
        let outcome = await run.run(report: { _ in })

        let stop = try XCTUnwrap(stoppedAt.value, "the premise: Stop came during the paste")
        let tab = try XCTUnwrap(bridge.sheetTabs.first)
        let closed = try XCTUnwrap(bridge.closed.first { $0.tab == tab }, "the Sheet's tab is closed")
        XCTAssertLessThan(closed.at - stop, AgentRun.stopLimit)
        XCTAssertTrue(bridge.ran.filter { $0.at > stop }.isEmpty, "nothing is written or read after Stop")
        XCTAssertNil(bridge.pastedText(in: tab), "the paste Stop cut short never landed")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.answer, Self.answer, "what was found is kept")
        XCTAssertNotNil(outcome.sheet, "the Sheet made before Stop is kept")
        XCTAssertNil(outcome.sheetFailure, "Stop is no failure of the Sheet")
    }

    /// Stop as the Sheet's receipt comes: nothing more is typed, pasted or read in its tab — the Sheet is not even
    /// named — its tab closes within Stop's limit, and the errand ends stopped with its answer and the Sheet it made.
    func testStopAsTheSheetIsMadeNamesNothingAndWritesNothing() async throws {
        let bridge = SheetTabBridge()
        let stoppedAt = Box<ContinuousClock.Instant>()
        let running = Box<any ErrandRunner>()
        let run = errand(.sheet, bridge: bridge, sheet: { GoogleSheet(bridge: $0) }, sheetMade: { _ in
            stoppedAt.value = .now
            running.value?.stop()
        })
        running.value = run
        let outcome = await run.run(report: { _ in })

        let stop = try XCTUnwrap(stoppedAt.value, "the premise: Stop came with the Sheet's receipt")
        let tab = try XCTUnwrap(bridge.sheetTabs.first)
        XCTAssertEqual(bridge.ran.filter { $0.at > stop }.map(\.kind), [], "nothing is typed, pasted or read after Stop")
        XCTAssertEqual(bridge.names, [], "the Sheet is not named after Stop")
        XCTAssertNil(bridge.pastedText(in: tab))
        let closed = try XCTUnwrap(bridge.closed.first { $0.tab == tab }, "the Sheet's tab is closed")
        XCTAssertLessThan(closed.at - stop, AgentRun.stopLimit)
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.answer, Self.answer, "what was found is kept")
        XCTAssertEqual(outcome.sheet, URL(string: "https://docs.google.com/spreadsheets/d/SHEET-1/edit"),
                       "the Sheet made before Stop is kept")
        XCTAssertNil(outcome.sheetFailure, "Stop is no failure of the Sheet")
    }

    /// Google's sign-in on the way to the Sheet is the user's part, waited for in the Sheet's own tab as at any
    /// page (stage 3); once they said Continue, the Sheet is made and written.
    func testAGoogleSignInOnTheWayWaitsForTheUserThenTheSheetIsMade() async throws {
        let bridge = SheetTabBridge()
        bridge.landings = [.signIn, .editor]
        let asked = Box<[(ErrandHandover, BrowserTab)]>()
        let run = errand(.sheet, bridge: bridge, sheet: { GoogleSheet(bridge: $0) }, waitForUser: { handover, tab, _ in
            asked.value = (asked.value ?? []) + [(handover, tab)]
            return true
        })
        let outcome = await run.run(report: { _ in })

        let waits = try XCTUnwrap(asked.value)
        XCTAssertEqual(waits.map(\.0), [ErrandHandover(kind: .signIn, host: "accounts.google.com")])
        XCTAssertEqual(waits.map(\.1), [bridge.sheetTabs[0]], "in the Sheet's own tab")
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertNil(outcome.sheetFailure)
        XCTAssertEqual(outcome.sheet?.path, "/spreadsheets/d/SHEET-2/edit")
        XCTAssertEqual(bridge.closed.map(\.tab), bridge.sheetTabs, "both tabs closed")
        XCTAssertTrue(run.record.events.map(\.shape).contains("handover signIn accounts.google.com"))
        XCTAssertTrue(run.record.events.map(\.shape).contains("continued"))
    }

    /// A sign-in the user never does: the errand ends with its answer, and MetaChat says Google asked for one.
    func testASignInNobodyDoesEndsWithTheAnswerAndSaysGoogleAskedForIt() async throws {
        let bridge = SheetTabBridge()
        bridge.landings = [.signIn]
        let outcome = await errand(.sheet, bridge: bridge, sheet: { GoogleSheet(bridge: $0) }).run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.answer)
        XCTAssertNil(outcome.sheet)
        XCTAssertEqual(outcome.sheetFailure, .signIn)
        XCTAssertEqual(bridge.closed.map(\.tab), bridge.sheetTabs, "the sign-in tab is closed")
        XCTAssertTrue(ChatService.errandResultText(outcome).hasSuffix("\n\n" + ChatService.sheetSignInLine))
    }

    // MARK: - At a ceiling (owner default 6.1)

    /// An errand stopped at a ceiling writes what it collected into the Sheet.
    func testAtACeilingWhatWasCollectedGoesIntoTheSheet() async throws {
        let model = Self.model(subgoals: ["Read the jokes", "Find the author"])
        let jev = RecordedJev { asked, _ in asked.isStep ? .answers(operation: "DONE") : .answers() }
        let fixture = FixtureSheet()
        let plan = try XCTUnwrap(AgentPlan(goal: Self.goal, requirements: [
            .init(id: "r1", text: "Find 3 jokes", kind: .information),
            .init(id: "r2", text: "Find who wrote them", kind: .information),
        ], answerExpected: true))
        let run = AgentRun(goal: Self.goal, planner: FixedPlanner(plan: plan), errandID: UUID(),
                           collaborators: .init(bridge: WebViewBridge(), engine: jev.engine, writer: nil, sheet: fixture,
                                                confirm: { _ in nil }, model: model.model, output: .sheet),
                           limits: .init(steps: 1, activeSeconds: 600, spendMicros: 500_000, expiry: .seconds(1_800)),
                           startPage: Self.start)
        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(outcome.ending, .ceiling)
        XCTAssertEqual(outcome.answer, Self.answer)
        let written = try await fixture.readBack(try XCTUnwrap(outcome.sheet))
        XCTAssertEqual(written.cells, Self.table)
        XCTAssertEqual(run.record.sheetWrite, .verified)
    }

    // MARK: - Fixtures

    /// A Sheet that cannot be made.
    private final class NeverMade: SheetDestination {
        struct Failed: Error {}
        func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL { throw Failed() }
        func paste(_ text: String, into sheet: URL) async throws { throw Failed() }
        func readBack(_ sheet: URL) async throws -> SheetReadBack { throw Failed() }
    }

    /// A Sheet whose read-back shows one cell changed — the user editing it meanwhile.
    private final class ShowsSomethingElse: SheetDestination {
        private let inner = FixtureSheet()
        func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
            try await inner.create(title: title, made: made)
        }
        func paste(_ text: String, into sheet: URL) async throws { try await inner.paste(text, into: sheet) }
        func readBack(_ sheet: URL) async throws -> SheetReadBack {
            var cells = try await inner.readBack(sheet).cells
            cells[1][0] = "Something else"
            return SheetReadBack(cells: cells, holdsFormula: false)
        }
    }
}
