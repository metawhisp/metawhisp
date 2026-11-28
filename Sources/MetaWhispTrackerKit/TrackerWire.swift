import Foundation

// FEAT-0006 §7 — what the command-line tool and the app say to each other over the local socket.

/// Free-form JSON: tool arguments, MCP messages.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Int.self) { self = .int(n); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Unknown JSON value"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let n): try c.encode(n)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Any `Encodable` as a JSON value (for `--json` and MCP structured results).
    public static func encoding<T: Encodable>(_ value: T) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public enum TrackerErrorCode: String, Codable, Sendable {
    case validation = "VALIDATION_ERROR"
    case taskNotFound = "TASK_NOT_FOUND"
    case noProject = "NO_PROJECT"
    case appUnavailable = "APP_UNAVAILABLE"
    case internalError = "INTERNAL_ERROR"
}

public struct TrackerFailure: Error, Equatable, Sendable {
    public var code: TrackerErrorCode
    public var message: String

    public init(_ code: TrackerErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func validation(_ message: String) -> TrackerFailure { .init(.validation, message) }
}

/// One request line. `folder` is the project root the tool resolved (§5.1); `client` names the agent.
public struct TrackerRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var op: String
    public var folder: String?
    public var client: String?
    /// One agent session: who took a task to In Progress (owner 2026-11-27, Q2) — the agent's own session id when it
    /// started the tool (`AgentCaller`), else the MCP server process. Absent for a person's command-line call and for
    /// an older tool; the client name stands in then.
    public var session: String?
    public var args: [String: JSONValue]

    public init(op: String, folder: String?, client: String?, session: String? = nil,
                args: [String: JSONValue] = [:]) {
        self.v = Self.currentVersion
        self.op = op
        self.folder = folder
        self.client = client
        self.session = session
        self.args = args
    }
}

/// One response line: the text an agent reads and, for `--json`, the data behind it.
public struct TrackerResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    public var data: JSONValue?
    public var code: TrackerErrorCode?
    public var message: String?

    public static func success(_ text: String, data: JSONValue? = nil) -> TrackerResponse {
        TrackerResponse(ok: true, text: text, data: data, code: nil, message: nil)
    }

    public static func failure(_ f: TrackerFailure) -> TrackerResponse {
        TrackerResponse(ok: false, text: nil, data: nil, code: f.code, message: f.message)
    }
}

/// Line framing shared by both ends: one JSON object per line, at most `maxBytes`.
public enum TrackerWire {
    public static let maxBytes = 1_048_576
    public static let timeoutSeconds: TimeInterval = 30
    public static let socketName = "tracker.sock"

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: line)
    }
}

/// The agent session a process runs in, from what the agent hands the commands it starts: Codex sets
/// `CODEX_SESSION_ID` (and `CODEX_THREAD_ID`), Claude Code `CLAUDE_CODE_SESSION_ID` (both seen 2026-11-27). Codex is
/// read first: one started from Claude Code inherits Claude's variables too. Nil for a person in a terminal or a script.
/// Before this the command line sent "CLI" with no session, so two agents using it were one (Codex review P2).
public struct AgentCaller: Equatable, Sendable {
    public let client: String
    public let session: String

    public init(client: String, session: String) {
        self.client = client
        self.session = session
    }

    public static func from(environment env: [String: String]) -> AgentCaller? {
        func value(_ key: String) -> String? {
            let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? nil : v
        }
        if let s = value("CODEX_SESSION_ID") ?? value("CODEX_THREAD_ID") { return AgentCaller(client: "Codex", session: s) }
        if let s = value("CLAUDE_CODE_SESSION_ID") { return AgentCaller(client: "Claude Code", session: s) }
        return nil
    }
}
