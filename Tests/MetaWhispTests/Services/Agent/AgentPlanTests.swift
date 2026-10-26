import XCTest
@testable import MetaWhisp

/// The plan (ITER-074 §3.1, §4, §5): written once from the user's words,
/// never changed, and only runnable when it is whole.
final class AgentPlanTests: XCTestCase {

    private let engine = SearchEngine(base: URL(string: "https://search.test/")!, queryName: "q")
    private let find = AgentPlan.Subgoal(description: "Find a competitor's site", terms: ["voice", "notes"])

    private func plan(subgoals: [AgentPlan.Subgoal]? = nil, searches: [URL]? = nil, columns: [String] = ["Name", "URL"],
                      rowsWanted: Int = 3) -> AgentPlan? {
        AgentPlan(goal: "Add three competitor sites to a sheet", subgoals: subgoals ?? [find],
                  searches: searches ?? [URL(string: "https://search.test/?q=voice")!], columns: columns,
                  sheetTitle: "Competitors", rowsWanted: rowsWanted, emptyCell: "n/a")
    }

    // MARK: - Searches the app builds

    func testASearchAddressIsBuiltFromTheQuery() throws {
        let url = engine.url(for: "  voice notes apps ")
        XCTAssertEqual(url?.host, "search.test")
        let query = URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "q", value: "voice notes apps")])
    }

    /// Whatever the query holds, it stays one query value: it cannot add a
    /// parameter or change the address.
    func testAQueryCannotEscapeItsParameter() throws {
        let url = try XCTUnwrap(engine.url(for: "a&b=c#d"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "q", value: "a&b=c#d")])
        XCTAssertEqual(url.host, "search.test")
        XCTAssertNil(url.fragment)
    }

    func testAnEmptyQueryBuildsNothing() {
        XCTAssertNil(engine.url(for: "   "))
    }

    // MARK: - A whole plan

    func testAWholePlanIsAccepted() {
        let whole = plan()
        XCTAssertEqual(whole?.columns, ["Name", "URL"])
        XCTAssertEqual(whole?.rowsWanted, 3)
    }

    /// Only web addresses are ever searched (§6.2); a plan left with none
    /// cannot run.
    func testOnlyWebSearchesAreKept() {
        let mixed = plan(searches: [URL(string: "file:///etc/hosts")!, URL(string: "https://search.test/?q=a")!])
        XCTAssertEqual(mixed?.searches, [URL(string: "https://search.test/?q=a")!])
        XCTAssertNil(plan(searches: [URL(string: "javascript:alert(1)")!]))
    }

    func testAPlanThatCannotRunIsRefused() {
        XCTAssertNil(plan(subgoals: []), "no subgoal")
        XCTAssertNil(plan(columns: []), "no column")
        XCTAssertNil(plan(rowsWanted: 0), "no row wanted")
        XCTAssertNil(plan(rowsWanted: AgentPlan.maxRows + 1), "more rows than any errand asks for")
        XCTAssertNotNil(plan(rowsWanted: AgentPlan.maxRows))
    }

    // MARK: - Which subgoal a row serves

    /// One subgoal per row in order, the last one repeated: J1 has one for
    /// all its rows, J2 one per service.
    func testEachRowHasItsSubgoalAndTheLastRepeats() throws {
        let first = AgentPlan.Subgoal(description: "Service one", terms: ["one"])
        let second = AgentPlan.Subgoal(description: "Service two", terms: ["two"])
        let twoSteps = try XCTUnwrap(plan(subgoals: [first, second]))
        XCTAssertEqual(twoSteps.subgoal(forRow: 0), first)
        XCTAssertEqual(twoSteps.subgoal(forRow: 1), second)
        XCTAssertEqual(twoSteps.subgoal(forRow: 7), second)
        XCTAssertEqual(try XCTUnwrap(plan()).subgoal(forRow: 5), find)
    }

    // MARK: - An answer plan (ITER-076 brain)

    /// An answer plan names what the user asked for: at least one
    /// requirement, each id once — the reference planner's check, and one
    /// more — and it asks for no rows; a rows plan does.
    func testAnAnswerPlanNeedsARequirementAndUniqueIds() throws {
        let find = AgentPlan.Requirement(id: "r1", text: "Find 10 jokes", kind: .information)
        let open = AgentPlan.Requirement(id: "r2", text: "Open the tips", kind: .action)
        let answer = try XCTUnwrap(AgentPlan(goal: "Find jokes", requirements: [find, open], answerExpected: true))
        XCTAssertEqual(answer.requirements, [find, open])
        XCTAssertTrue(answer.answerExpected)
        XCTAssertFalse(answer.asksForRows)
        XCTAssertEqual(answer.columns, [])
        XCTAssertNil(AgentPlan(goal: "Find jokes", requirements: [], answerExpected: true), "no requirement")
        XCTAssertNil(AgentPlan(goal: "Find jokes", requirements: [find, .init(id: "r1", text: "Open", kind: .action)],
                               answerExpected: true), "a repeated id")
        let rows = try XCTUnwrap(plan())
        XCTAssertTrue(rows.asksForRows)
        XCTAssertEqual(rows.requirements, [])
    }
}
