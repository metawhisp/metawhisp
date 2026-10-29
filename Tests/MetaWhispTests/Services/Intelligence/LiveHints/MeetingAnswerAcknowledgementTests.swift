import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingAnswerAcknowledgementTests: XCTestCase {
    func testEveryAcceptedKindOwnsBusySynchronouslyAndRetainsTheAnswer() async throws {
        for kind in ["shortcut", "typed", "questions", "recap", "more", "screen"] {
            let h = makeAnswerHarness(generation: { 7 }, screenEnabled: { true }, captureScreen: { "Visible text" })
            await appendThemLine(h.transcript, text: "What is the delivery date?", from: 0)
            let answer = seed(h.state)
            let request: Task<Void, Never>?
            switch kind {
            case "shortcut": request = h.service.requestShortcut()
            case "typed": request = h.service.requestQuestion("What is next?")
            case "screen": request = h.service.requestScreen()
            default: request = h.service.requestAction(MeetingAnswerAction(rawValue: kind)!)
            }
            XCTAssertNotNil(request, kind)
            XCTAssertNotNil(h.state.busyRequest, kind)
            XCTAssertEqual(h.state.busyRequest?.generation, 7, kind)
            XCTAssertEqual(h.state.answers, [answer], kind)
            await request?.value
            XCTAssertNil(h.state.busyRequest, kind)
        }
    }

    func testScreenAndPendingTranscriptWaitsHaveImmediateBusy() async {
        let screenGate = RequestGate()
        let screen = makeAnswerHarness(screenEnabled: { true }, captureScreen: {
            await screenGate.wait()
            return nil
        })
        let screenRequest = screen.service.requestScreen()
        XCTAssertNotNil(screen.state.busyRequest)
        await screen.waitUntil { screenGate.waiterCount == 1 }
        XCTAssertNotNil(screen.state.busyRequest)
        screenGate.open()
        await screenRequest?.value
        XCTAssertNil(screen.state.busyRequest)

        let pendingGate = RequestGate()
        let pending = makeAnswerHarness(pendingThemText: {
            await pendingGate.wait()
            return nil
        })
        let pendingRequest = pending.service.requestShortcut()
        XCTAssertNotNil(pending.state.busyRequest)
        await pending.waitUntil { pendingGate.waiterCount == 1 }
        XCTAssertNotNil(pending.state.busyRequest)
        pendingGate.open()
        await pendingRequest?.value
        XCTAssertNil(pending.state.busyRequest)
    }

    func testPreflightAndTerminalExitsClearTheirBusyOwner() async {
        for outcome in ["empty", "no-route", "success", "unauthorized", "failure", "timeout", "pause", "cancelled", "invalid"] {
            let h = makeAnswerHarness()
            if outcome != "empty" { await appendThemLine(h.transcript, text: "What is the delivery date?", from: 0) }
            h.pro.isAvailable = outcome != "no-route"
            let status = ["unauthorized": 401, "failure": 500, "timeout": 408, "pause": 503, "cancelled": 499][outcome] ?? 200
            h.pro.replies = [.init(status: status, retryAfter: nil,
                text: outcome == "invalid" ? "invalid" : "**A valid answer.**")]
            let request = h.service.requestShortcut()
            XCTAssertNotNil(h.state.busyRequest, outcome)
            await request?.value
            XCTAssertNil(h.state.busyRequest, outcome)
        }
    }

    func testSettingOffAfterCaptureAndStopClearBusy() async {
        var enabled = true
        let gate = RequestGate()
        let h = makeAnswerHarness(screenEnabled: { enabled }, captureScreen: {
            await gate.wait()
            return "Visible text"
        })
        let first = h.service.requestScreen()
        await h.waitUntil { gate.waiterCount == 1 }
        enabled = false
        gate.open()
        await first?.value
        XCTAssertNil(h.state.busyRequest)
        let request = h.service.requestQuestion("What comes next?")
        XCTAssertNotNil(h.state.busyRequest)
        h.service.stop()
        XCTAssertNil(h.state.busyRequest)
        await request?.value
    }

    func testLatePreflightCleanupCannotClearTheNewerRequest() async throws {
        let oldGate = RequestGate()
        let currentGate = RequestGate()
        let h = makeAnswerHarness(screenEnabled: { true }, captureScreen: {
            await oldGate.wait()
            return "Visible text"
        })
        h.pro.gate = { await currentGate.wait() }
        let old = h.service.requestScreen()
        await h.waitUntil { oldGate.waiterCount == 1 }
        let oldOwner = h.state.busyRequest
        let current = h.service.requestQuestion("What comes next?")
        let currentOwner = try XCTUnwrap(h.state.busyRequest)
        XCTAssertNotEqual(oldOwner, currentOwner)
        await h.waitForRequests(1)
        oldGate.open()
        await old?.value
        XCTAssertEqual(h.state.busyRequest, currentOwner)
        currentGate.open()
        await current?.value
        XCTAssertNil(h.state.busyRequest)
    }

    func testBusyCleanupRequiresBothUUIDAndGeneration() {
        let state = MeetingCoachState()
        let id = UUID()
        state.showBusy(requestID: id, generation: 8)
        state.clearBusy(requestID: UUID(), generation: 8)
        XCTAssertNotNil(state.busyRequest)
        state.clearBusy(requestID: id, generation: 7)
        XCTAssertNotNil(state.busyRequest)
        state.clearBusy(requestID: id, generation: 8)
        XCTAssertNil(state.busyRequest)
    }

    func testRepeatGuardIsPerKindAndFlashesOnlyTheRepeatedChip() async throws {
        let h = makeAnswerHarness()
        await appendThemLine(h.transcript, text: "What is the delivery date?", from: 0)
        let questions = h.service.requestAction(.questions)
        let recap = h.service.requestAction(.recap)
        XCTAssertNotNil(questions)
        XCTAssertNotNil(recap)
        let owner = h.state.busyRequest
        XCTAssertNil(h.service.requestAction(.questions))
        XCTAssertEqual(h.state.repeatPulse(for: .questions), 1)
        XCTAssertEqual(h.state.repeatPulse(for: .recap), 0)
        XCTAssertEqual(h.state.busyRequest, owner)
        XCTAssertNil(h.service.requestAction(.questions))
        XCTAssertEqual(h.state.repeatPulse(for: .questions), 2)
        h.clock.advance(by: 1)
        let later = h.service.requestAction(.questions)
        XCTAssertNotNil(later)
        await questions?.value
        await recap?.value
        await later?.value
    }

    private func seed(_ state: MeetingCoachState) -> MeetingAnswer {
        let answer = MeetingAnswer(id: UUID(), heard: nil, kind: .answer,
            provenance: .transcript, action: nil, blocks: [.headline("The retained answer.")], createdAt: Date())
        state.publish(answer)
        return answer
    }
}
