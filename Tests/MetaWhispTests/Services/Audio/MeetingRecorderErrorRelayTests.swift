import Combine
import XCTest
@testable import MetaWhisp

/// ITER-050 B3.6 — the recorder must forward the system-audio error AND its
/// reset. The old sink dropped `nil` (`if let err`), so one transient SCK
/// failure pinned the red "System audio failed" banner in the popover forever
/// («System audio failed: No display found…» in an idle NO MEETING popover).
@MainActor
final class MeetingRecorderErrorRelayTests: XCTestCase {

    func testErrorResetReachesRecorder() async throws {
        let mic = AudioRecordingService()
        let system = SystemAudioCaptureService()
        let recorder = MeetingRecorder(mic: mic, systemAudio: system)

        system.lastError = "System audio failed: No display found for system audio capture"
        try await pump(until: { recorder.lastError != nil })
        XCTAssertNotNil(recorder.lastError, "error must propagate to the recorder banner")

        // Recovery (next start() clears the source error) must CLEAR the banner.
        system.lastError = nil
        try await pump(until: { recorder.lastError == nil })
        XCTAssertNil(recorder.lastError, "nil reset must propagate — stuck banner regression")
    }

    /// Spin the main run loop until the condition holds (the relay hops via
    /// `receive(on: RunLoop.main)`).
    private func pump(until condition: @escaping () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        XCTFail("condition not reached within ~1s")
    }
}
