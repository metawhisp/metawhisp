import AVFAudio
import XCTest
@testable import MetaWhisp

/// AVAudioEngine reports a device it can no longer use — a format the hardware stopped having, an input gone during a
/// dark wake with the lid closed — by raising an Objective-C exception. One escaped a main-actor job of the recorder on
/// 2026-10-11 23:37; the main queue never ran again and the app crashed at the next wake. A raise in a bind is that
/// bind failing, like any other.
@MainActor
final class EngineRaiseTests: XCTestCase {

    /// An engine whose input node raises, as AVFAudio does; it counts its stops, from any thread.
    private final class RaisingEngine: AVAudioEngine {
        private let lock = NSLock()
        private var stopCount = 0
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
        override func stop() { lock.lock(); stopCount += 1; lock.unlock(); super.stop() }
        override var inputNode: AVAudioInputNode {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                        reason: "required condition is false: a test's raise", userInfo: nil).raise()
            return super.inputNode
        }
    }

    func testARaiseInTheBindIsTheBindFailing() async {
        let recorder = AudioRecordingService(path: .engine)
        recorder.makeEngine = { RaisingEngine() }
        XCTAssertThrowsError(try recorder.start())
        XCTAssertFalse(recorder.isRecording)
        let ran = expectation(description: "the main queue still runs")
        DispatchQueue.main.async { ran.fulfill() }
        await fulfillment(of: [ran], timeout: 2)
    }

    /// The next start is a fresh engine: the one that raised is not kept for reuse.
    func testTheEngineThatRaisedIsNotReused() {
        let recorder = AudioRecordingService(path: .engine)
        var made = 0
        recorder.makeEngine = { made += 1; return RaisingEngine() }
        XCTAssertThrowsError(try recorder.start())
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(made, 2)
    }

    /// What the bind asks of its input — is it the built-in microphone, take this device — fails with a raise:
    /// answered "no" instead, a built-in microphone's bind would lose its dead-mic check. The log line's description
    /// stays best-effort.
    func testTheBindsQuestionsAboutItsInputFailWithARaise() {
        let engine = RaisingEngine()
        let device = AudioInputDevice(uid: "test-input", name: "Test input", deviceID: 1)
        XCTAssertThrowsError(try AudioInputCatalog.boundInputIsBuiltIn(for: engine))
        XCTAssertThrowsError(try AudioInputCatalog.setInputDevice(device, on: engine))
        XCTAssertEqual(AudioInputCatalog.boundInputDescription(for: engine), "<no input audio unit>")
    }

    /// Taking an engine down stops it even when taking its tap off raised: an engine that raised is leaked — the
    /// frames a raise unwinds skip their releases — and stopped, it holds no device.
    func testAnEngineIsStoppedEvenWhenItsTapRaised() {
        let engine = RaisingEngine()
        XCTAssertFalse(AudioRecordingService.tearDown(engine))
        XCTAssertEqual(engine.stops, 1)
    }

    /// A bind that failed retires its generation: whatever it queued — buffers of an engine that started before its
    /// input query raised — is not counted.
    func testAFailedBindRetiresItsGeneration() {
        let recorder = AudioRecordingService(path: .engine)
        recorder.makeEngine = { RaisingEngine() }
        let before = recorder.bindGeneration
        XCTAssertThrowsError(try recorder.start())
        XCTAssertGreaterThan(recorder.bindGeneration, before)
    }

    /// An engine whose bind failed is stopped, not only let go: the raise leaked it, and only stopping gives back what
    /// it prepared.
    func testAnEngineWhoseBindFailedIsStopped() async {
        let recorder = AudioRecordingService(path: .engine)
        let engine = RaisingEngine()
        recorder.makeEngine = { engine }
        XCTAssertThrowsError(try recorder.start())
        for _ in 0..<200 where engine.stops == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(engine.stops, 1)
    }
}
