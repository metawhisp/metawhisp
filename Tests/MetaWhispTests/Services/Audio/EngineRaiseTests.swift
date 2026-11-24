import AVFAudio
import XCTest
@testable import MetaWhisp

/// AVAudioEngine reports a device it can no longer use by raising an Objective-C exception; one escaped a main-actor
/// job on 2026-10-11 23:37 and the main queue never ran again. Recording no longer uses the engine (ITER-086); the
/// permission prompt's touch still does, through `avf` and `tearDown`.
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



    /// Taking an engine down stops it even when taking its tap off raised: an engine that raised is leaked — the
    /// frames a raise unwinds skip their releases — and stopped, it holds no device.
    func testAnEngineIsStoppedEvenWhenItsTapRaised() {
        let engine = RaisingEngine()
        XCTAssertFalse(AudioRecordingService.tearDown(engine))
        XCTAssertEqual(engine.stops, 1)
    }


}
