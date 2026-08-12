import XCTest
@testable import MetaWhisp

/// TDD coverage for `DeadMicDetector` (2026-08-12).
///
/// Written after a live incident on the founder's Mac: macOS's audio subsystem
/// started handing the process bit-exact zero samples, and EIGHT dictations in
/// a row plus one meeting were silently discarded — the only trace was a
/// `Audio too quiet (RMS=0.00000)` line in the log. The app could not tell a
/// dead input stream from a quiet room, so it never told the user anything.
///
/// The distinction this type locks in: a LIVE microphone always has a noise
/// floor. Even in a silent room the RMS of a buffer is a small positive number.
/// RMS that is bit-exact `0` over a sustained run means no signal is arriving
/// at all — a different failure class, deserving a different response.
final class DeadMicDetectorTests: XCTestCase {

    private let rate: Double = 16000
    /// 1024-frame buffers are what `AudioRecordingService` installs.
    private let bufferFrames = 1024

    /// Feed `count` buffers of the given rms, return the number of the buffer
    /// that first tripped the detector (nil when it never tripped).
    private func firstTrip(rms: Float, buffers count: Int,
                           detector: inout DeadMicDetector) -> Int? {
        for i in 1 ... count {
            if detector.observe(rms: rms, frames: bufferFrames, sampleRate: rate) {
                return i
            }
        }
        return nil
    }

    // MARK: - The core distinction: dead vs quiet

    func test_sustainedDigitalZero_reportsDead() {
        var d = DeadMicDetector()
        // 2 seconds' worth of bit-exact-zero buffers.
        let buffers = Int(2.0 * rate) / bufferFrames
        XCTAssertNotNil(firstTrip(rms: 0, buffers: buffers, detector: &d),
                        "A sustained run of bit-exact zero must be reported as a dead stream")
    }

    func test_quietRoomNoiseFloor_neverReportsDead() {
        var d = DeadMicDetector()
        // A real silent room on the built-in mic sits around 2e-4. Even an
        // order of magnitude quieter must NOT be called dead — that is the
        // false positive that would nag users recording in quiet rooms.
        let buffers = Int(30.0 * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: 0.00002, buffers: buffers, detector: &d),
                     "A quiet room has a noise floor and must never be called dead")
    }

    func test_denormalTinyButNonZero_neverReportsDead() {
        var d = DeadMicDetector()
        let buffers = Int(30.0 * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: .leastNonzeroMagnitude, buffers: buffers, detector: &d),
                     "Only bit-exact zero counts; any non-zero signal means the stream is alive")
    }

    // MARK: - Timing

    func test_shortZeroRun_belowThreshold_doesNotReportDead() {
        var d = DeadMicDetector()
        // Half of the dead-stream window — a brief gap is not a dead mic.
        let buffers = Int((DeadMicDetector.deadAfterSeconds / 2) * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: 0, buffers: buffers, detector: &d))
    }

    func test_tripsOnlyAfterTheConfiguredWindow() {
        var d = DeadMicDetector()
        let buffers = Int(3.0 * rate) / bufferFrames
        guard let trip = firstTrip(rms: 0, buffers: buffers, detector: &d) else {
            return XCTFail("expected the detector to trip")
        }
        let secondsAtTrip = Double(trip * bufferFrames) / rate
        XCTAssertGreaterThanOrEqual(secondsAtTrip, DeadMicDetector.deadAfterSeconds)
        // And not much later — one buffer of slack.
        XCTAssertLessThan(secondsAtTrip,
                          DeadMicDetector.deadAfterSeconds + Double(bufferFrames) / rate)
    }

    // MARK: - Recovery / reset behaviour

    func test_audioAfterZeros_resetsTheRun() {
        var d = DeadMicDetector()
        // Almost-but-not-quite dead...
        let nearly = Int((DeadMicDetector.deadAfterSeconds * 0.9) * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: 0, buffers: nearly, detector: &d))
        // ...then one buffer of real audio clears the run entirely.
        XCTAssertFalse(d.observe(rms: 0.01, frames: bufferFrames, sampleRate: rate))
        XCTAssertNil(firstTrip(rms: 0, buffers: nearly, detector: &d),
                     "Real audio must reset the zero-run, not merely pause it")
    }

    func test_micDyingMidRecording_isDetected() {
        var d = DeadMicDetector()
        // Speech first — this is the meeting case: the mic worked, then stopped.
        for _ in 0 ..< 100 {
            _ = d.observe(rms: 0.05, frames: bufferFrames, sampleRate: rate)
        }
        let buffers = Int(2.0 * rate) / bufferFrames
        XCTAssertNotNil(firstTrip(rms: 0, buffers: buffers, detector: &d),
                        "A mic that dies mid-recording must still be caught")
    }

    func test_tripsOnce_notOnEverySubsequentBuffer() {
        var d = DeadMicDetector()
        let buffers = Int(2.0 * rate) / bufferFrames
        XCTAssertNotNil(firstTrip(rms: 0, buffers: buffers, detector: &d))
        // Recovery is expensive (engine teardown + rebuild). Re-arming on every
        // later buffer would rebuild the engine dozens of times per second.
        var laterTrips = 0
        for _ in 0 ..< buffers {
            if d.observe(rms: 0, frames: bufferFrames, sampleRate: rate) { laterTrips += 1 }
        }
        XCTAssertEqual(laterTrips, 0, "The detector must latch after tripping")
    }

    func test_reset_reArmsAfterAnEngineRebuild() {
        var d = DeadMicDetector()
        let buffers = Int(2.0 * rate) / bufferFrames
        XCTAssertNotNil(firstTrip(rms: 0, buffers: buffers, detector: &d))
        // After a rebuild the caller re-arms; a still-dead engine must trip
        // again so the failure can be escalated to the user.
        d.reset()
        XCTAssertNotNil(firstTrip(rms: 0, buffers: buffers, detector: &d))
    }

    // MARK: - Corner cases

    func test_zeroFrameBuffers_areIgnored() {
        var d = DeadMicDetector()
        for _ in 0 ..< 10000 {
            XCTAssertFalse(d.observe(rms: 0, frames: 0, sampleRate: rate),
                           "Empty buffers carry no time and must not accumulate")
        }
    }

    func test_nonPositiveSampleRate_neverTrips() {
        var d = DeadMicDetector()
        // A bogus format is its own failure — it must not masquerade as a dead
        // mic (and must not divide by zero).
        for _ in 0 ..< 10000 {
            XCTAssertFalse(d.observe(rms: 0, frames: bufferFrames, sampleRate: 0))
        }
    }

    func test_negativeRms_isTreatedAsAlive_notZero() {
        var d = DeadMicDetector()
        // RMS is never negative by construction; if one ever arrives it is a
        // bug upstream, not silence — do not report a dead mic on it.
        let buffers = Int(30.0 * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: -1, buffers: buffers, detector: &d))
    }

    func test_nanRms_neverTrips() {
        var d = DeadMicDetector()
        let buffers = Int(30.0 * rate) / bufferFrames
        XCTAssertNil(firstTrip(rms: .nan, buffers: buffers, detector: &d),
                     "NaN is not bit-exact zero and must not be counted as silence")
    }

    func test_differentSampleRates_useTheSameWallClockWindow() {
        // The window is expressed in SECONDS, so a 48 kHz stream must need
        // proportionally more frames than a 16 kHz one.
        var slow = DeadMicDetector()
        var fast = DeadMicDetector()
        var slowTrip = 0, fastTrip = 0
        for i in 1 ... 5000 {
            if slowTrip == 0, slow.observe(rms: 0, frames: 512, sampleRate: 16000) { slowTrip = i }
            if fastTrip == 0, fast.observe(rms: 0, frames: 512, sampleRate: 48000) { fastTrip = i }
        }
        XCTAssertGreaterThan(slowTrip, 0)
        XCTAssertGreaterThan(fastTrip, 0)
        XCTAssertEqual(Double(fastTrip) / Double(slowTrip), 3.0, accuracy: 0.1,
                       "48 kHz needs 3x the buffers of 16 kHz for the same wall-clock window")
    }
}
