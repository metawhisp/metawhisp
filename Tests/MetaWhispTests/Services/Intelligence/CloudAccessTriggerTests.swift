import Combine
import XCTest
@testable import MetaWhisp

/// ITER-075 step 1 (1.5) — the summaries that wait for cloud access hear about
/// it once the setup settles on one that can work, and not again for the same
/// setup.
final class CloudAccessTriggerTests: XCTestCase {

    /// Runs the main run loop until `condition` holds, or two seconds pass.
    private func runLoop(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Lets well over one quiet period pass, for a check that nothing came.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testItSpeaksOnceTheSetupSettlesAndNotAgainForTheSameSetup() {
        let changes = PassthroughSubject<Void, Never>()
        var setup: String?
        var heard: [String] = []
        let subscription = CloudAccessTrigger.publisher(changes: changes.eraseToAnyPublisher(),
                                                        setup: { setup }, quietFor: .milliseconds(20))
            .sink { heard.append($0) }
        defer { subscription.cancel() }

        changes.send()
        settle()
        XCTAssertEqual(heard, [], "no access: nothing to announce")

        setup = "openai:1"
        for _ in 0..<3 { changes.send() }   // a key typed in, one keystroke at a time
        runLoop { heard.count == 1 }
        settle()
        XCTAssertEqual(heard, ["openai:1"], "once, after the typing stops")

        changes.send()                      // another setting changed
        settle()
        XCTAssertEqual(heard, ["openai:1"], "the same setup stays quiet")

        setup = "openai:2"
        changes.send()
        runLoop { heard.count == 2 }
        XCTAssertEqual(heard, ["openai:1", "openai:2"], "a new key is announced")

        setup = nil
        changes.send()
        settle()
        setup = "pro"
        changes.send()
        runLoop { heard.count == 3 }
        XCTAssertEqual(heard, ["openai:1", "openai:2", "pro"], "access lost, then back")
    }
}
