import Foundation
import MetaWhispTrackerKit

/// FEAT-0006 §8 (T9, D3) — an agent the Settings button connects.
enum ConnectableAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The agent's own command-line tool; registration goes through it, no config file is edited by hand.
    var command: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    func addArguments(cli: String) -> [String] {
        switch self {
        case .claudeCode: return ["mcp", "add", "-s", "user", MCPSession.serverName, "--", cli, "mcp", "start"]
        case .codex: return ["mcp", "add", MCPSession.serverName, "--", cli, "mcp", "start"]
        }
    }

    var removeArguments: [String] {
        switch self {
        case .claudeCode: return ["mcp", "remove", "-s", "user", MCPSession.serverName]
        case .codex: return ["mcp", "remove", MCPSession.serverName]
        }
    }

    /// Both agents' `mcp get` exit 0 for a registered server and 1 for none (checked 2026-11-27).
    var getArguments: [String] { ["mcp", "get", MCPSession.serverName] }

    /// The agent's global instructions, where the one rule goes.
    func instructionsPath(home: URL) -> URL {
        switch self {
        case .claudeCode: return home.appendingPathComponent(".claude/CLAUDE.md")
        case .codex: return home.appendingPathComponent(".codex/AGENTS.md")
        }
    }
}

/// FEAT-0006 §8 — Connect: register MetaWhisp's MCP server with the agent, then add the rule to its global
/// instructions. Disconnect: remove both. The user's own text in those files is never changed.
/// spec://tracker/FEAT-0006#connect
@MainActor
final class AgentConnector: ObservableObject {

    enum State: Equatable {
        case notConnected
        case connected
        case working
        case failed(String)
    }

    typealias Runner = (_ command: String, _ arguments: [String]) async -> (status: Int32, output: String)

    @Published private(set) var states: [ConnectableAgent: State] = [:]

    private let home: URL
    private let cliPath: String?
    private let run: Runner

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         cliPath: String? = AgentConnector.bundledCLIPath,
         run: @escaping Runner = AgentConnector.runInLoginShell) {
        self.home = home
        self.cliPath = cliPath
        self.run = run
        refresh()
    }

    func state(_ agent: ConnectableAgent) -> State { states[agent] ?? .notConnected }

    /// Connected = the rule is in the agent's instructions (Connect writes it last, after the registration).
    func refresh() {
        for agent in ConnectableAgent.allCases where states[agent] != .working {
            states[agent] = hasRule(agent) ? .connected : .notConnected
        }
    }

    func connect(_ agent: ConnectableAgent) async {
        guard let cliPath else {
            states[agent] = .failed("This MetaWhisp has no metawhisp-cli inside. Install MetaWhisp from its DMG.")
            return
        }
        states[agent] = .working
        _ = await run(agent.command, agent.removeArguments)   // an older entry, if any
        let added = await run(agent.command, agent.addArguments(cli: cliPath))
        if added.status == 127 {
            states[agent] = .failed("\(agent.displayName) was not found on this Mac. Install it, then press Connect again.")
            return
        }
        guard added.status == 0 else {
            let said = added.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no answer"
            states[agent] = .failed("\(agent.displayName) did not take the MetaWhisp server: \(said)")
            return
        }
        states[agent] = writeRule(agent, install: true) ?? .connected
    }

    func disconnect(_ agent: ConnectableAgent) async {
        states[agent] = .working
        let removed = await run(agent.command, agent.removeArguments)
        // A failed remove may only mean the server was not there: gone only when the agent's own `get` says it has no
        // such server (exit 1). Anything else — it is still there, or `get` failed too — keeps the rule, so Settings
        // keeps saying connected and says why (Codex review P2-11: it said disconnected).
        if removed.status != 0, removed.status != 127, await run(agent.command, agent.getArguments).status != 1 {
            let said = removed.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no answer"
            states[agent] = .failed("\(agent.displayName) kept the MetaWhisp server: \(said). Press Disconnect again.")
            return
        }
        states[agent] = writeRule(agent, install: false) ?? .notConnected
    }

    // MARK: - The instructions file

    private func hasRule(_ agent: ConnectableAgent) -> Bool {
        guard let text = try? String(contentsOf: agent.instructionsPath(home: home), encoding: .utf8) else { return false }
        return text.contains(TrackerGuides.blockStart) && text.contains(TrackerGuides.blockEnd)
    }

    /// Writes or strips the block; returns a failure state, or nil when it went through. Only a missing file counts
    /// as empty: a file that cannot be read as text is left alone (review P1-2), and a symlinked file is written
    /// through to its target, so it stays a link (review P2-6).
    private func writeRule(_ agent: ConnectableAgent, install: Bool) -> State? {
        let url = agent.instructionsPath(home: home).resolvingSymlinksInPath()
        let current: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                current = try String(contentsOf: url, encoding: .utf8)
            } catch {
                return .failed("\(url.path) could not be read as text, so it was left as it is. Add the MetaWhisp "
                               + "rule by hand or fix the file, then press Connect again.")
            }
        } else {
            current = nil
        }
        if !install && current == nil { return nil }
        let outcome = install ? AgentInstructionsFile.install(current) : AgentInstructionsFile.remove(current ?? "")
        switch outcome {
        case .unchanged:
            return nil
        case .refused(let why):
            return .failed("\(url.path): \(why)")
        case .written(let text):
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return .failed("Could not write \(url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Running the agent's own tool

    /// `metawhisp-cli` inside this app (`Contents/Helpers`), or next to the executable in a development build.
    nonisolated static var bundledCLIPath: String? {
        let fm = FileManager.default
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/metawhisp-cli").path
        if fm.isExecutableFile(atPath: helpers) { return helpers }
        if let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("metawhisp-cli").path,
           fm.isExecutableFile(atPath: sibling) { return sibling }
        return nil
    }

    /// Runs a command the way the user's terminal would find it: a login shell with the usual install folders on
    /// PATH (the app itself starts with a bare PATH). 127 = not found. Stops after 60 s.
    nonisolated static func runInLoginShell(_ command: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { done in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let script = #"export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"; "#
                + #"command -v "$0" >/dev/null 2>&1 || exit 127; exec "$0" "$@""#
            p.arguments = ["-lc", script, command] + arguments
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let output = OutputBox()
            let readerDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    output.append(chunk)
                }
                readerDone.signal()
            }
            p.terminationHandler = { proc in
                // A job the command left in the background may keep the output open: wait for it at most 2 s
                // (review P3-15), then answer with what was read.
                DispatchQueue.global().async {
                    _ = readerDone.wait(timeout: .now() + 2)
                    done.resume(returning: (proc.terminationStatus, String(decoding: output.data, as: UTF8.self)))
                }
            }
            do { try p.run() } catch {
                done.resume(returning: (127, "\(error)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
