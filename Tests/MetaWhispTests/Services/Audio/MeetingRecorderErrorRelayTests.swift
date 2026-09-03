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

    /// v17 P2: the user-toggle stop resets the system-audio error BEFORE
    /// stopping; that reset is relayed asynchronously and used to land after
    /// `keepFinalizationNote`, erasing the sticky mic-loss banner. The relay
    /// composes with the note, exactly as `reportFinalization` does.
    func testAnErrorResetDoesNotEraseTheFinalizationNote() async throws {
        let mic = AudioRecordingService()
        let system = SystemAudioCaptureService()
        let recorder = MeetingRecorder(mic: mic, systemAudio: system)
        let note = "⚠️ Mic input was down 12s during this meeting — your side is missing for that stretch"

        system.lastError = nil                                   // the toggle's reset, still in flight…
        recorder.keepFinalizationNote(note, for: 0)              // …when the stop keeps its note
        XCTAssertEqual(recorder.lastError, note)
        for _ in 0..<10 {                                        // let the relayed nil land
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        XCTAssertEqual(recorder.lastError, note, "the relayed reset must not erase the sticky note")

        // A later system-audio error joins the note rather than replacing it.
        system.lastError = "System audio failed: No display found for system audio capture"
        try await pump(until: { recorder.lastError?.contains("System audio failed") == true })
        XCTAssertEqual(recorder.lastError?.hasPrefix(note), true)
    }

    /// v18 P1: the next meeting must not resurrect the previous meeting's
    /// note. `start()` forgets the outcome synchronously — before any reset
    /// the relay could compose with the old note. (`start()` itself is not
    /// called here: it starts system-audio capture.)
    func testANewMeetingForgetsThePreviousNote() async throws {
        let mic = AudioRecordingService()
        let system = SystemAudioCaptureService()
        let recorder = MeetingRecorder(mic: mic, systemAudio: system)
        recorder.keepFinalizationNote("⚠️ Mic input was down 12s during this meeting", for: 0)
        recorder.forgetOutcome()                                 // what start() does first
        system.lastError = nil                                   // the new start's reset
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        XCTAssertNil(recorder.lastError, "the previous meeting's note must not come back")
    }

    /// v20: `start()` must forget the previous meeting's outcome in its
    /// SYNCHRONOUS half — before any await where a relayed reset could
    /// compose with the old note. The generation checkpoint at the top of
    /// `start()`'s Task lets `stop()` cancel the in-flight start, so this
    /// never reaches ScreenCaptureKit.
    func testStartForgetsThePreviousOutcomeBeforeItAwaitsAnything() async throws {
        let mic = AudioRecordingService()
        let system = SystemAudioCaptureService()
        let recorder = MeetingRecorder(mic: mic, systemAudio: system)
        recorder.keepFinalizationNote("⚠️ Mic input was down 12s during this meeting", for: 0)
        XCTAssertNotNil(recorder.lastError)

        recorder.start()
        XCTAssertNil(recorder.lastError, "the previous meeting's note is gone before start() awaits anything")
        _ = recorder.stop()          // retires the in-flight start task
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
