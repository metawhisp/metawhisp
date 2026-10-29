import XCTest
@testable import MetaWhisp

/// A live call with a deadline. The four outcomes stay apart: the text, a
/// timeout, a cancellation and the error itself — a caller must be able to
/// tell "the engine was slow" from "the monthly minutes are gone".
final class LiveCallTests: XCTestCase {

    // MARK: - The outcomes

    /// The work returns in time: the caller gets its text.
    func testTheTextComesBackWhenTheWorkFinishesInTime() async {
        let outcome = await LiveCall.run(within: .seconds(5)) { "the text" }

        guard case .text(let text) = outcome else {
            return XCTFail("the call did not return its text — \(outcome)")
        }
        XCTAssertEqual(text, "the text")
    }

    /// The work throws: the error comes back as it was thrown.
    func testAFailedWorkKeepsItsError() async {
        struct EngineError: Error, Equatable {
            let code: Int
        }

        let outcome = await LiveCall.run(within: .seconds(5)) { () -> String in
            throw EngineError(code: 42)
        }

        guard case .failed(let error) = outcome else {
            return XCTFail("the call did not return the error — \(outcome)")
        }
        XCTAssertEqual(error as? EngineError, EngineError(code: 42),
                       "the error came back as something else")
    }

    /// A cancelled call says so, and the work stops with it.
    func testACancelledCallSaysCancelled() async {
        let stopped = expectation(description: "the work stopped")
        let task = Task {
            await LiveCall.run(within: .seconds(30)) { () -> String in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    stopped.fulfill()
                    throw error
                }
                return "never"
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let outcome = await task.value

        guard case .cancelled = outcome else {
            return XCTFail("the call did not say it was cancelled — \(outcome)")
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    // MARK: - The timeout

    /// The deadline comes first: the caller is told at once, and the work
    /// goes on to completion.
    func testATimeoutComesAtTheDeadlineWhileTheWorkGoesOn() async {
        let started = expectation(description: "the work started")
        let finished = expectation(description: "the work finished")
        let finishedOutcome = LiveValueBox<LiveCall.Outcome<String>>(.cancelled)

        let outcome = await LiveCall.run(within: .milliseconds(100), onFinish: { outcome in
            finishedOutcome.value = outcome
            finished.fulfill()
        }) { () -> String in
            started.fulfill()
            // The work listens for a cancellation: a timeout must not send
            // one, or the work would never reach its text.
            try await Task.sleep(nanoseconds: 600_000_000)
            return "the late text"
        }

        await fulfillment(of: [started], timeout: 2)
        guard case .timeout = outcome else {
            return XCTFail("the call did not time out — \(outcome)")
        }

        // The work was not cancelled by the timeout: it finished on its own.
        await fulfillment(of: [finished], timeout: 3)
        guard case .text(let text) = finishedOutcome.value else {
            return XCTFail("the work did not finish with its text — \(String(describing: finishedOutcome.value))")
        }
        XCTAssertEqual(text, "the late text")
    }

    /// The work that finished before the deadline is told once, with its own
    /// outcome.
    func testTheWorkIsToldWhenItFinished() async {
        let finished = expectation(description: "the work finished")
        let finishedOutcome = LiveValueBox<LiveCall.Outcome<String>>(.cancelled)

        let outcome = await LiveCall.run(within: .seconds(5), onFinish: { outcome in
            finishedOutcome.value = outcome
            finished.fulfill()
        }) { "the text" }

        await fulfillment(of: [finished], timeout: 2)
        guard case .text(let text) = outcome, case .text(let told) = finishedOutcome.value else {
            return XCTFail("the outcome and the telling disagree — \(outcome)")
        }
        XCTAssertEqual(text, told)
    }
}

/// A box a `@Sendable` closure may write into — a captured `var` cannot be
/// written from one.
final class LiveValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        self.stored = value
    }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
