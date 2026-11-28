// metawhisp-cli — MetaWhisp tasks for AI agents and the terminal (FEAT-0006).
//
// `metawhisp-cli mcp start` is the MCP server Claude Code and Codex launch over stdio; `metawhisp-cli task …` is the
// command line. Neither opens MetaWhisp's store: every request goes to the running app over its local socket
// (`~/Library/Application Support/MetaWhisp/tracker.sock`); when the app is not running it is started quietly in
// the menu bar (no window) and waited for, at most 30 s (T11: the app is the only writer).

import Foundation
import MetaWhispTrackerKit

let argv = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let home = NSHomeDirectory()
let socketPath = TrackerClient.defaultSocketPath(environment: environment)
/// The agent session that started this tool, when an agent did.
let caller = AgentCaller.from(environment: environment)

func standardError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Starts MetaWhisp without a window or focus, by bundle id (where it is installed does not matter).
func launchApp() throws {
    struct LaunchFailure: Error, CustomStringConvertible { let description: String }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-j", "-b", environment["METAWHISP_BUNDLE_ID"] ?? "com.metawhisp.app"]
    let errors = Pipe()
    open.standardError = errors
    open.standardOutput = FileHandle.nullDevice
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw LaunchFailure(description: "MetaWhisp is not installed on this Mac (\(said))")
    }
}

func send(_ request: TrackerRequest) -> TrackerResponse {
    TrackerClient.sendLaunching(request, socketPath: socketPath, launch: launchApp)
}

func folder(cwdFlag: String?) -> String {
    let cwd = cwdFlag ?? environment["METAWHISP_CWD"] ?? FileManager.default.currentDirectoryPath
    return ProjectRoot.resolve(workingDirectory: cwd, home: home)
}

func serveMCP(cwdFlag: String?) -> Never {
    // Claude Code names the project folder for its MCP servers (CLAUDE_PROJECT_DIR): taken as given, like --cwd.
    let pinned = cwdFlag ?? environment["METAWHISP_CWD"]
        ?? environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    let session = MCPSession(cwd: pinned ?? FileManager.default.currentDirectoryPath, pinned: pinned != nil,
                             resolveRoot: { ProjectRoot.resolve(workingDirectory: $0, home: home) },
                             session: caller?.session, call: send)
    standardError("[metawhisp-cli] MCP server started (pid \(getpid()), socket \(socketPath))")
    // One queue owns the session; stdin is read here. A client that offers roots and never answers the question
    // gets its held calls answered with the process folder after 5 s (a gate needs a ceiling).
    let queue = DispatchQueue(label: "metawhisp-cli.mcp")
    func emit(_ lines: [String]) {
        for out in lines { FileHandle.standardOutput.write(Data((out + "\n").utf8)) }
    }
    while let line = readLine(strippingNewline: true) {
        queue.sync {
            emit(session.handle(line: line))
            if let asked = session.pendingRootsRequest {
                queue.asyncAfter(deadline: .now() + 5) { emit(session.giveUpOnRoots(ifStill: asked)) }
            }
        }
    }
    queue.sync {}
    exit(0)
}

func prettyJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

do {
    switch try TrackerCLI.parse(argv) {
    case .help(let usage):
        print(usage)
    case .instructions(let name):
        print(TrackerGuides.guide(named: name)?.text ?? "")
    case .mcpStart(let cwd):
        serveMCP(cwdFlag: cwd)
    case let .request(op, args, json):
        let reply = send(TrackerRequest(op: op, folder: folder(cwdFlag: try TrackerCLI.cwdOverride(argv)),
                                        client: caller?.client ?? "CLI", session: caller?.session, args: args))
        guard reply.ok else {
            standardError("\(reply.code?.rawValue ?? "ERROR"): \(reply.message ?? "failed")")
            exit(1)
        }
        if json, let data = reply.data { print(prettyJSON(data)) } else { print(reply.text ?? "") }
    }
} catch let usage as TrackerCLI.UsageError {
    standardError(usage.description)
    exit(2)
} catch {
    standardError("\(error)")
    exit(1)
}
