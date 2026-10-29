import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsManualQuestionRaceTests: XCTestCase {
    func testTypedAnswerSurvivesAutomaticOff() async throws {
        let fakes = FakeLiveHintsEnvironment()
        let route = TokenRecordingRoute()
        let gate = RequestGate()
        route.fake.gate = { await gate.wait() }
        route.fake.replies = [MeetingAnswerReply(status: 200, retryAfter: nil,
                                                 text: "**The final review is Friday.**")]
        let environment = fakes.environment()
        environment.routes.pro = route
        let session = LiveHintsMeeting(environment: environment)
        await session.start()
        defer {
            gate.open()
            session.stop()
        }
        let question = "When is the final review?"
        fakes.state.updateQuestionText(question)
        fakes.state.submitQuestion()
        await waitUntil { route.fake.requests.count == 1 && gate.waiterCount == 1 }
        XCTAssertEqual(route.fake.requests.count, 1)
        XCTAssertTrue(route.fake.requests.first?.user.contains(MeetingAnswerPrompts.typedAsk(text: question)) == true)
        let token = try XCTUnwrap(route.token)

        fakes.defaults.set(false, forKey: fakes.autoAnswerKey)
        await waitUntil { !fakes.state.autoAnswerOn }
        XCTAssertFalse(fakes.state.autoAnswerOn)
        XCTAssertFalse(token.isCancelled)
        gate.open()
        await waitUntil { !fakes.state.answers.isEmpty || route.fake.requests.first?.wasCancelled == true }

        XCTAssertEqual(fakes.state.answers.map(\.headline), ["**The final review is Friday.**"])
        XCTAssertFalse(token.isCancelled)
        XCTAssertFalse(try XCTUnwrap(route.fake.requests.first).wasCancelled)
        XCTAssertEqual(route.fake.requests.count, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private final class TokenRecordingRoute: MeetingAnswerRoute {
        let fake = FakeRoute(routeName: "pro")
        var token: LiveHintsStopToken?
        var routeName: String { fake.routeName }
        var isAvailable: Bool { fake.isAvailable }

        func answer(system: String, user: String, deadlineMs: Int,
                    stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
            token = stopToken
            return try await fake.answer(system: system, user: user, deadlineMs: deadlineMs,
                                         stopToken: stopToken)
        }
    }
}
