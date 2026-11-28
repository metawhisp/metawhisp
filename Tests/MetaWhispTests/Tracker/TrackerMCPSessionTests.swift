import XCTest
@testable import MetaWhispTrackerKit

/// FEAT-0006 §6, §7 — the MCP server an agent talks to: handshake, tools, resources, roots, results and errors.
final class TrackerMCPSessionTests: XCTestCase {

    private var calls: [(op: String, folder: String?, client: String?, args: [String: JSONValue])] = []
    private var reply = TrackerResponse.success("ok")

    private func session(cwd: String = "/work/Acme", pinned: Bool = false) -> MCPSession {
        MCPSession(cwd: cwd, pinned: pinned, resolveRoot: { "root:" + $0 }) { [unowned self] request in
            calls.append((request.op, request.folder, request.client, request.args))
            return reply
        }
    }

    private func send(_ s: MCPSession, _ json: String) throws -> [[String: JSONValue]] {
        try s.handle(line: json).map { line in
            try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue)
        }
    }

    private func initialize(_ s: MCPSession, roots: Bool = false, client: String = "claude-code") throws {
        let caps = roots ? #"{"roots":{"listChanged":true}}"# : "{}"
        _ = try send(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":\#(caps),"clientInfo":{"name":"\#(client)","version":"1"}}}"#)
    }

    func testInitializeNamesTheServerAndKeepsTheClientsProtocol() throws {
        let s = session()
        let out = try send(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
        let result = try XCTUnwrap(out.first?["result"]?.objectValue)
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(result["serverInfo"]?.objectValue?["name"], .string("metawhisp"))
        XCTAssertNotNil(result["capabilities"]?.objectValue?["tools"])
        XCTAssertNotNil(result["capabilities"]?.objectValue?["resources"])
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("metawhisp://workflow/overview") == true)
        XCTAssertTrue(try send(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).isEmpty)
    }

    func testAnUnknownProtocolVersionGetsOurs() throws {
        let out = try send(session(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(out.first?["result"]?.objectValue?["protocolVersion"], .string(MCPSession.protocolVersions.last!))
    }

    func testToolsAreTheTaskToolsPlusSearchAndNothingElse() throws {
        let s = session()
        try initialize(s)
        let out = try send(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(out.first?["result"]?.objectValue?["tools"]?.arrayValue)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(Set(names), ["get_metawhisp_instructions", "task_create", "task_list", "task_search", "task_view",
                                    "task_edit", "task_archive", "task_restore", "task_delete", "search_memories",
                                    "search_conversations", "recent_conversations"])
        for tool in tools {
            let schema = try XCTUnwrap(tool.objectValue?["inputSchema"]?.objectValue)
            XCTAssertEqual(schema["type"], .string("object"))
            XCTAssertEqual(schema["additionalProperties"], .bool(false), "\(tool)")
            XCTAssertNotNil(tool.objectValue?["description"]?.stringValue)
        }
        let create = try XCTUnwrap(tools.first { $0.objectValue?["name"] == .string("task_create") }?.objectValue)
        let status = create["inputSchema"]?.objectValue?["properties"]?.objectValue?["status"]?.objectValue
        XCTAssertEqual(status?["enum"], .array([.string("To Do"), .string("In Progress"), .string("Done")]),
                       "no Draft for agents")
        let delete = try XCTUnwrap(tools.first { $0.objectValue?["name"] == .string("task_delete") }?.objectValue)
        XCTAssertEqual(delete["inputSchema"]?.objectValue?["required"], .array([.string("id"), .string("userConfirmed")]))
    }

    func testAToolCallGoesToTheAppWithTheFolderAndTheClient() throws {
        let s = session()
        try initialize(s, client: "codex-mcp-client")
        reply = .success("Created task TASK-1.")
        let out = try send(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_create","arguments":{"title":"Ship"}}}"#)
        XCTAssertEqual(calls.first?.op, "task_create")
        XCTAssertEqual(calls.first?.folder, "root:/work/Acme")
        XCTAssertEqual(calls.first?.client, "Codex")
        XCTAssertEqual(calls.first?.args["title"], .string("Ship"))
        let result = try XCTUnwrap(out.first?["result"]?.objectValue)
        XCTAssertEqual(result["content"]?.arrayValue?.first?.objectValue?["text"], .string("Created task TASK-1."))
        XCTAssertNil(result["isError"])
    }

    func testAFailureIsAnErrorResultWithItsCode() throws {
        let s = session()
        try initialize(s)
        reply = .failure(TrackerFailure(.taskNotFound, "Task TASK-9 not found in this project."))
        let out = try send(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_view","arguments":{"id":"TASK-9"}}}"#)
        let result = try XCTUnwrap(out.first?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["code"], .string("TASK_NOT_FOUND"))
        XCTAssertEqual(result["content"]?.arrayValue?.first?.objectValue?["text"],
                       .string("Task TASK-9 not found in this project."))
    }

    func testTheInstructionsToolAndResourcesNeedNoApp() throws {
        let s = session()
        try initialize(s)
        var out = try send(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_metawhisp_instructions","arguments":{"instruction":"task-execution"}}}"#)
        XCTAssertTrue(out.first?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?
            .stringValue?.contains("In Progress") == true)
        out = try send(s, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        let uris = out.first?["result"]?.objectValue?["resources"]?.arrayValue?
            .compactMap { $0.objectValue?["uri"]?.stringValue }
        XCTAssertEqual(uris, ["metawhisp://workflow/overview", "metawhisp://workflow/task-creation",
                              "metawhisp://workflow/task-execution", "metawhisp://workflow/task-finalization"])
        out = try send(s, #"{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"metawhisp://workflow/overview"}}"#)
        XCTAssertEqual(out.first?["result"]?.objectValue?["contents"]?.arrayValue?.first?.objectValue?["mimeType"],
                       .string("text/markdown"))
        out = try send(s, #"{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"metawhisp://nope"}}"#)
        XCTAssertNotNil(out.first?["error"])
        XCTAssertTrue(calls.isEmpty, "none of this reached the app")
    }

    func testWithRootsTheFirstCallAsksTheClientForItsFolderFirst() throws {
        let s = session()
        try initialize(s, roots: true)
        var out = try send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?["method"], .string("roots/list"))
        XCTAssertTrue(calls.isEmpty, "the call waits for the folder")
        let askId = try XCTUnwrap(out.first?["id"])
        let idJSON = String(data: try JSONEncoder().encode(askId), encoding: .utf8)!
        out = try send(s, #"{"jsonrpc":"2.0","id":\#(idJSON),"result":{"roots":[{"uri":"file:///Users/sam/Code/My%20App","name":"x"}]}}"#)
        XCTAssertEqual(calls.first?.folder, "root:/Users/sam/Code/My App")
        XCTAssertEqual(out.first?["id"], .int(8), "the held call is answered")
        _ = try send(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertEqual(calls.count, 2, "asked once")
    }

    /// A gate needs a ceiling: a client that offers roots and never answers gets its calls answered anyway.
    func testRootsThatNeverComeStopAtTheCeiling() throws {
        let s = session()
        try initialize(s, roots: true)
        _ = try send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        let asked = try XCTUnwrap(s.pendingRootsRequest)
        XCTAssertTrue(s.giveUpOnRoots(ifStill: "another").isEmpty, "only the ask it was started for")
        let out = s.giveUpOnRoots(ifStill: asked)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(calls.first?.folder, "root:/work/Acme")
        XCTAssertNil(s.pendingRootsRequest)
        _ = try send(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertEqual(calls.count, 2, "not asked again")
    }

    /// Review P3-9: a second call that arrives while the roots answer is pending waits too, in order.
    func testCallsDuringTheRootsQuestionAreHeldInOrder() throws {
        let s = session()
        try initialize(s, roots: true)
        let ask = try send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertTrue(try send(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"task_view","arguments":{"id":"1"}}}"#).isEmpty)
        XCTAssertTrue(calls.isEmpty)
        let idJSON = String(data: try JSONEncoder().encode(ask.first?["id"]), encoding: .utf8)!
        let out = try send(s, #"{"jsonrpc":"2.0","id":\#(idJSON),"result":{"roots":[{"uri":"file:///r/Acme"}]}}"#)
        XCTAssertEqual(out.map { $0["id"] }, [.int(8), .int(9)])
        XCTAssertEqual(calls.map(\.folder), ["root:/r/Acme", "root:/r/Acme"])
    }

    func testAPinnedFolderNeverAsksForRoots() throws {
        let s = session(cwd: "/pinned/Acme", pinned: true)
        try initialize(s, roots: true)
        let out = try send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        XCTAssertEqual(out.first?["id"], .int(8))
        XCTAssertEqual(calls.first?.folder, "root:/pinned/Acme")
    }

    func testAClientWithoutRootsOrWithNoneUsesTheProcessFolder() throws {
        let s = session()
        try initialize(s, roots: true)
        let ask = try send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#)
        let idJSON = String(data: try JSONEncoder().encode(ask.first?["id"]), encoding: .utf8)!
        _ = try send(s, #"{"jsonrpc":"2.0","id":\#(idJSON),"error":{"code":-32601,"message":"no"}}"#)
        XCTAssertEqual(calls.first?.folder, "root:/work/Acme")
    }

    func testUnknownMethodsAndBadLinesAreHandled() throws {
        let s = session()
        let out = try send(s, #"{"jsonrpc":"2.0","id":1,"method":"bogus/thing"}"#)
        XCTAssertEqual(out.first?["error"]?.objectValue?["code"], .int(-32601))
        XCTAssertEqual(try send(s, "not json").first?["error"]?.objectValue?["code"], .int(-32700))
        XCTAssertEqual(try send(s, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#).first?["result"], .object([:]))
    }
}
