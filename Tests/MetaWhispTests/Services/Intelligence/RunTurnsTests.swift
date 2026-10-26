import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — a run handed in while another is going waits its
/// turn instead of being dropped.
@MainActor
final class RunTurnsTests: XCTestCase {

    private final class Probe: @unchecked Sendable {
        var log: [String] = []
        var release: CheckedContinuation<Void, Never>?
    }

    /// The second run starts only after the first has ended, and it runs:
    /// nothing is dropped.
    func testASecondRunWaitsForTheFirstAndIsNotDropped() async {
        let turns = RunTurns<String>()
        let probe = Probe()
        let first = Task { @MainActor in
            await turns.take {
                probe.log.append("first starts")
                await withCheckedContinuation { probe.release = $0 }
                probe.log.append("first ends")
                return "first"
            }
        }
        for _ in 0..<1_000 where probe.release == nil { await Task.yield() }
        XCTAssertNotNil(probe.release, "the first run never started")
        let second = Task { @MainActor in
            await turns.take {
                probe.log.append("second starts")
                return "second"
            }
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(probe.log, ["first starts"], "the second run waits for the first")
        probe.release?.resume()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual([firstResult, secondResult], ["first", "second"])
        XCTAssertEqual(probe.log, ["first starts", "first ends", "second starts"])
    }

    /// Once the runs before it are over, a run starts at once.
    func testARunAfterTheOthersEndedStartsAtOnce() async {
        let turns = RunTurns<Int>()
        let one = await turns.take { 1 }
        let two = await turns.take { 2 }
        XCTAssertEqual([one, two], [1, 2])
    }
}
