import XCTest
@testable import MetaWhispTrackerKit

/// FEAT-0006 §6 — the command-line tool's words become the same requests the MCP tools send.
final class TrackerCLITests: XCTestCase {

    private func parse(_ line: String) throws -> TrackerCLI.Command {
        try TrackerCLI.parse(TrackerCLI.split(line))
    }

    private func request(_ line: String) throws -> (op: String, args: [String: JSONValue], json: Bool) {
        guard case let .request(op, args, json) = try parse(line) else {
            XCTFail("not a request: \(line)")
            return ("", [:], false)
        }
        return (op, args, json)
    }

    func testCreateTakesTheTitleAndItsFlags() throws {
        let r = try request(#"task create "Add search" -d "Why it matters" -s "In Progress" --priority high -l web,auth --ac "Works" --ac "Tested" --dep TASK-1 -p TASK-2 --due-date 2026-12-01 --json"#)
        XCTAssertEqual(r.op, "task_create")
        XCTAssertTrue(r.json)
        XCTAssertEqual(r.args["title"], .string("Add search"))
        XCTAssertEqual(r.args["description"], .string("Why it matters"))
        XCTAssertEqual(r.args["status"], .string("In Progress"))
        XCTAssertEqual(r.args["priority"], .string("high"))
        XCTAssertEqual(r.args["labels"], .array([.string("web"), .string("auth")]))
        XCTAssertEqual(r.args["acceptanceCriteria"], .array([.string("Works"), .string("Tested")]))
        XCTAssertEqual(r.args["dependencies"], .array([.string("TASK-1")]))
        XCTAssertEqual(r.args["parentTaskId"], .string("TASK-2"))
        XCTAssertEqual(r.args["dueDate"], .string("2026-12-01"))
    }

    func testListAndItsFilters() throws {
        let r = try request("task list -s todo --unassigned --ready --limit 5 -l web")
        XCTAssertEqual(r.op, "task_list")
        XCTAssertEqual(r.args["status"], .string("todo"))
        XCTAssertEqual(r.args["unassigned"], .bool(true))
        XCTAssertEqual(r.args["ready"], .bool(true))
        XCTAssertEqual(r.args["limit"], .int(5))
        XCTAssertEqual(r.args["labels"], .array([.string("web")]))
    }

    func testEditMapsChecksPlanNotesAndComments() throws {
        let r = try request(#"task edit TASK-3 -s done --check-ac 1 --check-ac 2 --append-notes "Found it" --plan "Step 1" --comment "Looks good" --comment-author @sam --final-summary "Fixed" --due-date """#)
        XCTAssertEqual(r.op, "task_edit")
        XCTAssertEqual(r.args["id"], .string("TASK-3"))
        XCTAssertEqual(r.args["status"], .string("done"))
        XCTAssertEqual(r.args["acceptanceCriteriaCheck"], .array([.int(1), .int(2)]))
        XCTAssertEqual(r.args["notesAppend"], .array([.string("Found it")]))
        XCTAssertEqual(r.args["planSet"], .string("Step 1"))
        XCTAssertEqual(r.args["commentsAppend"], .array([.string("Looks good")]))
        XCTAssertEqual(r.args["commentAuthor"], .string("@sam"))
        XCTAssertEqual(r.args["finalSummary"], .string("Fixed"))
        XCTAssertEqual(r.args["dueDate"], .null, "an empty due date clears it")
    }

    func testViewArchiveRestoreAndTheShorthand() throws {
        XCTAssertEqual(try request("task view TASK-3").op, "task_view")
        XCTAssertEqual(try request("task 3").args["id"], .string("3"))
        XCTAssertEqual(try request("task archive 3").op, "task_archive")
        XCTAssertEqual(try request("task restore 3").op, "task_restore")
        XCTAssertEqual(try request("project").op, "project_info")
        let search = try request("search login form")
        XCTAssertEqual(search.op, "task_search")
        XCTAssertEqual(search.args["query"], .string("login form"))
    }

    func testDeleteNeedsYes() throws {
        XCTAssertEqual(try request("task delete 3").args["userConfirmed"], .bool(false))
        XCTAssertEqual(try request("task delete 3 --yes").args["userConfirmed"], .bool(true))
    }

    func testLocalCommands() throws {
        guard case .instructions("task-creation") = try parse("instructions task-creation") else { return XCTFail() }
        guard case .instructions("overview") = try parse("instructions") else { return XCTFail() }
        guard case .mcpStart(cwd: "/x/Acme") = try parse("mcp start --cwd /x/Acme") else { return XCTFail() }
        guard case .mcpStart(cwd: nil) = try parse("mcp start") else { return XCTFail() }
        guard case .help = try parse("--help") else { return XCTFail() }
        guard case .help = try parse("") else { return XCTFail() }
    }

    func testTheWorkingFolderFlagWorksAnywhere() throws {
        XCTAssertEqual(try TrackerCLI.cwdOverride(TrackerCLI.split("task list --cwd /x/Acme")), "/x/Acme")
        XCTAssertNil(try TrackerCLI.cwdOverride(TrackerCLI.split("task list")))
        XCTAssertEqual(try request("task list --cwd /x/Acme").op, "task_list", "the flag is not an argument")
    }

    func testMistakesAreSaid() {
        XCTAssertThrowsError(try parse("task create")) { XCTAssertTrue("\($0)".contains("title")) }
        XCTAssertThrowsError(try parse("task list --bogus"))
        XCTAssertThrowsError(try parse("task edit"))
        XCTAssertThrowsError(try parse("task list --limit"))
        XCTAssertThrowsError(try parse("frobnicate"))
        XCTAssertThrowsError(try parse("instructions nope"))
    }

    func testSplitKeepsQuotedWords() {
        XCTAssertEqual(TrackerCLI.split(#"a "b c" 'd e' f\ g"#), ["a", "b c", "d e", "f g"])
        XCTAssertEqual(TrackerCLI.split(#"x """#), ["x", ""])
    }
}
