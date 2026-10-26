import AVFAudio
import XCTest
@testable import MetaWhisp

/// An Objective-C exception that escapes a main-actor job stops the main queue for good, and the next main-actor check
/// crashes the app: an AVFAudio exception raised during a dark wake at 23:37 on 2026-10-11, the app crashed at the
/// wake ten hours later (reproduced on macOS 26.5.1). A framework call that raises is caught where our code makes it.
final class ObjCRaiseTests: XCTestCase {

    func testARaiseComesBackAsAnError() {
        XCTAssertThrowsError(try ObjCRaise.catching {
            NSException(name: NSExceptionName("TestRaise"), reason: "the reason", userInfo: nil).raise()
        }) { error in
            XCTAssertEqual((error as? ObjCRaise)?.name, "TestRaise")
            XCTAssertEqual((error as? ObjCRaise)?.reason, "the reason")
        }
    }

    func testAValueComesBackUntouched() throws {
        XCTAssertEqual(try ObjCRaise.catching { 42 }, 42)
    }

    func testASwiftErrorPassesThroughAsItIs() {
        struct Refused: Error {}
        XCTAssertThrowsError(try ObjCRaise.catching { throw Refused() }) { XCTAssertTrue($0 is Refused) }
    }

    /// AVFAudio's own kind of raise, the kind that reached AppKit on 2026-10-11: here a second tap on one bus.
    func testAnAudioEngineRaiseIsCaught() {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        defer { mixer.removeTap(onBus: 0) }
        XCTAssertThrowsError(try ObjCRaise.catching {
            mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        }) { XCTAssertEqual(($0 as? ObjCRaise)?.name, "com.apple.coreaudio.avfaudio") }
    }

    /// What the crashed process lacked: a main-actor job that met a raise ends normally, and the main queue goes on —
    /// a block queued after it still runs.
    @MainActor
    func testAMainActorJobThatMetARaiseLeavesTheMainQueueRunning() async {
        let job = Task { @MainActor in
            try? ObjCRaise.catching {
                NSException(name: NSExceptionName("TestRaise"), reason: "inside a job", userInfo: nil).raise()
            }
        }
        await job.value
        let ran = expectation(description: "a main-queue block after the raise")
        DispatchQueue.main.async { ran.fulfill() }
        await fulfillment(of: [ran], timeout: 2)
    }
}
