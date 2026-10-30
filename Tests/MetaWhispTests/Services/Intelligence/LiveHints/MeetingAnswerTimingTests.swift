import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerTimingTests: XCTestCase {
    func testFormatUsesFirstDrawAndEndFromMonotonicRequestStart() async {
        let h = AnswerTimingHarness()
        let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
        // Scheduling time belongs to the request, before the task dispatches.
        h.advance(25)
        await h.waitForRequest()
        XCTAssertTrue(h.lines.isEmpty)
        h.advance(100)
        h.route.send(.delta("**ANSWER_PRIVATE_MARKER.**"))
        await h.wait { h.state.draft != nil }
        h.advance(75)
        h.route.send(.delta("\n- Another private point"))
        await h.wait { h.state.draft?.blocks.count == 2 }
        h.advance(300)
        h.route.end(200)
        await request?.value
        XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=pro first_draw_ms=125 end_ms=500 outcome=published status=200"])
    }

    func testPrivacyNeverLogsTranscriptAnswerTypedQuestionOrScreenText() async {
        let markers = ["TRANSCRIPT_PRIVATE_MARKER", "ANSWER_PRIVATE_MARKER", "TYPED_PRIVATE_MARKER", "SCREEN_PRIVATE_MARKER"]
        let h = AnswerTimingHarness()
        await appendThemLine(h.transcript, text: markers[0], from: 0)
        let typed = h.service.requestQuestion(markers[2])
        await h.waitForRequest()
        XCTAssertTrue(h.route.users[0].contains(markers[0]))
        XCTAssertTrue(h.route.users[0].contains(markers[2]))
        h.route.send(.delta("**\(markers[1]).**"))
        h.route.end(200)
        await typed?.value
        let screen = h.service.requestScreen()
        await h.waitForRequest(2)
        XCTAssertTrue(h.route.users[1].contains(markers[3]))
        h.route.send(.delta("**\(markers[1]).**"))
        h.route.end(200)
        await screen?.value
        XCTAssertEqual(h.lines.count, 2)
        for line in h.lines {
            for marker in markers { XCTAssertFalse(line.contains(marker), "Private marker reached the timing log") }
            XCTAssertNotNil(line.range(of: #"^\[LiveHints\] answer kind=(shortcut|automatic|typed|chip|questions|recap|more|screen) route=(pro|own-key|local) first_draw_ms=(-1|[0-9]+) end_ms=[0-9]+ outcome=(published|skipped|rejected|failed|cancelled|timeout) status=[0-9]+$"#, options: .regularExpression))
        }
    }

    func testEveryActionHasNoDraftTimingAndIncludesScreenCaptureTime() async {
        for action in [MeetingAnswerAction.questions, .recap, .more, .screen] {
            let h = AnswerTimingHarness(captureMilliseconds: 40)
            await h.seed()
            let request = action == .screen ? h.service.requestScreen() : h.service.requestAction(action)
            await h.waitForRequest()
            h.advance(60)
            h.route.send(.delta("Useful action response\n- A supporting detail"))
            h.route.end(200)
            await request?.value
            let elapsed = action == .screen ? 100 : 60
            XCTAssertEqual(h.lines, ["[LiveHints] answer kind=\(action.rawValue) route=pro first_draw_ms=-1 end_ms=\(elapsed) outcome=published status=200"])
            XCTAssertNil(h.state.draft)
        }
    }

    func testSkippedAutomaticHasNoFirstDraw() async {
        let h = AnswerTimingHarness()
        await h.service.themLineEnded(themLine(text: "TRANSCRIPT_PRIVATE_MARKER?", from: 0))
        await h.waitForRequest()
        h.advance(240)
        h.route.send(.delta("[no-answer]"))
        h.route.end(200)
        await h.wait { !h.service.isThinking }
        XCTAssertEqual(h.lines, ["[LiveHints] answer kind=automatic route=pro first_draw_ms=-1 end_ms=240 outcome=skipped status=200"])
        XCTAssertTrue(h.state.answers.isEmpty)
        h.service.stop()
    }

    func testShortcutAndAutomaticKinds() async {
        for kind in ["shortcut", "automatic"] {
            let h = AnswerTimingHarness()
            await appendThemLine(h.transcript, text: "TRANSCRIPT_PRIVATE_MARKER?", from: 0)
            let request: Task<Void, Never>?
            if kind == "automatic" {
                await h.service.themLineEnded(themLine(text: "TRANSCRIPT_PRIVATE_MARKER?", from: 0))
                request = nil
            } else {
                request = h.service.requestShortcut()
            }
            await h.waitForRequest()
            h.advance(17)
            h.route.send(.delta("**ANSWER_PRIVATE_MARKER.**"))
            h.route.end(200)
            await request?.value
            await h.wait { !h.service.isThinking }
            XCTAssertEqual(h.lines, ["[LiveHints] answer kind=\(kind) route=pro first_draw_ms=17 end_ms=17 outcome=published status=200"])
            h.service.stop()
        }
    }

    func testRoutesUseClosedNamesRatherThanAdapterText() async {
        for route in ["pro", "own-key", "local"] {
            let h = AnswerTimingHarness(route: route)
            let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
            await h.waitForRequest()
            h.advance(9)
            h.route.end(503)
            await request?.value
            XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=\(route) first_draw_ms=-1 end_ms=9 outcome=failed status=503"])
            h.service.stop()
        }
    }

    func testRejectedAndFailedTerminalsLogOnceWithStatus() async {
        for (status, outcome) in [(200, "rejected"), (401, "failed"), (500, "failed"), (408, "timeout"), (499, "cancelled")] {
            let h = AnswerTimingHarness()
            let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
            await h.waitForRequest()
            h.advance(30)
            h.route.send(.delta("INVALID_ANSWER_PRIVATE_MARKER"))
            h.route.end(status)
            await request?.value
            XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=pro first_draw_ms=-1 end_ms=30 outcome=\(outcome) status=\(status)"])
        }
    }

    func testCancellationAfterDrawLogsOnceAndLateEndDoesNotLogAgain() async {
        let h = AnswerTimingHarness()
        let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
        await h.waitForRequest()
        h.advance(12)
        h.route.send(.delta("**ANSWER_PRIVATE_MARKER.**"))
        await h.wait { h.state.draft != nil }
        h.advance(8)
        request?.cancel()
        await request?.value
        h.route.end(200)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=pro first_draw_ms=12 end_ms=20 outcome=cancelled status=0"])
    }

    func testDeadlineWithoutAnHTTPResponseLogsTimeoutAndZeroStatus() async {
        let h = AnswerTimingHarness()
        let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
        await h.waitForRequest()
        await h.wait { h.deadline != nil }
        h.advance(6_000)
        h.deadline?.yield(())
        await request?.value
        XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=pro first_draw_ms=-1 end_ms=6000 outcome=timeout status=0"])
    }

    func testValidDeadlinePartialLogsPublishedWithoutInventingHTTPStatus() async {
        let h = AnswerTimingHarness()
        let request = h.service.requestQuestion("TYPED_PRIVATE_MARKER")
        await h.waitForRequest()
        h.advance(20)
        h.route.send(.delta("**ANSWER_PRIVATE_MARKER.**"))
        await h.wait { h.state.draft != nil && h.deadline != nil }
        h.advance(5_980)
        h.deadline?.yield(())
        await request?.value
        XCTAssertEqual(h.lines, ["[LiveHints] answer kind=typed route=pro first_draw_ms=20 end_ms=6000 outcome=published status=0"])
        XCTAssertEqual(h.state.answers.count, 1)
    }

    func testNoDispatchedCardStreamEmitsNoTimingLine() async {
        let h = AnswerTimingHarness()
        h.route.isAvailable = false
        await h.service.requestQuestion("TYPED_PRIVATE_MARKER")?.value
        XCTAssertTrue(h.lines.isEmpty)
        XCTAssertTrue(h.route.users.isEmpty)
        XCTAssertEqual(h.state.status, MeetingAnswerStatus.noRoute)
    }
}

@MainActor
private final class AnswerTimingHarness {
    let state = MeetingCoachState()
    let transcript = LiveMeetingTranscript()
    let routes = MeetingAnswerRoutes()
    let route = TimingCardRoute()
    var now = ContinuousClock.now
    var lines: [String] = []
    var deadline: AsyncStream<Void>.Continuation?
    private let captureMilliseconds: Int
    lazy var service = MeetingAnswerService(
        transcript: transcript, routes: routes, timingNow: { [unowned self] in now },
        timingLog: { [unowned self] in lines.append($0) }, isAutoOn: { true }, state: state,
        screenEnabled: { true }, captureScreen: { [unowned self] in
            advance(captureMilliseconds)
            return "SCREEN_PRIVATE_MARKER"
        }, streamSleep: { [weak self] _ in
            let stream = AsyncStream<Void> { self?.deadline = $0 }
            for await _ in stream { break }
            try Task.checkCancellation()
        })

    init(route selected: String = "pro", captureMilliseconds: Int = 0) {
        self.captureMilliseconds = captureMilliseconds
        if selected == "pro" { routes.pro = route }
        else if selected == "own-key" { routes.ownKey = route }
        else { routes.local = route }
        state.arm(generation: 0)
        state.autoAnswerOn = true
    }
    func advance(_ milliseconds: Int) { now = now.advanced(by: .milliseconds(milliseconds)) }
    func seed() async {
        await appendThemLine(transcript, text: "TRANSCRIPT_PRIVATE_MARKER", from: 0)
        await service.publish(.init(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
                                    action: nil, blocks: [.headline("**PREVIOUS_ANSWER_PRIVATE_MARKER.**")],
                                    createdAt: Date()), heard: nil, boundary: nil)
    }
    func waitForRequest(_ count: Int = 1) async { await wait { self.route.users.count >= count } }
    func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }
}

@MainActor
private final class TimingCardRoute: MeetingAnswerRoute {
    let routeName = "ADAPTER_PRIVATE_MARKER"
    var isAvailable = true
    var users: [String] = []
    private var continuation: AsyncStream<MeetingAnswerStreamEvent>.Continuation?
    func answer(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        XCTFail("Card timing must use the stream")
        return .init(status: 500, retryAfter: nil, text: nil)
    }
    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        users.append(user)
        return AsyncStream { continuation = $0 }
    }
    func send(_ event: MeetingAnswerStreamEvent) { continuation?.yield(event) }
    func end(_ status: Int) {
        send(.end(.init(status: status, retryAfter: nil, text: nil)))
        continuation?.finish()
    }
}
