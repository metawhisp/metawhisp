import XCTest
@testable import MetaWhisp

/// ITER-086 — the recorder talks to the audio system through `MicHardware`: never on the main thread, never waited on
/// past a deadline. On 2026-11-24 a call into Core Audio held MetaWhisp's main thread eight minutes after a call ended;
/// nothing in the app answered, dictation included.
@MainActor
final class MicHardwareTests: XCTestCase {

    func testTheWorkRunsOffTheMainThreadAndItsAnswerComesBackOnIt() async {
        let hardware = MicHardware(deadline: 2)
        let ran = SharedValue<Bool?>(nil)
        let answered = expectation(description: "answered")
        hardware.run({ ran.value = Thread.isMainThread; return 7 }, done: { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), 7)
            answered.fulfill()
        }, late: { _ in XCTFail("answered in time") })
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(ran.value, false, "never on the main thread")
    }

    /// A call that does not answer: the caller hears "not responding" at the deadline, and the main thread runs all
    /// the while; the late answer comes on its own.
    func testACallThatHangsIsNotRespondingAtTheDeadlineAndTheMainThreadRuns() async {
        let hardware = MicHardware(deadline: 0.1)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "done")
        let late = expectation(description: "late")
        var heard: Error?
        hardware.run({ release.wait(); return 1 }, done: { result in
            if case .failure(let error) = result { heard = error }
            done.fulfill()
        }, late: { result in
            XCTAssertEqual(try? result.get(), 1)
            late.fulfill()
        })
        var ticks = 0
        let ticking = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(10)) } }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(heard as? AudioRecordingService.RecordingError, .notResponding)
        XCTAssertGreaterThan(ticks, 3, "the main actor ran while the call hung")
        release.signal()
        await fulfillment(of: [late], timeout: 2)
        ticking.cancel()
    }
}

/// A value the tests share with a background thread.
final class SharedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
