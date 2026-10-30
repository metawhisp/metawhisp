import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerTerminalDeliveryTests: XCTestCase {
    func testPublicationCancelsPendingTransportBeforePublishingTheAnswer() async throws {
        let h = TerminalDeliveryHarness()
        defer { h.service.stop() }
        let request = h.service.requestQuestion("Which milestone comes next?")
        await h.wait { h.route.handle != nil }
        h.route.send(.delta("**Confirm the next milestone.**"))
        await h.wait { h.state.draft != nil }
        var cancelledAtPublication: Bool?
        let observer = h.state.$answers.dropFirst().sink { answers in
            if !answers.isEmpty { cancelledAtPublication = h.route.handle?.isCancelled }
        }

        h.route.send(.end(.init(status: 200, retryAfter: nil, text: nil)))
        await request?.value

        XCTAssertEqual(cancelledAtPublication, true)
        XCTAssertEqual(h.state.answers.first?.headline, "**Confirm the next milestone.**")
        XCTAssertNil(h.state.draft)
        withExtendedLifetime(observer) {}
    }

    func testRejectedAndCancelledTerminalsCancelPendingTransportBeforeClearingDraft() async {
        for status in [500, 499] {
            let h = TerminalDeliveryHarness()
            let request = h.service.requestQuestion("Which milestone comes next?")
            await h.wait { h.route.handle != nil }
            h.route.send(.delta("**Temporary milestone.**"))
            await h.wait { h.state.draft != nil }
            var cancelledAtClear: Bool?
            let observer = h.state.$draft.dropFirst().sink { draft in
                if draft == nil { cancelledAtClear = h.route.handle?.isCancelled }
            }

            h.route.send(.end(.init(status: status, retryAfter: nil, text: nil)))
            await request?.value

            XCTAssertEqual(cancelledAtClear, true, "status \(status)")
            XCTAssertNil(h.state.draft)
            XCTAssertTrue(h.state.answers.isEmpty)
            h.service.stop()
            withExtendedLifetime(observer) {}
        }
    }

    func testStoppedRequestRejectsLateTransportDelta() async throws {
        let h = TerminalDeliveryHarness()
        let request = h.service.requestQuestion("Which milestone comes next?")
        await h.wait { h.route.handle != nil }
        h.route.send(.delta("**Temporary milestone.**"))
        await h.wait { h.state.draft != nil }

        h.service.stop()
        XCTAssertTrue(try XCTUnwrap(h.route.handle).isCancelled)
        h.route.send(.delta("\n- This arrived after cancellation."))
        h.route.send(.end(.init(status: 200, retryAfter: nil, text: nil)))
        await request?.value

        XCTAssertNil(h.state.draft)
        XCTAssertTrue(h.state.answers.isEmpty)
    }
}

@MainActor
private final class TerminalDeliveryHarness {
    let state = MeetingCoachState()
    let route = TerminalDeliveryRoute()
    let service: MeetingAnswerService

    init() {
        state.arm(generation: 1)
        let routes = MeetingAnswerRoutes()
        routes.pro = route
        service = MeetingAnswerService(transcript: LiveMeetingTranscript(), routes: routes,
            timingLog: { _ in }, diagnosticLog: { _ in }, generation: { 1 }, state: state)
    }

    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The controlled stream did not reach the expected state.")
    }
}

@MainActor
private final class TerminalDeliveryRoute: MeetingAnswerRoute {
    let routeName = "terminal-delivery-test"
    var isAvailable = true
    var handle: LiveHintsRequestHandle?
    private var continuation: AsyncStream<MeetingAnswerStreamEvent>.Continuation?

    func answer(system: String, user: String, deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        XCTFail("The card must use its stream route.")
        return .init(status: 500, retryAfter: nil, text: nil)
    }

    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        self.handle = handle
        return AsyncStream { self.continuation = $0 }
    }

    func send(_ event: MeetingAnswerStreamEvent) { continuation?.yield(event) }
}
