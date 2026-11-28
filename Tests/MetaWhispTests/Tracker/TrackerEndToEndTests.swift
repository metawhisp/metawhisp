import SwiftData
import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 S1, S5 — the real `metawhisp-cli` binary, as Claude Code / Codex launch it, against the app's socket
/// and a real `TrackerService` on on-disk stores. Headless: nothing is shown on screen.
@MainActor
final class TrackerEndToEndTests: XCTestCase {

    private var dir: URL!
    private var socket: String!
    private var server: TrackerSocketServer!
    private var main: ModelContainer!
    private var project: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-e2e-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        project = dir.appendingPathComponent("Code/Acme")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        main = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                  configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("Main.store"))])
        let tracker = try TrackerStore.makeContainer(url: dir.appendingPathComponent("Tracker.store"))
        let service = TrackerService(main: main, tracker: tracker, mutations: MutationService(runHooks: { _ in }),
                                     home: dir.path)
        socket = "/tmp/mwe-\(UUID().uuidString.prefix(8)).sock"
        server = TrackerSocketServer(path: socket) { request in
            MainActor.assumeIsolated { service.handle(request) }
        }
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("metawhisp-cli")
    }

    /// Runs the tool off the main thread (the app's side answers on the main actor) and waits for it.
    private func run(_ args: [String], stdin: String = "", socketPath: String? = nil,
                     cwd: URL? = nil, env: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "metawhisp-cli not built")
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = cwd ?? project.appendingPathComponent("Sources")
        p.environment = ["METAWHISP_SOCKET": socketPath ?? socket, "METAWHISP_BUNDLE_ID": "com.invalid.metawhisp-test",
                         "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(env) { _, given in given }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let finished = expectation(description: "tool finished")
        DispatchQueue.global().async {
            p.waitUntilExit()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 40)
        return (p.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testAnAgentCreatesAndListsTasksOverMCP() throws {
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_create","arguments":{"title":"Add search","acceptanceCriteria":["Finds tasks"]}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_edit","arguments":{"id":"TASK-1","status":"In Progress","planSet":"1. Index"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#,
        ]
        let r = try run(["mcp", "start"], stdin: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(r.status, 0, r.err)
        let replies = r.out.split(separator: "\n").map(String.init)
        XCTAssertEqual(replies.count, 4, r.out)
        XCTAssertTrue(replies[1].contains("Created task TASK-1."), replies[1])
        // A write answers briefly: the task's line, its criteria and the revision (round 3).
        XCTAssertTrue(replies[2].contains("Updated task TASK-1."), replies[2])
        // The agent that took it (Q2).
        XCTAssertTrue(replies[2].contains("TASK-1 - Add search (In Progress, Claude Code, since "), replies[2])
        XCTAssertTrue(replies[2].contains("Revision: "), replies[2])
        XCTAssertTrue(replies[3].contains(#"In Progress:\n  TASK-1 - Add search (ac: 0/1) (Claude Code, since "#),
                      replies[3])

        let task = try XCTUnwrap(try ModelContext(main).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(task.taskDescription, "Add search")
        XCTAssertEqual(task.sourceApp, "Claude Code", "the agent is named as the task's maker")
        XCTAssertEqual(try ModelContext(main).fetch(FetchDescriptor<ProjectAlias>()).map(\.canonicalName), ["Acme"],
                       "a subfolder of the repository is the repository's project")
    }

    func testTheCommandLineSpeaksToTheSameApp() throws {
        var r = try run(["task", "create", "Write docs", "--priority", "high"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("Created task TASK-1."), r.out)
        r = try run(["task", "list"])
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Project: Acme\n\nTo Do:\n  [HIGH] TASK-1 - Write docs")
        r = try run(["task", "view", "TASK-9"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("TASK_NOT_FOUND"), r.err)
        r = try run(["task", "list", "--bogus"])
        XCTAssertEqual(r.status, 2)
    }

    /// An agent's commands carry its session (Claude Code hands them `CLAUDE_CODE_SESSION_ID`, Codex
    /// `CODEX_SESSION_ID`): a task one session took is not another's to move through the command line either.
    func testTheCommandLineCarriesTheAgentsSession() throws {
        let one = ["CLAUDE_CODE_SESSION_ID": "session-one"]
        XCTAssertEqual(try run(["task", "create", "Write docs"], env: one).status, 0)
        var r = try run(["task", "edit", "TASK-1", "-s", "In Progress"], env: one)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("In Progress, Claude Code, since "), r.out)
        r = try run(["task", "edit", "TASK-1", "-s", "Done"], env: ["CLAUDE_CODE_SESSION_ID": "session-two"])
        XCTAssertEqual(r.status, 1, "another Claude Code session cannot move it")
        r = try run(["task", "edit", "TASK-1", "-s", "Done"],
                    env: ["CLAUDE_CODE_SESSION_ID": "session-one", "CODEX_SESSION_ID": "codex-one"])
        XCTAssertEqual(r.status, 1, "a Codex started from that session is another agent")
        r = try run(["task", "edit", "TASK-1", "-s", "Done"])
        XCTAssertEqual(r.status, 1, "nor a person in a terminal")
        r = try run(["task", "edit", "TASK-1", "-s", "Done"], env: one)
        XCTAssertEqual(r.status, 0, r.err)
    }

    func testNoAppIsSaidClearlyAndQuickly() throws {
        let started = Date()
        let r = try run(["task", "list"], socketPath: "/tmp/mwe-missing-\(UUID().uuidString.prefix(6)).sock")
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("APP_UNAVAILABLE"), r.err)
        XCTAssertTrue(r.err.contains("not installed"), r.err)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}
