import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §8 — Connect registers MetaWhisp's MCP server with the agent's own CLI and puts one block into its
/// global instructions; Disconnect takes both away. The user's own text is never changed.
final class AgentInstructionsFileTests: XCTestCase {

    private let block = TrackerGuides.agentBlock

    func testAMissingFileGetsTheBlock() {
        XCTAssertEqual(AgentInstructionsFile.install(nil), .written(block + "\n"))
    }

    func testTheBlockGoesAfterTheUsersTextAndAGap() {
        XCTAssertEqual(AgentInstructionsFile.install("# My rules\n- be brief\n"),
                       .written("# My rules\n- be brief\n\n" + block + "\n"))
        XCTAssertEqual(AgentInstructionsFile.install("# My rules"), .written("# My rules\n\n" + block + "\n"))
    }

    func testConnectingTwiceKeepsOneBlock() {
        guard case let .written(once) = AgentInstructionsFile.install("# Mine\n") else { return XCTFail() }
        XCTAssertEqual(AgentInstructionsFile.install(once), .unchanged)
    }

    func testAnOlderBlockIsReplacedWhereItStands() {
        let old = "# Top\n\n\(TrackerGuides.blockStart)\nold words\n\(TrackerGuides.blockEnd)\n\n# Bottom\n"
        XCTAssertEqual(AgentInstructionsFile.install(old), .written("# Top\n\n" + block + "\n\n# Bottom\n"))
    }

    func testAStartWithoutItsEndLeavesTheFileAlone() {
        let broken = "# Top\n\(TrackerGuides.blockStart)\nhalf a block\n"
        guard case .refused = AgentInstructionsFile.install(broken) else { return XCTFail() }
        guard case .refused = AgentInstructionsFile.remove(broken) else { return XCTFail() }
    }

    func testDisconnectGivesBackExactlyTheUsersText() {
        let mine = "# My rules\n- be brief\n"
        guard case let .written(connected) = AgentInstructionsFile.install(mine) else { return XCTFail() }
        XCTAssertEqual(AgentInstructionsFile.remove(connected), .written(mine))
        XCTAssertEqual(AgentInstructionsFile.remove(mine), .unchanged)
        let middle = "# Top\n\n" + block + "\n\n# Bottom\n"
        XCTAssertEqual(AgentInstructionsFile.remove(middle), .written("# Top\n\n# Bottom\n"))
    }

    func testTheBlockSaysTheRule() {
        XCTAssertTrue(block.hasPrefix(TrackerGuides.blockStart))
        XCTAssertTrue(block.hasSuffix(TrackerGuides.blockEnd))
        XCTAssertTrue(block.contains("get_metawhisp_instructions"))
        XCTAssertTrue(block.contains("working folder"))
        XCTAssertTrue(block.contains("Delete forever only an archived task"))
    }
}

@MainActor
final class AgentConnectorTests: XCTestCase {

    private var home: URL!
    private var runs: [(command: String, args: [String])] = []
    private var exitCode: Int32 = 0

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func connector(cli: String? = "/Applications/MetaWhisp.app/Contents/Helpers/metawhisp-cli") -> AgentConnector {
        AgentConnector(home: home, cliPath: cli) { [unowned self] command, args in
            runs.append((command, args))
            return (exitCode, exitCode == 0 ? "ok" : "boom")
        }
    }

    func testTheAgentsOwnCommandsRegisterAndRemoveTheServer() {
        let cli = "/Applications/MetaWhisp.app/Contents/Helpers/metawhisp-cli"
        XCTAssertEqual(ConnectableAgent.claudeCode.addArguments(cli: cli),
                       ["mcp", "add", "-s", "user", "metawhisp", "--", cli, "mcp", "start"])
        XCTAssertEqual(ConnectableAgent.claudeCode.removeArguments, ["mcp", "remove", "-s", "user", "metawhisp"])
        XCTAssertEqual(ConnectableAgent.codex.addArguments(cli: cli), ["mcp", "add", "metawhisp", "--", cli, "mcp", "start"])
        XCTAssertEqual(ConnectableAgent.codex.removeArguments, ["mcp", "remove", "metawhisp"])
        XCTAssertEqual(ConnectableAgent.claudeCode.instructionsPath(home: home).path, home.path + "/.claude/CLAUDE.md")
        XCTAssertEqual(ConnectableAgent.codex.instructionsPath(home: home).path, home.path + "/.codex/AGENTS.md")
    }

    func testConnectRegistersThenWritesTheRule() async throws {
        let c = connector()
        await c.connect(.claudeCode)
        XCTAssertEqual(runs.map(\.command), ["claude", "claude"])
        XCTAssertEqual(runs.first?.args, ConnectableAgent.claudeCode.removeArguments, "an old entry goes first")
        XCTAssertEqual(runs.last?.args.prefix(5), ["mcp", "add", "-s", "user", "metawhisp"])
        let text = try String(contentsOf: ConnectableAgent.claudeCode.instructionsPath(home: home), encoding: .utf8)
        XCTAssertTrue(text.contains(TrackerGuides.blockStart))
        XCTAssertEqual(c.state(.claudeCode), .connected)
        XCTAssertEqual(c.state(.codex), .notConnected)
    }

    func testAMissingAgentIsSaidAndNothingIsWritten() async {
        exitCode = 127
        let c = connector()
        await c.connect(.codex)
        XCTAssertEqual(c.state(.codex), .failed("Codex was not found on this Mac. Install it, then press Connect again."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConnectableAgent.codex.instructionsPath(home: home).path))
    }

    func testABuildWithoutTheToolCannotConnect() async {
        let c = connector(cli: nil)
        await c.connect(.claudeCode)
        XCTAssertTrue(runs.isEmpty)
        guard case .failed = c.state(.claudeCode) else { return XCTFail() }
    }

    func testDisconnectRemovesTheServerAndOnlyTheRule() async throws {
        let file = ConnectableAgent.codex.instructionsPath(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Mine\n".write(to: file, atomically: true, encoding: .utf8)
        let c = connector()
        await c.connect(.codex)
        runs = []
        await c.disconnect(.codex)
        XCTAssertEqual(runs.map(\.args), [ConnectableAgent.codex.removeArguments])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Mine\n")
        XCTAssertEqual(c.state(.codex), .notConnected)
    }

    /// Codex review P2-11 — the agent refused the removal and still has the server: the rule stays, the failure shows.
    func testARefusedRemovalKeepsTheRuleAndSaysSo() async throws {
        let file = ConnectableAgent.codex.instructionsPath(home: home)
        let c = connector()
        await c.connect(.codex)
        exitCode = 1   // remove fails ...
        let still = AgentConnector(home: home, cliPath: "/x/metawhisp-cli") { [unowned self] _, args in
            runs.append(("codex", args))
            return args == ConnectableAgent.codex.getArguments ? (0, "metawhisp") : (1, "config is read-only")
        }
        runs = []
        await still.disconnect(.codex)
        XCTAssertEqual(runs.map(\.args), [ConnectableAgent.codex.removeArguments, ConnectableAgent.codex.getArguments])
        XCTAssertEqual(still.state(.codex), .failed("Codex kept the MetaWhisp server: config is read-only. Press Disconnect again."))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(TrackerGuides.blockStart), "the rule stays")
    }

    /// The agent's `get` failing too (a timeout) is no proof the server is gone: the rule stays.
    func testARemovalThatCannotBeCheckedKeepsTheRule() async throws {
        let file = ConnectableAgent.codex.instructionsPath(home: home)
        let c = connector()
        await c.connect(.codex)
        let unsure = AgentConnector(home: home, cliPath: "/x/metawhisp-cli") { _, args in
            args == ConnectableAgent.codex.getArguments ? (124, "timed out") : (1, "timed out")
        }
        await unsure.disconnect(.codex)
        guard case .failed = unsure.state(.codex) else { return XCTFail("must not say disconnected") }
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(TrackerGuides.blockStart))
    }

    /// ... and a failed removal of a server that was not there disconnects as before.
    func testARemovalOfAnAbsentServerStillDisconnects() async throws {
        let file = ConnectableAgent.codex.instructionsPath(home: home)
        let c = connector()
        await c.connect(.codex)
        exitCode = 1
        runs = []
        await c.disconnect(.codex)
        XCTAssertEqual(runs.map(\.args), [ConnectableAgent.codex.removeArguments, ConnectableAgent.codex.getArguments])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(TrackerGuides.blockStart))
        XCTAssertEqual(c.state(.codex), .notConnected)
    }

    func testTheStateComesFromTheInstructionsFile() async throws {
        let file = ConnectableAgent.claudeCode.instructionsPath(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("# x\n\n" + TrackerGuides.agentBlock + "\n").write(to: file, atomically: true, encoding: .utf8)
        let c = connector()
        c.refresh()
        XCTAssertEqual(c.state(.claudeCode), .connected)
    }

    /// Review P1-2: a file that cannot be read as text is never replaced by the block alone.
    func testAnUnreadableInstructionsFileIsLeftAlone() async throws {
        let file = ConnectableAgent.claudeCode.instructionsPath(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("# Mine\n".utf8) + Data([0xFF, 0xFE, 0x00, 0xC3]) + Data("\nmore\n".utf8)
        try bytes.write(to: file)
        let c = connector()
        await c.connect(.claudeCode)
        guard case .failed = c.state(.claudeCode) else { return XCTFail("must not write over it") }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        await c.disconnect(.claudeCode)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    /// Review P2-6: a dotfiles symlink stays a symlink; the rule lands in its target.
    func testASymlinkedInstructionsFileStaysALink() async throws {
        let target = home.appendingPathComponent("dotfiles/CLAUDE.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Mine\n".write(to: target, atomically: true, encoding: .utf8)
        let link = ConnectableAgent.claudeCode.instructionsPath(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let c = connector()
        await c.connect(.claudeCode)
        XCTAssertEqual(c.state(.claudeCode), .connected)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "still a link")
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(TrackerGuides.blockStart))
    }

    /// Review P3-15: a job left running in the background that keeps the output open cannot hold Connect.
    func testAJobHoldingTheOutputDoesNotHoldTheRunner() async {
        let started = Date()
        let r = await AgentConnector.runInLoginShell("sh", ["-c", "(sleep 20 &) ; echo started"])
        XCTAssertEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTheLoginShellRunnerFindsCommandsAndSaysWhenOneIsMissing() async {
        let found = await AgentConnector.runInLoginShell("echo", ["hello"])
        XCTAssertEqual(found.status, 0)
        XCTAssertTrue(found.output.contains("hello"), found.output)
        let missing = await AgentConnector.runInLoginShell("no-such-agent-cli-\(UUID().uuidString.prefix(6))", [])
        XCTAssertEqual(missing.status, 127)
    }
}

/// FEAT-0006 §8 — the bundle carries the agents' tool where the Connect button looks for it, signed before the app.
final class TrackerBundleScriptTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testBuildCopiesTheToolIntoHelpersAndSignsItBeforeTheApp() throws {
        let script = try source("build.sh")
        let copy = try XCTUnwrap(script.range(of: #"cp "$BUILD_DIR/metawhisp-cli" "$HELPERS/metawhisp-cli""#))
        let sign = try XCTUnwrap(script.range(of: #"sign_target "$HELPERS/metawhisp-cli" "com.metawhisp.cli""#))
        let outer = try XCTUnwrap(script.range(of: "# Sign outer bundle with our app identifier"))
        XCTAssertLessThan(copy.lowerBound, sign.lowerBound)
        XCTAssertLessThan(sign.lowerBound, outer.lowerBound, "nested code is signed before the bundle")
        XCTAssertTrue(script.contains(#"HELPERS="$CONTENTS/Helpers""#))
    }
}
