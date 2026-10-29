import AppKit
import XCTest
@testable import MetaWhisp

/// Source contracts for the real entry, plus isolated recorder and refusal gates.
/// Constructing AppDelegate would open the production history store; these are
/// deliberately not a stop-to-persistence integration fixture.
@MainActor
final class MeetingCoachStopTests: XCTestCase {
    func testControllerRoutesEveryStopThroughTheStopOnlyEntry() throws {
        let source = try sourceFile("Views/MeetingCoach/MeetingCoachWindowController.swift")
        XCTAssertTrue(source.contains("AppDelegate.shared?.stopMeetingFromCard()"))
        XCTAssertFalse(source.contains("toggleMeetingRecording"))
    }

    func testRealEntryRefusesIdleBeforeAnySideEffect() throws {
        let body = try entryBody()
        let lines = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }

        XCTAssertEqual(lines.first,
                       "guard meetingRecorder.isRecording || meetingRecorder.isStarting else { return }")
        XCTAssertFalse(body.contains("toggleMeetingRecording"))
        XCTAssertFalse(body.contains("startMeetingRecording"))
        XCTAssertFalse(body.contains("Task"), "the eligibility check must be synchronous")
        XCTAssertFalse(body.contains("await"))
    }

    func testRealEntryClearsBothErrorsBeforeExactlyOneManualStop() throws {
        let body = try entryBody()
        let recorderReset = try XCTUnwrap(body.range(of: "meetingRecorder.lastError = nil"))
        let systemReset = try XCTUnwrap(body.range(of: "systemAudioCapture.lastError = nil"))
        let stop = try XCTUnwrap(body.range(of: "stopMeetingRecording(reason: \"card-tap-stop\")"))

        XCTAssertLessThan(recorderReset.lowerBound, stop.lowerBound)
        XCTAssertLessThan(systemReset.lowerBound, stop.lowerBound)
        XCTAssertEqual(body.components(separatedBy: "stopMeetingRecording(").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "meetingRecorder.lastError = nil").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "systemAudioCapture.lastError = nil").count - 1, 1)
    }

    func testCardReasonPreservesCalendarAndCallRefusals() throws {
        let body = try entryBody()
        let marker = "stopMeetingRecording(reason: \""
        let start = try XCTUnwrap(body.range(of: marker)).upperBound
        let end = try XCTUnwrap(body[start...].firstIndex(of: "\""))
        let reason = String(body[start..<end])
        XCTAssertTrue(CalendarAutoStartRetry.isRefusal(stopReason: reason))

        let stopBody = try functionBody("private func stopMeetingRecording(reason: String)")
        XCTAssertTrue(stopBody.contains("MeetingAutoStartGate.shared.decline(eventID: eventID)"))
        XCTAssertTrue(stopBody.contains("MeetingAutoStartGate.shared.stoppedByHand()"))

        let gate = MeetingAutoStartGate(now: { Date(timeIntervalSince1970: 1_000) })
        let event = (id: "card-stop-event", title: "Planning call")
        XCTAssertEqual(gate.evaluate(callName: nil, calendarEventNow: event,
                                     calendarEventInProgress: event, isRecording: false,
                                     practiceHoldsCapture: false),
                       .calendarReady(name: event.title, eventID: event.id))
        _ = gate.evaluate(callName: "Call app", calendarEventNow: nil,
                          calendarEventInProgress: event, isRecording: true,
                          practiceHoldsCapture: false)
        if CalendarAutoStartRetry.isRefusal(stopReason: reason) {
            gate.decline(eventID: event.id)
            gate.stoppedByHand()
        }
        XCTAssertTrue(gate.isHeld("Call app"))
        for _ in 0..<(CalendarAutoStartRetry.cooldownTicks * 3) {
            XCTAssertEqual(gate.evaluate(callName: "Call app", calendarEventNow: nil,
                                         calendarEventInProgress: event, isRecording: false,
                                         practiceHoldsCapture: false), .idle)
        }
    }

    func testExistingRecorderStopInvalidatesStartupAndClearsEligibility() {
        let recorder = makeRecorder()
        recorder.isStarting = true
        let generation = recorder.recordingGeneration

        _ = recorder.stop()

        XCTAssertGreaterThan(recorder.recordingGeneration, generation)
        XCTAssertFalse(recorder.isStarting)
        XCTAssertFalse(recorder.isRecording)
    }

    func testExistingRecorderStopMakesRepeatedAndStaleEntryTapsIneligible() {
        let recorder = makeRecorder()
        recorder.isRecording = true

        _ = recorder.stop()

        XCTAssertFalse(recorder.isRecording || recorder.isStarting)
        XCTAssertNil(recorder.recordingStartedAt)
    }

    func testShowingTheOffscreenCardPreservesDictationPauseWindows() async throws {
        let recorder = makeRecorder()
        recorder.micClockStart = SuspendingClock.now.advanced(by: .seconds(-1))
        recorder.isRecording = true
        recorder.pauseMic()
        try await Task.sleep(for: .milliseconds(20))
        recorder.resumeMic()
        let before = recorder.pauseWindowsSnapshot()
        XCTAssertEqual(before.count, 1)

        let state = MeetingCoachState()
        state.arm()
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1200, height: 800) })
        controller.show()
        controller.pointerEntered(.capsule)
        controller.pointerEntered(.answer)
        defer { controller.hide() }

        XCTAssertEqual(recorder.pauseWindowsSnapshot(), before)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(try XCTUnwrap(controller.capsulePanel).isVisible)
        XCTAssertFalse(try XCTUnwrap(controller.answerPanel).isVisible)
    }

    private func makeRecorder() -> MeetingRecorder {
        MeetingRecorder(mic: AudioRecordingService(), systemAudio: SystemAudioCaptureService())
    }

    private func entryBody() throws -> String {
        try functionBody("func stopMeetingFromCard()")
    }

    private func functionBody(_ signature: String) throws -> String {
        let source = try sourceFile("App/AppDelegate.swift")
        let signatureEnd = try XCTUnwrap(source.range(of: signature), "Missing real entry: \(signature)").upperBound
        let opening = try XCTUnwrap(source[signatureEnd...].firstIndex(of: "{"))
        let closing = try XCTUnwrap(source[opening...].range(of: "\n    }"))
        return String(source[source.index(after: opening)..<closing.lowerBound])
    }

    private func sourceFile(_ path: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent(path))
    }
}
