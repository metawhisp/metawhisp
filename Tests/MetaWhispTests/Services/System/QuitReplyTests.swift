import AppKit
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 9d, № 20 — the app's one answer to a quit that waits: the
/// agent's stopped runs closing their tabs and a meeting's rescue are one wait,
/// each part ended once — done, or out of its time — and the answer goes once,
/// when the last part has. With nothing to wait for, the app quits at once.
@MainActor
final class QuitReplyTests: XCTestCase {

    /// A quit as the app answers it, with the timers the test fires and the
    /// answers it counts.
    @MainActor
    private final class Quit {
        var timers: [(delay: Duration, action: @MainActor () -> Void)] = []
        var answers = 0
        lazy var reply = QuitReply(schedule: { [unowned self] delay, action in self.timers.append((delay, action)) },
                                   send: { [unowned self] in self.answers += 1 })

        /// The timer set for `delay` goes off, as if its time had passed.
        func fire(after delay: Duration, file: StaticString = #filePath, line: UInt = #line) {
            guard let index = timers.firstIndex(where: { $0.delay == delay }) else {
                return XCTFail("no timer set for \(delay)", file: file, line: line)
            }
            timers.remove(at: index).action()
        }
    }

    func testWithNothingToWaitForTheAppQuitsNow() {
        let quit = Quit()
        XCTAssertEqual(quit.reply.answer, .terminateNow)
        XCTAssertEqual(quit.answers, 0, "no answer is sent for a quit that did not wait")
    }

    /// The errands' wait: the answer goes once their stopped runs returned —
    /// not before, and never twice.
    func testTheAnswerWaitsUntilTheStoppedRunsReturnedAndGoesOnce() {
        let quit = Quit()
        let returned = quit.reply.wait(within: AgentRun.stopLimit)
        XCTAssertEqual(quit.reply.answer, .terminateLater)
        XCTAssertEqual(quit.answers, 0, "the tab is not closed yet")
        returned()
        XCTAssertEqual(quit.answers, 1)
        returned()
        quit.fire(after: AgentRun.stopLimit)
        XCTAssertEqual(quit.answers, 1, "one answer")
    }

    /// A run that never returns does not hold the quit: its part ends at its
    /// limit, Stop's 10 s.
    func testAPartThatNeverEndsIsLetGoAtItsLimit() {
        let quit = Quit()
        _ = quit.reply.wait(within: AgentRun.stopLimit)
        XCTAssertEqual(quit.timers.map(\.delay), [AgentRun.stopLimit])
        XCTAssertEqual(quit.answers, 0)
        quit.fire(after: AgentRun.stopLimit)
        XCTAssertEqual(quit.answers, 1)
    }

    /// A meeting and an errand at the quit: one `.terminateLater`, one answer,
    /// once both parts ended — whichever ends last, by being done or by its
    /// time.
    func testTheMeetingAndTheErrandsAreOneWaitAndOneAnswer() {
        let quit = Quit()
        let returned = quit.reply.wait(within: AgentRun.stopLimit)
        let rescued = quit.reply.wait(within: .seconds(MeetingShutdown.rescueDeadlineSeconds))
        XCTAssertEqual(quit.reply.answer, .terminateLater)
        rescued()
        XCTAssertEqual(quit.answers, 0, "the errands' tabs are still closing")
        quit.fire(after: .seconds(MeetingShutdown.rescueDeadlineSeconds))
        XCTAssertEqual(quit.answers, 0, "a part ends once")
        returned()
        XCTAssertEqual(quit.answers, 1)
        quit.fire(after: AgentRun.stopLimit)
        XCTAssertEqual(quit.answers, 1, "one answer")
    }

    /// The bound of the whole wait: the errands' 10 s at most, the meeting's
    /// 6 s within it.
    func testTheWaitIsBoundedByTheErrandsTenSeconds() {
        XCTAssertEqual(AgentRun.stopLimit, .seconds(10))
        XCTAssertLessThanOrEqual(Duration.seconds(MeetingShutdown.rescueDeadlineSeconds), AgentRun.stopLimit)
    }
}
