import AVFoundation
import XCTest
@testable import MetaWhisp

/// The placement arithmetic as the SERVICE runs it — not a re-implementation.
/// `MicRecoveryTests` pins the pure functions; this drives
/// `fillSilence(bufferSampleTime:inputRate:capturedAt:)` on a real
/// `AudioRecordingService` with a declared timeline and no engine, and reads
/// the buffer back through `currentSampleCount`.
@MainActor
final class MicTimelinePlacementTests: XCTestCase {

    private let inputRate = 48_000.0
    private let target = 16_000.0

    /// A one-second IO drop inside a bind is filled in full — by the device's
    /// sample clock, not by the tap's delivery time.
    func testARealInBindGapIsFilledInFull() {
        let mic = AudioRecordingService()
        let t0 = SuspendingClock.now
        mic.beginTimeline()
        mic.fillSilence(bufferSampleTime: 1_000_000, inputRate: inputRate, capturedAt: t0)
        XCTAssertEqual(mic.currentSampleCount, 0, "the first buffer of a bind is the origin")

        let filled = mic.fillSilence(bufferSampleTime: 1_000_000 + Int64(inputRate),
                                     inputRate: inputRate, capturedAt: t0 + .seconds(1))
        XCTAssertEqual(filled, 16_000, "one second of missing device time is one second of silence")
        XCTAssertEqual(mic.currentSampleCount, 16_000)
    }

    /// v19/v20: a sample-time jump bounded while the margin is under the fill
    /// trigger fills NOTHING — and the bind must re-originate where the buffer
    /// actually landed. If it re-originated at the bound instead, the next
    /// real gap would be over-filled by the whole margin: a manufactured hole
    /// inside speech. The numbers below differ by exactly that margin.
    func testABoundedJumpDoesNotLeaveAPhantomDeficitBehind() {
        let mic = AudioRecordingService()
        let t0 = SuspendingClock.now
        mic.beginTimeline()
        var deviceTime: Int64 = 1_000_000
        mic.fillSilence(bufferSampleTime: deviceTime, inputRate: inputRate, capturedAt: t0)

        // A minute of healthy stream, placed by the clock.
        deviceTime += Int64(60 * inputRate)
        mic.fillSilence(bufferSampleTime: deviceTime, inputRate: inputRate, capturedAt: t0 + .seconds(60))
        XCTAssertEqual(mic.currentSampleCount, 60 * 16_000)

        // The device clock jumps eight hours. At a minute of bind age the
        // margin is 0.26 s — under the 0.35 s trigger — so nothing is filled.
        deviceTime += Int64(8 * 3600 * inputRate)
        let jumpFill = mic.fillSilence(bufferSampleTime: deviceTime, inputRate: inputRate,
                                       capturedAt: t0 + .seconds(60) + .milliseconds(21))
        XCTAssertEqual(jumpFill, 0, "the bound holds the jump under the trigger")
        XCTAssertEqual(mic.currentSampleCount, 60 * 16_000, "and nothing was appended")

        // Now a real half-second gap. From an origin where the buffer landed,
        // that is 8 000 samples; from an origin at the bound it would be
        // 8 000 plus the margin (~4 200) — the phantom hole.
        deviceTime += Int64(0.5 * inputRate)
        let gapFill = mic.fillSilence(bufferSampleTime: deviceTime, inputRate: inputRate,
                                      capturedAt: t0 + .seconds(60.521))
        XCTAssertEqual(gapFill, 8_000, accuracy: 2, "the real gap, and only the real gap")
        XCTAssertEqual(Double(mic.currentSampleCount), Double(60 * 16_000 + 8_000), accuracy: 2)
    }
}
