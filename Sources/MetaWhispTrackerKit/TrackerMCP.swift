import Foundation

/// FEAT-0006 §6, §7 — one MCP session over stdio: JSON-RPC 2.0, one message per line. Tools other than the guide go
/// to the app through `call`; the folder is the client's first `file://` root when the client offers roots and the
/// folder is not pinned, else the process folder.
public final class MCPSession {

    public static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    public static let serverName = "metawhisp"

    private let cwd: String
    private let pinned: Bool
    private let resolveRoot: (String) -> String
    private let call: (TrackerRequest) -> TrackerResponse

    private var clientName: String?
    /// The agent session this server serves: the agent's own id when it passed one (`AgentCaller`), the same id its
    /// commands carry; else this server process.
    public let session: String
    private var clientHasRoots = false
    private var rootsFolder: String?
    private var rootsAsked = false
    private var rootsStale = false
    private var pendingRootsId: JSONValue?
    private var held: [(id: JSONValue, params: [String: JSONValue])] = []
    private var nextOwnId = 1

    /// - Parameters:
    ///   - cwd: the process folder (or `--cwd` / `METAWHISP_CWD`).
    ///   - pinned: true when the folder came from `--cwd` / `METAWHISP_CWD`: client roots are never asked.
    ///   - resolveRoot: working folder → project root (§5.1).
    ///   - call: sends a request to the app and returns its answer.
    ///   - session: the agent's session id, when it passed one.
    public init(cwd: String, pinned: Bool, resolveRoot: @escaping (String) -> String, session: String? = nil,
                call: @escaping (TrackerRequest) -> TrackerResponse) {
        self.cwd = cwd
        self.pinned = pinned
        self.resolveRoot = resolveRoot
        self.session = session ?? UUID().uuidString
        self.call = call
    }

    /// One incoming line → the lines to write back (none for notifications).
    public func handle(line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)).objectValue else {
            return [encode(error(id: .null, code: -32700, message: "Parse error"))]
        }
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            if let id, id == pendingRootsId { return rootsArrived(message) }
            return []
        }
        let params = message["params"]?.objectValue ?? [:]
        guard let id, !id.isNull else {
            if method == "notifications/roots/list_changed" { rootsStale = true }
            return []
        }
        switch method {
        case "initialize":
            return [encode(result(id, initialize(params)))]
        case "ping":
            return [encode(result(id, .object([:])))]
        case "tools/list":
            return [encode(result(id, .object(["tools": .array(TrackerToolSchemas.tools)])))]
        case "tools/call":
            // Held while the folder question is open, so calls keep their order (review P3-9).
            if needsRoots || pendingRootsId != nil {
                held.append((id, params))
                guard pendingRootsId == nil else { return [] }
                return [encode(askRoots())]
            }
            return [encode(result(id, toolCall(params)))]
        case "resources/list":
            return [encode(result(id, .object(["resources": .array(TrackerGuides.all.map { g in
                .object(["uri": .string(g.uri), "name": .string(g.title), "description": .string(g.summary),
                         "mimeType": .string("text/markdown")])
            })])))]
        case "resources/read":
            let uri = params["uri"]?.stringValue ?? ""
            let bare = uri.split(separator: "?").first.map(String.init) ?? uri
            guard let g = TrackerGuides.all.first(where: { $0.uri == bare }) else {
                return [encode(error(id: id, code: -32602, message: "Resource not found: \(uri)"))]
            }
            return [encode(result(id, .object(["contents": .array([.object([
                "uri": .string(g.uri), "mimeType": .string("text/markdown"), "text": .string(g.text),
            ])])])))]
        case "resources/templates/list":
            return [encode(result(id, .object(["resourceTemplates": .array([])])))]
        case "prompts/list":
            return [encode(result(id, .object(["prompts": .array([])])))]
        default:
            return [encode(error(id: id, code: -32601, message: "Method not found: \(method)"))]
        }
    }

    // MARK: - Handshake

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let asked = params["protocolVersion"]?.stringValue
        let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions.last!
        clientHasRoots = params["capabilities"]?.objectValue?["roots"] != nil
        clientName = params["clientInfo"]?.objectValue?["name"]?.stringValue
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:]), "resources": .object([:])]),
            "serverInfo": .object(["name": .string(Self.serverName), "version": .string("\(TrackerKit.version)")]),
            "instructions": .string(TrackerGuides.initializeInstructions),
        ])
    }

    /// "Claude Code" / "Codex" from the client's own name; written as the task's maker.
    var client: String? {
        guard let n = clientName?.lowercased() else { return nil }
        if n.contains("claude") { return "Claude Code" }
        if n.contains("codex") { return "Codex" }
        return clientName
    }

    // MARK: - Roots

    private var needsRoots: Bool {
        !pinned && clientHasRoots && (!rootsAsked || rootsStale)
    }

    private func askRoots() -> JSONValue {
        let id = JSONValue.string("metawhisp-roots-\(nextOwnId)")
        nextOwnId += 1
        pendingRootsId = id
        rootsAsked = true
        rootsStale = false
        return .object(["jsonrpc": .string("2.0"), "id": id, "method": .string("roots/list")])
    }

    /// The id of the `roots/list` this session is waiting for, if any.
    public var pendingRootsRequest: String? { pendingRootsId?.stringValue }

    /// The ceiling on that wait: the held calls are answered with the process folder. Only for the ask the timer
    /// was started for (a later ask has its own).
    public func giveUpOnRoots(ifStill id: String) -> [String] {
        guard pendingRootsRequest == id else { return [] }
        return rootsArrived([:])
    }

    private func rootsArrived(_ message: [String: JSONValue]) -> [String] {
        pendingRootsId = nil
        let roots = message["result"]?.objectValue?["roots"]?.arrayValue ?? []
        rootsFolder = roots.lazy.compactMap { $0.objectValue?["uri"]?.stringValue }
            .compactMap { URL(string: $0) }.first { $0.isFileURL }?.path
        let waiting = held
        held = []
        return waiting.map { encode(result($0.id, toolCall($0.params))) }
    }

    private var folder: String { resolveRoot(rootsFolder ?? cwd) }

    // MARK: - Tools

    private func toolCall(_ params: [String: JSONValue]) -> JSONValue {
        let name = params["name"]?.stringValue ?? ""
        let args = params["arguments"]?.objectValue ?? [:]
        if name == "get_metawhisp_instructions" {
            let which = args["instruction"]?.stringValue ?? "overview"
            guard let g = TrackerGuides.guide(named: which) else {
                return toolResult(.failure(.validation("Unknown instruction: \(which). Valid: "
                                                       + TrackerGuides.all.map(\.name).joined(separator: ", "))))
            }
            return toolResult(.success(g.text))
        }
        guard TrackerToolSchemas.tools.contains(where: { $0.objectValue?["name"]?.stringValue == name }) else {
            return toolResult(.failure(.validation("Tool not found: \(name)")))
        }
        return toolResult(call(TrackerRequest(op: name, folder: folder, client: client, session: session, args: args)))
    }

    private func toolResult(_ r: TrackerResponse) -> JSONValue {
        if r.ok {
            return .object(["content": .array([.object(["type": .string("text"), "text": .string(r.text ?? "")])])])
        }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(r.message ?? "Failed")])]),
            "isError": .bool(true),
            "structuredContent": .object(["code": .string((r.code ?? .internalError).rawValue)]),
        ])
    }

    // MARK: - JSON-RPC

    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .int(code), "message": .string(message)])])
    }

    private func encode(_ v: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(v) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
