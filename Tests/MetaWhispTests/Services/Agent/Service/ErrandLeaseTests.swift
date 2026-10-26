import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — while an errand runs the activity lease says so, below
/// recording and transcribing, and a hot-swap refuses to quit the app.
@MainActor
final class ErrandLeaseTests: XCTestCase {

    func testAnErrandIsBusyBelowRecordingAndTranscribing() {
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle,
                                           meetingsInFlight: 0, errandRunning: true), .errand)
        XCTAssertEqual(ActivityLease.state(isRecording: true, isStarting: false, dictationStage: .idle,
                                           meetingsInFlight: 0, errandRunning: true), .recording)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .processing,
                                           meetingsInFlight: 0, errandRunning: true), .transcribing)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle,
                                           meetingsInFlight: 1, errandRunning: true), .transcribing)
        XCTAssertEqual(ActivityLease.state(isRecording: false, isStarting: false, dictationStage: .idle,
                                           meetingsInFlight: 0, errandRunning: false), .idle)
    }

    func testTheTrackerSaysErrandWhileOneRunsAndIdleAfter() {
        var states: [ActivityLease.State] = []
        let lease = ActivityLeaseTracker(pid: 4242, executable: "/Applications/Test.app/Contents/MacOS/Test",
                                         write: { states.append($0.state) })
        lease.errand(isRunning: true)
        lease.recorderAndDictation(isRecording: true, isStarting: false, stage: .idle)
        lease.recorderAndDictation(isRecording: false, isStarting: false, stage: .idle)
        lease.errand(isRunning: false)
        XCTAssertEqual(states, [.errand, .recording, .errand, .idle],
                       "a dictation during an errand goes first, and the errand is busy again after it")
    }

    /// The swap script reads the lease: an errand makes it refuse, and its
    /// message says why in words.
    func testAHotSwapRefusesWhileAnErrandRuns() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-errand-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let executable = try shell("/bin/ps -o comm= -p \(pid)").output.trimmingCharacters(in: .whitespacesAndNewlines)
        try ActivityLease.write(ActivityLease.Record(pid: pid, executable: executable, state: .errand, since: Date()),
                                to: ActivityLease.fileURL(in: support))
        // …/Tests/MetaWhispTests/Services/Agent/Service/ErrandLeaseTests.swift → repo root
        let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../scripts/lib/app-install.sh").standardized.path
        let run = try shell("export MW_APP_SUPPORT_DIR='\(support.path)' MW_APP_INSTALL_DIR='\(support.path)/Applications'; "
                            + "source '\(library)' && mw_refuse_if_busy")
        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("MetaWhisp is running an errand right now"), run.output)
    }

    /// Review of B1: the script says what it reads — every state the lease
    /// can hold, the errand's included, is named where the script reads it.
    func testTheSwapScriptNamesEveryLeaseState() throws {
        let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../scripts/lib/app-install.sh").standardized
        let script = try String(contentsOf: library, encoding: .utf8)
        let function = try XCTUnwrap(script.range(of: "\nmw_lease_state() {"))
        let comment = script[..<function.lowerBound].components(separatedBy: "\n")
            .reversed().prefix { $0.hasPrefix("#") }.reversed().joined(separator: " ")
        for state in [ActivityLease.State.idle, .recording, .transcribing, .errand] {
            XCTAssertTrue(comment.replacingOccurrences(of: "# ", with: "").contains(state.rawValue),
                          "\(state.rawValue) is not named in: \(comment)")
        }
    }

    /// The app feeds the tracker from the agent service; without that line a
    /// swap could quit the app mid-errand. How the lease follows the service
    /// is tested in `AgentServiceKeepAwakeTests` and `AgentServiceSleepTests`.
    func testTheAppFeedsTheLeaseFromTheAgentService() throws {
        let appDelegate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: appDelegate, encoding: .utf8).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(source.contains("AgentService.shared.$errandRunning"), "the app subscribes to the service")
        XCTAssertTrue(source.contains("leaseTracker.errand(isRunning:"), "and feeds the lease tracker")
    }

    private func shell(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
