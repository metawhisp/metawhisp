import XCTest

/// ITER-075 step 1 (1.5) — every summary run takes its turn: `generate` hands
/// the run to `RunTurns`, and nothing drops a run because another is going.
/// A run dropped that way was never run again.
final class StructuredTurnsGuardTests: XCTestCase {

    private func generatorSource() throws -> String {
        // …/Tests/MetaWhispTests/Guards/StructuredTurnsGuardTests.swift → repo root
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Intelligence/StructuredGenerator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testGenerateHandsEveryRunToItsTurn() throws {
        let source = try generatorSource()
        let start = try XCTUnwrap(source.range(of: "func generate(conversationId: UUID"),
                                  "generate is gone — update the guard")
        XCTAssertTrue(source[start.upperBound...].prefix(600).contains("turns.take"),
                      "generate must run in its turn")
    }

    func testNoRunIsDroppedBecauseAnotherIsGoing() throws {
        XCTAssertFalse(try generatorSource().contains("guard !isRunning"),
                       "a run in flight must make the next one wait, not drop it")
    }
}
