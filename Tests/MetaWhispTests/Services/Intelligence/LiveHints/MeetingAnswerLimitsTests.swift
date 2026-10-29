import XCTest
@testable import MetaWhisp

/// The limits of the answer service (T10).
///
/// The automatic checks are spaced, capped and paused; the shortcut is bound
/// by none of them.
@MainActor
final class MeetingAnswerLimitsTests: XCTestCase {

    // MARK: - The spacing

    /// Two checks less than six seconds apart do not both run.
    func testTwoChecksLessThanSixSecondsApartDoNotBothRun() async {
        let harness = makeAnswerHarness()
        await appendThemLine(harness.transcript, text: "the first question", from: 0)
        await harness.service.themLineEnded(themLine(text: "the first question", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        harness.clock.advance(by: MeetingAnswerService.automaticSpacing - 1)
        await appendThemLine(harness.transcript, text: "the second question", from: 32_000)
        await harness.service.themLineEnded(themLine(text: "the second question", from: 32_000))
        await harness.settle()

        XCTAssertEqual(harness.requestCount, 1, "the second check started inside the spacing")

        harness.clock.advance(by: 2)
        await harness.waitForRequests(2)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.requestCount, 2, "the waiting check never started")
    }

    /// A continuation is exempt from the spacing.
    func testAContinuationIsExemptFromTheSpacing() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "shall we ship", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship", from: 0))
        await harness.waitForRequests(1)

        // The same utterance, longer: it starts at once, without waiting for
        // the spacing to pass.
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(2)

        XCTAssertEqual(harness.requestCount, 2, "the continuation waited for the spacing")

        harness.latch.open()
        await harness.waitUntilIdle()
    }

    /// A continuation is counted toward the cap.
    func testAContinuationIsCountedTowardTheCap() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        await appendThemLine(harness.transcript, text: "shall we ship", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship", from: 0))
        await harness.waitForRequests(1)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(2)

        XCTAssertEqual(harness.service.startedAutomaticCheckCount, 2,
                       "the continuation was not counted")

        harness.latch.open()
        await harness.waitUntilIdle()
    }

    // MARK: - The cap

    /// The cap counts the checks that were superseded, and the check that
    /// would be the two hundred and forty-first does not start.
    func testTheCapCountsTheSupersededChecks() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        var expected = 0
        var sample = 0
        let rounds = MeetingAnswerService.automaticCap / 2

        for _ in 0..<rounds {
            harness.latch.close()
            harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)

            // A check that runs, and a continuation that supersedes it: two
            // started checks, one of them thrown away.
            await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: sample))
            expected += 1
            await harness.waitForRequests(expected)

            await harness.service.themLineEnded(themLine(text: "shall we ship on Friday then?", from: sample))
            expected += 1
            await harness.waitForRequests(expected)

            harness.latch.open()
            await harness.waitUntilIdle()
            sample += 32_000
        }

        XCTAssertEqual(harness.service.startedAutomaticCheckCount, MeetingAnswerService.automaticCap,
                       "the started checks were not counted as they started")

        // The next one is over the cap.
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
        await harness.service.themLineEnded(themLine(text: "one more question", from: sample))
        await harness.settle(0.4)

        XCTAssertEqual(harness.requestCount, MeetingAnswerService.automaticCap,
                       "a check started although the cap was reached")
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.automaticPaused(shortcutLabel: nil),
                       "the cap did not put the status line up")
    }

    /// The shortcut of the user changes while the backoff runs: the line
    /// that names it shows the new shortcut at once (§3.6).
    func testThePauseStatusFollowsTheShortcutDuringTheBackoff() async {
        let harness = makeAnswerHarness()
        harness.state.shortcutLabel = "⌃↩"
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 30, text: nil)]

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()
        XCTAssertEqual(harness.service.status, "Automatic answers paused — press ⌃↩",
                       "the line does not name the shortcut of the user")

        // The user sets another shortcut while the backoff runs.
        harness.state.shortcutLabel = "⌥O"
        harness.service.shortcutLabelChanged()

        XCTAssertEqual(harness.service.status, "Automatic answers paused — press ⌥O",
                       "the line still names the shortcut of before")

        // The shortcut is gone: the line asks for the help shortcut.
        harness.state.shortcutLabel = nil
        harness.service.shortcutLabelChanged()

        XCTAssertEqual(harness.service.status, "Automatic answers paused — press your help shortcut",
                       "the line still names a shortcut that is not registered")
    }

    // MARK: - The backoff

    /// The line that says the automatic answers are paused names the shortcut
    /// that is registered now — the one the user actually presses (§3.6).
    func testThePauseStatusNamesTheShortcutOfTheUser() async {
        let harness = makeAnswerHarness()
        harness.state.shortcutLabel = "⌥O"
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 30, text: nil)]

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, "Automatic answers paused — press ⌥O",
                       "the line does not name the shortcut of the user")
    }

    /// Without a registered shortcut the line asks for the help shortcut: the
    /// fixed ⌃↩ of the app is not the shortcut of this user (§3.6).
    func testThePauseStatusAsksForTheHelpShortcutWhenNoneIsRegistered() async {
        let harness = makeAnswerHarness()
        harness.state.shortcutLabel = nil
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 30, text: nil)]

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, "Automatic answers paused — press your help shortcut",
                       "the line does not ask for the help shortcut")
    }

    /// A 503 with a Retry-After pauses the automatic answers, and the pause
    /// is as long as the header says.
    func testA503PausesTheAutomaticAnswers() async {
        let transport = FakeProTransport(statusCode: 503, headers: ["Retry-After": "30"])
        let harness = makeAnswerHarness()
        harness.routes.pro = ProAnswerRoute(client: ProAdviceClient(
            licenseKey: { "a-license-key" },
            transport: { request in
                transport.requests.append(request)
                return transport.answer()
            }))

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitUntil { transport.requests.count >= 1 }
        await harness.waitUntilIdle()

        guard let pausedUntil = harness.service.automaticPausedUntil else {
            XCTFail("the 503 did not pause the automatic answers")
            return
        }
        XCTAssertEqual(pausedUntil.timeIntervalSince(harness.clock.now), 30, accuracy: 0.001)

        // While the pause holds, no automatic check starts.
        await harness.service.themLineEnded(themLine(text: "another question", from: 32_000))
        await harness.settle(0.3)
        XCTAssertEqual(transport.requests.count, 1, "a check started although the automatic answers were paused")
    }

    /// The shortcut runs while the automatic answers are paused.
    func testTheShortcutRunsWhileTheAutomaticAnswersArePaused() async {
        let transport = FakeProTransport(statusCode: 503, headers: ["Retry-After": "30"])
        let harness = makeAnswerHarness()
        harness.routes.pro = ProAnswerRoute(client: ProAdviceClient(
            licenseKey: { "a-license-key" },
            transport: { request in
                transport.requests.append(request)
                return transport.answer()
            }))

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitUntil { transport.requests.count >= 1 }
        await harness.waitUntilIdle()

        await harness.service.shortcutPressed()
        await harness.waitUntil { transport.requests.count >= 2 }
        await harness.waitUntilIdle()

        XCTAssertEqual(transport.requests.count, 2, "the shortcut did not run while the automatic answers were paused")
    }

    /// The pause is over: the line that says the automatic answers are
    /// paused goes away with it (§3.6).
    func testThePauseStatusGoesAwayWhenTheBackoffEnds() async {
        let harness = makeAnswerHarness()
        harness.pro.replies = [MeetingAnswerReply(status: 503, retryAfter: 30, text: nil)]
        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitForRequests(1)
        await harness.waitUntilIdle()

        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.automaticPaused(shortcutLabel: nil),
                       "the refusal did not put the line up")

        // The backoff is over.
        harness.clock.advance(by: 31)
        await harness.settle(0.6)

        XCTAssertNil(harness.service.status, "the line of the pause stayed after the pause")
    }

    /// The cap has room again: the line that says the automatic answers are
    /// paused goes away with it (§3.6).
    func testThePauseStatusGoesAwayWhenTheCapWindowEnds() async {
        let harness = makeAnswerHarness()
        harness.pro.gate = { [latch = harness.latch] in await latch.wait() }

        var expected = 0
        var sample = 0
        for _ in 0..<MeetingAnswerService.automaticCap / 2 {
            harness.latch.close()
            harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
            await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: sample))
            expected += 1
            await harness.waitForRequests(expected)
            await harness.service.themLineEnded(themLine(text: "shall we ship on Friday then?", from: sample))
            expected += 1
            await harness.waitForRequests(expected)
            harness.latch.open()
            await harness.waitUntilIdle()
            sample += 32_000
        }

        // The next one is over the cap.
        harness.clock.advance(by: MeetingAnswerService.automaticSpacing + 1)
        await harness.service.themLineEnded(themLine(text: "one more question", from: sample))
        await harness.settle(0.4)
        XCTAssertEqual(harness.service.status, MeetingAnswerStatus.automaticPaused(shortcutLabel: nil),
                       "the cap did not put the line up")

        // The rolling hour frees the room: the checks of the first hour fall
        // out of it.
        harness.clock.advance(by: MeetingAnswerService.automaticCapWindow + 1)
        await harness.settle(0.6)

        XCTAssertNil(harness.service.status, "the line of the cap stayed after the window")
    }

    /// The 503 that has no Retry-After pauses for a minute.
    func testA503WithoutARetryAfterPausesForAMinute() async {
        let transport = FakeProTransport(statusCode: 503, headers: [:])
        let harness = makeAnswerHarness()
        harness.routes.pro = ProAnswerRoute(client: ProAdviceClient(
            licenseKey: { "a-license-key" },
            transport: { request in
                transport.requests.append(request)
                return transport.answer()
            }))

        await appendThemLine(harness.transcript, text: "shall we ship on Friday?", from: 0)
        await harness.service.themLineEnded(themLine(text: "shall we ship on Friday?", from: 0))
        await harness.waitUntil { transport.requests.count >= 1 }
        await harness.waitUntilIdle()

        guard let pausedUntil = harness.service.automaticPausedUntil else {
            XCTFail("the 503 did not pause the automatic answers")
            return
        }
        XCTAssertEqual(pausedUntil.timeIntervalSince(harness.clock.now),
                       MeetingAnswerService.defaultRetryAfter,
                       accuracy: 0.001)
    }
}

/// The transport of the Pro route, answered by the test.
final class FakeProTransport: @unchecked Sendable {
    /// The requests the client built.
    var requests: [URLRequest] = []
    private let statusCode: Int
    private let headers: [String: String]

    init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    /// The answer the transport gives.
    func answer() -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: URL(string: "https://api.metawhisp.com/api/pro/advice")!,
                                       statusCode: statusCode,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        let body: [String: Any] = statusCode == 200 ? ["text": "**The answer.**"] : ["error": "busy"]
        return (try! JSONSerialization.data(withJSONObject: body), response)
    }
}
