import XCTest
@testable import MetaWhisp

/// 2026-10-20 — the owner found the installed app running its errands on the older step pipeline while the brain
/// (one model deciding every step, the one measured on the blind set) lived in the bench alone. This scans the
/// SOURCE: the app's service makes every errand's run with the brain, on the product's arm, and never with the
/// older factory — so no refactor puts the old pipeline back without failing `swift test`.
final class AgentBrainGuardTests: XCTestCase {
    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/AgentBrainGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The source without its line comments: only code counts.
    private func code(of path: String) throws -> String {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        XCTAssertFalse(source.isEmpty, "the guard must read the source — path resolution broke")
        return source.components(separatedBy: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
            .joined(separator: "\n")
    }

    func testTheAppsErrandsRunOnTheBrainOfTheProductsArm() throws {
        let service = try code(of: "Services/Agent/Service/AgentService.swift")
        XCTAssertTrue(service.contains("makeRunner: AgentRun.thinking(brain: { ServerBrain(arm: ServerBrain.productArm) })"),
                      "the app's service must make its runs with the brain on the product's arm")
        XCTAssertFalse(service.contains("AgentRun.answering("), "the older step pipeline is the bench's, not the app's")
        XCTAssertEqual(ServerBrain.productArm, "minimax",
                       "the product's brain runs on MiniMax, Groq its fallback — our own providers, never OpenRouter (owner, 2026-10-21)")
    }
}
