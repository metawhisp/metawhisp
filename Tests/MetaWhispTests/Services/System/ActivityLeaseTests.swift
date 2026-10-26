import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.2 — an install must never kill the app while a call
/// is being recorded or transcribed. The lease says which, in a file the
/// install script reads.
final class ActivityLeaseTests: XCTestCase {

    func testRecordingOrStartingIsRecording() {
        XCTAssertEqual(ActivityLease.state(isRecording: true, isStarting: false, dictationStage: .idle, meetingsInFlight: 0), .recording)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: true, dictationStage: .idle, meetingsInFlight: 0), .recording)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .recording, meetingsInFlight: 0), .recording)
    }

    func testAMeetingOrADictationBeingTranscribedIsTranscribing() {
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle, meetingsInFlight: 1), .transcribing)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .processing, meetingsInFlight: 0), .transcribing)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .postProcessing, meetingsInFlight: 0), .transcribing)
    }

    func testRecordingWinsOverTranscribing() {
        XCTAssertEqual(ActivityLease.state(isRecording: true, isStarting: false, dictationStage: .processing, meetingsInFlight: 2), .recording)
    }

    func testNothingGoingOnIsIdle() {
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle, meetingsInFlight: 0), .idle)
    }

    /// C6 — an install waits while the onboarding practice records or
    /// transcribes; real work still says what it is.
    func testThePracticeIsBusyBelowRealWorkAndAboveAnErrand() {
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle, meetingsInFlight: 0,
                                           errandRunning: true, practicing: true), .practice)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .processing, meetingsInFlight: 0,
                                           practicing: true), .transcribing)
        XCTAssertEqual(ActivityLease.state(isRecording: true, isStarting: false, dictationStage: .idle, meetingsInFlight: 0,
                                           practicing: true), .recording)
        XCTAssertEqual(ActivityLease.State.practice.rawValue, "running a practice dictation",
                       "the install script says: MetaWhisp is <state> right now")
    }

    func testTheLeaseLivesInTheAppsOwnFolder() {
        let base = URL(fileURLWithPath: "/tmp/mw-lease-folder", isDirectory: true)
        XCTAssertEqual(ActivityLease.fileURL(in: base).path, "/tmp/mw-lease-folder/activity.json")
    }

    /// The script reads `pid` and `state` from the file, so both are written
    /// whole and plainly.
    func testTheLeaseIsWrittenWholeAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mw-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = ActivityLease.fileURL(in: dir)
        let record = ActivityLease.Record(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test",
                                          state: .transcribing, since: Date(timeIntervalSince1970: 1_000_000))
        try ActivityLease.write(record, to: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["pid"] as? Int, 4242)
        XCTAssertEqual(json["executable"] as? String, "/Applications/Test.app/Contents/MacOS/Test",
                       "the script checks the pid still runs this executable, so a reused pid never blocks")
        XCTAssertEqual(json["state"] as? String, "transcribing")
        XCTAssertNotNil(json["since"] as? String)
    }
}
