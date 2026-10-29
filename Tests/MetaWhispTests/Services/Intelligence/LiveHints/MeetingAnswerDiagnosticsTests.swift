import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerDiagnosticsTests: XCTestCase {
    func testEverySuccessfulManualEntryLogsOnceBeforeScheduling() async {
        for kind in ["shortcut", "typed", "questions", "recap", "more", "screen"] {
            let h = DiagnosticsHarness()
            await h.seed()
            let request = h.request(kind)
            XCTAssertEqual(h.lines, [entry(kind)])
            await request?.value
            XCTAssertEqual(h.lines, [entry(kind)])
            XCTAssertEqual(h.route.requests.count, 1)
        }
    }

    func testRepeatGuardLogsOneExitWithoutDispatchingAgain() async {
        let h = DiagnosticsHarness()
        await h.seed()
        await h.service.requestShortcut()?.value
        XCTAssertNil(h.service.requestShortcut())
        XCTAssertEqual(h.lines, [entry("shortcut"), entry("shortcut"), exit("shortcut", "repeat_guard")])
        XCTAssertEqual(h.route.requests.count, 1)
    }

    func testEmptyTranscriptPreflightsLogTheirClosedReason() async {
        for kind in ["shortcut", "questions", "recap"] {
            let h = DiagnosticsHarness()
            await h.request(kind)?.value
            XCTAssertEqual(h.lines, [entry(kind), exit(kind, "empty_transcript")])
            XCTAssertTrue(h.route.requests.isEmpty)
        }
    }

    func testMoreRefusalsLogOnceForMissingIneligibleOrDraftCards() {
        for source in ["none", "recap", "screen", "draft"] {
            let h = DiagnosticsHarness()
            if source != "none" {
                h.state.publish(.init(id: UUID(), heard: nil,
                    kind: source == "draft" ? .answer : .action,
                    provenance: source == "screen" ? .screen : .transcript,
                    action: source == "recap" ? .recap : nil,
                    blocks: [.headline("**PRIVATE_ANSWER_MARKER.**")], createdAt: h.clock.now))
            }
            if source == "draft" {
                h.state.showDraft(.init(requestID: UUID(), generation: 1, kind: .answer,
                    heard: nil, blocks: [.headline("**PRIVATE_DRAFT_MARKER.**")]))
            }
            XCTAssertNil(h.service.requestAction(.more))
            XCTAssertEqual(h.lines, [entry("more"), exit("more", "no_expandable_card")])
            XCTAssertTrue(h.route.requests.isEmpty)
        }
    }

    func testScreenSettingOffLogsBeforeCaptureAndAfterAwait() async {
        let off = DiagnosticsHarness()
        off.screenOn = false
        XCTAssertNil(off.service.requestScreen())
        XCTAssertEqual(off.lines, [entry("screen"), exit("screen", "setting_off")])
        XCTAssertEqual(off.captureCount, 0)

        let h = DiagnosticsHarness()
        let gate = RequestGate()
        h.captureGate = gate
        let request = h.service.requestScreen()
        await h.wait { gate.waiterCount == 1 }
        h.screenOn = false
        gate.open()
        await request?.value
        XCTAssertEqual(h.lines, [entry("screen"), exit("screen", "setting_off")])
        XCTAssertEqual(h.captureCount, 1)
        XCTAssertTrue(h.route.requests.isEmpty)
    }

    func testMissingAndBlankScreenLogOneExit() async {
        for captured: String? in [nil, "", " \n\t "] {
            let h = DiagnosticsHarness()
            h.captureResult = captured
            await h.service.requestScreen()?.value
            XCTAssertEqual(h.lines, [entry("screen"), exit("screen", "screen_nil")])
            XCTAssertTrue(h.route.requests.isEmpty)
        }
    }

    func testSupersededAwaitLogsOnceAndNeverLogsCapturedContent() async {
        let h = DiagnosticsHarness()
        let gate = RequestGate()
        h.captureGate = gate
        let screen = h.service.requestScreen()
        await h.wait { gate.waiterCount == 1 }
        await h.service.requestQuestion("PRIVATE_QUESTION_MARKER")?.value
        gate.open()
        await screen?.value
        XCTAssertEqual(h.lines, [entry("screen"), entry("typed"), exit("screen", "superseded")])
        XCTAssertEqual(h.route.requests.count, 1)
        XCTAssertFalse(h.route.requests[0].user.contains("PRIVATE_SCREEN_MARKER"))
    }

    func testStaleGenerationBeforeSchedulingLogsOnePreflightExit() async {
        let h = DiagnosticsHarness()
        let request = h.service.requestQuestion("PRIVATE_QUESTION_MARKER")
        h.generation += 1
        await request?.value
        XCTAssertEqual(h.lines, [entry("typed"), exit("typed", "superseded")])
        XCTAssertTrue(h.route.requests.isEmpty)
    }

    func testStoppedEntriesLogOneRefusal() async {
        for kind in ["shortcut", "typed", "questions", "screen"] {
            let h = DiagnosticsHarness()
            h.service.stop()
            await h.request(kind)?.value
            XCTAssertEqual(h.lines, [entry(kind), exit(kind, "superseded")])
            XCTAssertTrue(h.route.requests.isEmpty)
        }
    }

    func testNoRouteAndInvalidInputHaveExplicitPreflightReasons() async {
        let unavailable = DiagnosticsHarness()
        unavailable.route.isAvailable = false
        await unavailable.service.requestQuestion("PRIVATE_QUESTION_MARKER")?.value
        XCTAssertEqual(unavailable.lines, [entry("typed"), exit("typed", "no_route")])

        let empty = DiagnosticsHarness()
        XCTAssertNil(empty.service.requestQuestion(" \n "))
        XCTAssertEqual(empty.lines, [entry("typed"), exit("typed", "empty_question")])

        let unsupported = DiagnosticsHarness()
        XCTAssertNil(unsupported.service.requestAction(.screen))
        XCTAssertEqual(unsupported.lines, [entry("screen"), exit("screen", "unsupported_action")])
    }

    func testDiagnosticsUseOnlyClosedNamesAndNeverPrivateContent() async {
        let h = DiagnosticsHarness()
        await h.seed()
        h.route.replies = [.init(status: 200, retryAfter: nil, text: "**PRIVATE_ANSWER_MARKER.**")]
        await h.service.requestQuestion("PRIVATE_QUESTION_MARKER")?.value
        await h.service.requestScreen()?.value
        XCTAssertNil(h.service.requestScreen())
        XCTAssertEqual(h.lines.count, 4)
        for line in h.lines {
            XCTAssertFalse(line.contains("PRIVATE_"))
            XCTAssertNotNil(line.range(of: #"^\[LiveHints\] manual kind=(shortcut|typed|questions|recap|more|screen) phase=(entry|preflight_exit reason=(repeat_guard|empty_transcript|no_expandable_card|screen_nil|setting_off|superseded|no_route|empty_question|unsupported_action))$"#,
                                       options: .regularExpression))
        }
    }

    private func entry(_ kind: String) -> String {
        "[LiveHints] manual kind=\(kind) phase=entry"
    }

    private func exit(_ kind: String, _ reason: String) -> String {
        "[LiveHints] manual kind=\(kind) phase=preflight_exit reason=\(reason)"
    }
}

@MainActor
private final class DiagnosticsHarness {
    let state = MeetingCoachState()
    let transcript = LiveMeetingTranscript()
    let routes = MeetingAnswerRoutes()
    let route = FakeRoute(routeName: "PRIVATE_ADAPTER_MARKER")
    let clock = FakeClock()
    var lines: [String] = []
    var generation = 1
    var screenOn = true
    var captureCount = 0
    var captureResult: String? = "PRIVATE_SCREEN_MARKER"
    var captureGate: RequestGate?

    lazy var service = MeetingAnswerService(transcript: transcript, routes: routes,
        clock: { [unowned self] in clock.now }, diagnosticLog: { [unowned self] in lines.append($0) },
        generation: { [unowned self] in generation }, state: state,
        screenEnabled: { [unowned self] in screenOn }, captureScreen: { [unowned self] in
            captureCount += 1
            await captureGate?.wait()
            return captureResult
        })

    init() {
        routes.pro = route
        state.arm(generation: 1)
    }

    func seed() async {
        await appendThemLine(transcript, text: "PRIVATE_TRANSCRIPT_MARKER?", from: 0)
        state.publish(.init(id: UUID(), generation: 1, heard: nil, kind: .answer,
            provenance: .transcript, action: nil, blocks: [.headline("**PRIVATE_ANSWER_MARKER.**")],
            createdAt: clock.now))
    }

    func request(_ kind: String) -> Task<Void, Never>? {
        switch kind {
        case "shortcut": return service.requestShortcut()
        case "typed": return service.requestQuestion("PRIVATE_QUESTION_MARKER")
        case "screen": return service.requestScreen()
        default: return service.requestAction(MeetingAnswerAction(rawValue: kind)!)
        }
    }

    func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }
}
