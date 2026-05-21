// MetaWhisp MCP server — standalone CLI binary that speaks the
// Model-Context-Protocol over stdio to Claude Desktop / Cursor /
// any MCP-compatible LLM client. Reads a JSON snapshot of MetaWhisp's
// user data (memories, tasks, conversations) that the main app dumps
// every 5 minutes to a stable path. Returns matching rows over
// JSON-RPC 2.0.
//
// Why a separate binary + snapshot file (not direct SwiftData access):
//   - Claude Desktop launches MCP servers as child processes via stdio.
//     They start, stay alive for the session, exit when Claude closes.
//     SwiftData stores can't be safely opened from two processes at once.
//   - Snapshot decouples the read schema from MetaWhisp's internal
//     @Model classes — we can iterate the main app's storage without
//     breaking external Claude/Cursor integrations.
//   - Privacy: snapshot lives on the user's disk. The MCP binary
//     reads + serves locally. Nothing leaves the machine.
//
// **Tools exposed (MCP `tools/list` returns these):**
//   - `search_memories(query: string, limit?: int = 10)`
//     Substring + word match across memory subject + content. Returns
//     top-N most-recent matches.
//   - `list_tasks(status?: "all"|"pending"|"completed" = "pending", limit?: int = 20)`
//     Tasks filtered by completion status, newest first.
//   - `recent_conversations(limit?: int = 10, since_days?: int)`
//     Last N finished conversations with title + overview + project.
//   - `search_conversations(query: string, limit?: int = 5)`
//     Substring search on conversation title + overview + project.
//
// **MCP wire spec:** JSON-RPC 2.0 over stdin/stdout. One JSON object
// per line. Methods: `initialize`, `initialized` (notification),
// `tools/list`, `tools/call`, `shutdown` (notification).
//
// **Build:** `swift build --product metawhisp-mcp` produces
// `.build/debug/metawhisp-mcp` (release version goes in the .app
// bundle via build.sh for distribution).

import Foundation

// MARK: - Snapshot reader

struct Snapshot: Codable {
    let generatedAt: Date
    let schemaVersion: Int
    let memories: [SnapshotMemory]
    let tasks: [SnapshotTask]
    let conversations: [SnapshotConversation]
}

struct SnapshotMemory: Codable {
    let id: String
    let kind: String
    let subject: String
    let content: String
    let category: String?
    let project: String?
    let createdAt: Date
}

struct SnapshotTask: Codable {
    let id: String
    let description: String
    let completed: Bool
    let dueAt: Date?
    let createdAt: Date
    let completedAt: Date?
}

struct SnapshotConversation: Codable {
    let id: String
    let title: String
    let overview: String
    let category: String
    let project: String
    let startedAt: Date
    let finishedAt: Date
}

/// Stable on-disk path. Mirrors `MCPSnapshotService.snapshotURL` in
/// the MetaWhisp main target.
func snapshotPath() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport
        .appendingPathComponent("MetaWhisp", isDirectory: true)
        .appendingPathComponent("mcp-snapshot.json")
}

/// Re-read snapshot on every tool call. The file is small (≤ ~1 MB)
/// and tool calls aren't a hot path; caching would risk staleness.
func loadSnapshot() -> Snapshot? {
    let url = snapshotPath()
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Snapshot.self, from: data)
}

// MARK: - JSON-RPC 2.0 minimal types

/// Generic JSON-RPC request. `id` is null for notifications.
struct RPCRequest: Decodable {
    let jsonrpc: String
    let method: String
    let id: RPCID?
    let params: JSONValue?
}

/// Either Int or String — MCP uses both at different points.
enum RPCID: Codable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .int(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(RPCID.self, .init(codingPath: [], debugDescription: "id must be int or string"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let n):    try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

/// Free-form JSON value — used for params/result payloads.
indirect enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Int.self) { self = .int(n); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown JSON value"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let n):     try c.encode(n)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }

    /// Convenience accessors for tool-arg extraction.
    var stringValue: String? {
        if case .string(let s) = self { return s }; return nil
    }
    var intValue: Int? {
        if case .int(let n) = self { return n }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }; return nil
    }
}

/// Successful response. `id` echoes the request.
struct RPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: RPCID
    let result: JSONValue
}

/// Error response payload.
struct RPCError: Encodable {
    let jsonrpc: String = "2.0"
    let id: RPCID?
    let error: ErrorBody

    struct ErrorBody: Encodable {
        let code: Int
        let message: String
    }
}

// MARK: - MCP tool definitions

/// Tools list returned by `tools/list`. Schema follows MCP spec section
/// "Tools" — name + description + JSON-Schema for inputs.
let mcpTools: [String: JSONValue] = [
    "search_memories": .object([
        "name": .string("search_memories"),
        "description": .string("Substring + word-match search across MetaWhisp's stored memories (facts, opinions, goals captured from the user's voice + meetings). Returns the top-N most recent matching memories."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search text. Case-insensitive substring match across memory subject + content.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max matches to return (default 10, max 50)."),
                    "default": .int(10)
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ]),
    "list_tasks": .object([
        "name": .string("list_tasks"),
        "description": .string("List MetaWhisp tasks. Filter by completion status. Newest first."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("all"), .string("pending"), .string("completed")]),
                    "description": .string("Filter tasks by status (default: pending)."),
                    "default": .string("pending")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max tasks to return (default 20)."),
                    "default": .int(20)
                ])
            ])
        ])
    ]),
    "recent_conversations": .object([
        "name": .string("recent_conversations"),
        "description": .string("Latest finished MetaWhisp conversations (meetings, voice notes) with title, overview, and project assignment. Newest first."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max conversations to return (default 10)."),
                    "default": .int(10)
                ]),
                "since_days": .object([
                    "type": .string("integer"),
                    "description": .string("Only conversations finished within the last N days. Omit for no time filter.")
                ])
            ])
        ])
    ]),
    "search_conversations": .object([
        "name": .string("search_conversations"),
        "description": .string("Substring search across MetaWhisp conversation titles, overviews, and project labels. Returns the top-N matches sorted by newest first."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search text. Case-insensitive substring match.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max conversations to return (default 5)."),
                    "default": .int(5)
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ])
]

// MARK: - Tool dispatch

/// `tools/call` handler. Returns the MCP-wrapped result envelope.
func executeTool(name: String, args: [String: JSONValue]) -> JSONValue {
    guard let snapshot = loadSnapshot() else {
        return mcpTextResult(
            "MetaWhisp snapshot not available at \(snapshotPath().path) — the main MetaWhisp app must be running for at least 5 minutes for the first snapshot to be written, or open Settings → AI to force a refresh."
        )
    }

    switch name {
    case "search_memories":
        let query = args["query"]?.stringValue ?? ""
        let limit = min(args["limit"]?.intValue ?? 10, 50)
        let q = query.lowercased()
        let matches = snapshot.memories
            .filter { mem in
                mem.subject.lowercased().contains(q) ||
                mem.content.lowercased().contains(q)
            }
            .prefix(limit)
        var lines: [String] = []
        for m in matches {
            let dateStr = ISO8601DateFormatter().string(from: m.createdAt)
            lines.append("- [\(m.kind)] \(m.subject) — \(m.content) (captured \(dateStr))")
        }
        if lines.isEmpty {
            return mcpTextResult("No memories matched «\(query)». Snapshot has \(snapshot.memories.count) total memories.")
        }
        return mcpTextResult(lines.joined(separator: "\n"))

    case "list_tasks":
        let status = args["status"]?.stringValue ?? "pending"
        let limit = min(args["limit"]?.intValue ?? 20, 100)
        let filtered = snapshot.tasks.filter { t in
            switch status {
            case "completed": return t.completed
            case "all":       return true
            default:          return !t.completed
            }
        }.prefix(limit)
        var lines: [String] = []
        for t in filtered {
            var line = t.completed ? "[x] " : "[ ] "
            line += t.description
            if let due = t.dueAt {
                line += " (due \(ISO8601DateFormatter().string(from: due)))"
            }
            lines.append("- " + line)
        }
        if lines.isEmpty {
            return mcpTextResult("No tasks matched status «\(status)». Snapshot has \(snapshot.tasks.count) total tasks.")
        }
        return mcpTextResult(lines.joined(separator: "\n"))

    case "recent_conversations":
        let limit = min(args["limit"]?.intValue ?? 10, 50)
        let sinceDays = args["since_days"]?.intValue
        var convos = snapshot.conversations
        if let sinceDays {
            let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
            convos = convos.filter { $0.finishedAt >= cutoff }
        }
        let slice = convos.prefix(limit)
        var lines: [String] = []
        for c in slice {
            let dateStr = ISO8601DateFormatter().string(from: c.finishedAt)
            var line = "## \(c.title)"
            if !c.project.isEmpty { line += " (project: \(c.project))" }
            line += "\n  \(dateStr)"
            if !c.overview.isEmpty { line += "\n  \(c.overview)" }
            lines.append(line)
        }
        if lines.isEmpty {
            return mcpTextResult("No conversations matched. Snapshot has \(snapshot.conversations.count) total.")
        }
        return mcpTextResult(lines.joined(separator: "\n\n"))

    case "search_conversations":
        let query = args["query"]?.stringValue ?? ""
        let limit = min(args["limit"]?.intValue ?? 5, 50)
        let q = query.lowercased()
        let matches = snapshot.conversations
            .filter { c in
                c.title.lowercased().contains(q) ||
                c.overview.lowercased().contains(q) ||
                c.project.lowercased().contains(q)
            }
            .prefix(limit)
        var lines: [String] = []
        for c in matches {
            let dateStr = ISO8601DateFormatter().string(from: c.finishedAt)
            var line = "## \(c.title)"
            if !c.project.isEmpty { line += " (project: \(c.project))" }
            line += "\n  \(dateStr)"
            if !c.overview.isEmpty { line += "\n  \(c.overview)" }
            lines.append(line)
        }
        if lines.isEmpty {
            return mcpTextResult("No conversations matched «\(query)».")
        }
        return mcpTextResult(lines.joined(separator: "\n\n"))

    default:
        return mcpTextResult("Unknown tool: \(name)")
    }
}

/// Wrap a string in the MCP `content` array envelope expected by
/// `tools/call` responses.
func mcpTextResult(_ text: String) -> JSONValue {
    .object([
        "content": .array([
            .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        ])
    ])
}

// MARK: - JSON-RPC main loop

/// Sum-type wrapping either a success response or an error. We can't return
/// `any Encodable` directly from `handle(...)` because Swift's existential
/// `any Encodable` doesn't itself conform to `Encodable` (the protocol has
/// `Self` requirements). This enum handles the dispatch explicitly.
enum RPCReply: Encodable {
    case success(RPCResponse)
    case failure(RPCError)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .success(let r): try c.encode(r)
        case .failure(let e): try c.encode(e)
        }
    }
}

func handle(request: RPCRequest) -> RPCReply? {
    let id = request.id

    switch request.method {
    case "initialize":
        // MCP handshake. Return our server info + protocol version.
        guard let id else { return nil }  // notification — won't happen for initialize, defensive
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("metawhisp-mcp"),
                "version": .string("1.0.0")
            ])
        ])
        return .success(RPCResponse(id: id, result: result))

    case "initialized", "notifications/initialized":
        // Notification — no reply.
        return nil

    case "tools/list":
        guard let id else { return nil }
        let toolsArray: [JSONValue] = mcpTools.values.map { $0 }
        return .success(RPCResponse(id: id, result: .object(["tools": .array(toolsArray)])))

    case "tools/call":
        guard let id else { return nil }
        let params = request.params?.objectValue ?? [:]
        let name = params["name"]?.stringValue ?? ""
        let args = params["arguments"]?.objectValue ?? [:]
        let result = executeTool(name: name, args: args)
        return .success(RPCResponse(id: id, result: result))

    case "shutdown", "notifications/cancelled":
        return nil

    default:
        guard let id else { return nil }
        return .failure(RPCError(
            id: id,
            error: .init(code: -32601, message: "Method not found: \(request.method)")
        ))
    }
}

// MARK: - Entry point

// Configure encoders/decoders we reuse.
let outEncoder = JSONEncoder()
outEncoder.dateEncodingStrategy = .iso8601
let inDecoder = JSONDecoder()
inDecoder.dateDecodingStrategy = .iso8601

// stderr logger — Claude Desktop's MCP log shows these without affecting
// the stdio protocol channel.
func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

log("[metawhisp-mcp] starting (pid=\(getpid()), snapshot=\(snapshotPath().path))")

// Line-delimited JSON over stdin. Each line = one JSON-RPC message.
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
    let request: RPCRequest
    do {
        request = try inDecoder.decode(RPCRequest.self, from: data)
    } catch {
        log("[metawhisp-mcp] parse error: \(error.localizedDescription)")
        continue
    }
    guard let response = handle(request: request) else { continue }
    do {
        let respData = try outEncoder.encode(response)
        FileHandle.standardOutput.write(respData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        log("[metawhisp-mcp] encode error: \(error.localizedDescription)")
    }
}

log("[metawhisp-mcp] stdin closed, exiting")
