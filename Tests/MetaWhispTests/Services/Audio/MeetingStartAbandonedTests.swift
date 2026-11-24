import XCTest
@testable import MetaWhisp

/// ITER-083 release review — a start that never recorded leaves no recording
/// behind. When system audio failed and there was no microphone, the start
/// ended quietly and the recording's snapshot stayed set: the settling sweep
/// took that phantom for a continuation of the call's last meeting and held it
/// unprocessed until the app was restarted.
@MainActor
final class MeetingStartAbandonedTests: XCTestCase {

    func testAFailedStartIsReported() {
        let recorder = MeetingRecorder(mic: AudioRecordingService(), systemAudio: SystemAudioCaptureService())
        var reported = 0
        recorder.onStartAbandoned = { reported += 1 }
        recorder.isStarting = true
        recorder.startFailed("No audio available — did not come up within 5s")
        XCTAssertEqual(reported, 1)
        XCTAssertFalse(recorder.isStarting)
        XCTAssertEqual(recorder.lastError, "No audio available — did not come up within 5s")
    }
}

/// The wiring, read off the source like the app's other wiring tests.
final class MeetingStartAbandonedWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../\(path)").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both ways a start can fail before it records go through one place.
    func testEveryFailedStartIsReported() throws {
        let recorder = try source("Services/Audio/MeetingRecorder.swift")
        let start = try XCTUnwrap(recorder.range(of: "func start(manualMode: Bool = false"))
        let end = try XCTUnwrap(recorder.range(of: "func pauseMic()"))
        let body = recorder[start.upperBound..<end.lowerBound]
        XCTAssertEqual(body.components(separatedBy: "self.startFailed(").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: "self.isStarting = false").count - 1, 1, "only the start that records")
    }

    func testTheAppForgetsTheRecordingOfAFailedStart() throws {
        let app = try source("App/AppDelegate.swift")
        let hook = try XCTUnwrap(app.range(of: "meetingRecorder.onStartAbandoned = { [weak self] in"))
        let body = app[hook.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("self.currentRecording = nil"))
        XCTAssertTrue(body.contains("self.calendarHardStopTask?.cancel()"), "its calendar-end check waits on nothing")
        XCTAssertTrue(body.contains("if self.didAutoStartRecording { MeetingAutoStartGate.shared.startCapturedNothing() }"),
                      "an empty start, so a call with no audio is not tried forever")
    }

    /// A stopped part waits for an earlier part of the same call still being
    /// saved; the save passes the recordings in flight.
    func testTheSavePassesTheRecordingsInFlight() throws {
        XCTAssertTrue(try source("App/AppDelegate.swift").contains(
            "inFlight: self.meetingRecordingsInFlight.filter { $0 != recording }"))
    }
}
