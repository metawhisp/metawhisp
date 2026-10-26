import AVFoundation
import XCTest
@testable import MetaWhisp

/// Dictation records through an input-only capture. AVAudioEngine runs input and output as one combined device on
/// macOS; a Bluetooth headset switches to its call profile the moment its microphone opens, which changes the
/// output side, and the engine resets — the recorder followed, the new engine opened the microphone again, and the
/// owner's three headset dictations of 2026-10-13 each ended with 0 samples after 3, 5 and 6 switches. A capture of
/// the input alone is not touched by the output side. Meetings keep the engine.
@MainActor
final class InputOnlyDictationTests: XCTestCase {

    private var recorder: AudioRecordingService!
    private var captures: [FakeCapture] = []
    private var devices: [AudioDeviceID] = []
    private var delays: [Double] = []
    private var defaultInput: AudioDeviceID = 4242
    private var now = SuspendingClock.now
    private var captureError: Error?
    /// Each follow waits on the next of these when a test queues them; otherwise it only yields.
    private var followHolds: [Hold] = []

    override func setUp() async throws {
        recorder = AudioRecordingService(path: .inputOnly)
        recorder.makeCapture = { [unowned self] device in
            self.devices.append(device)
            if let captureError = self.captureError { throw captureError }
            let capture = FakeCapture()
            self.captures.append(capture)
            return capture
        }
        recorder.defaultInputDevice = { [unowned self] in self.defaultInput }
        recorder.followDelay = { [unowned self] seconds in
            self.delays.append(seconds)
            if self.followHolds.isEmpty { await Task.yield() } else { await self.followHolds.removeFirst().wait() }
        }
        recorder.readinessDelay = { _ in await Task.yield() }
        recorder.readinessClock = { [unowned self] in self.now }
    }

    override func tearDown() async throws {
        _ = recorder.stop()
        recorder = nil
    }

    // MARK: - Which path

    func testMeetingsKeepTheEngine() {
        XCTAssertEqual(AudioRecordingService().path, .engine)
        XCTAssertEqual(recorder.path, .inputOnly)
    }

    // MARK: - Recording

    /// What the device delivers is what the dictation holds: converted to 16 kHz mono by the same handler the
    /// engine's tap uses.
    func testADictationRecordsWhatItsDeviceDelivers() async throws {
        try recorder.start()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(devices, [4242], "the system default, as macOS reports it")
        captures[0].deliver(frames: 4_800, sampleTime: 0)
        await until { self.recorder.currentSampleCount > 0 }
        let samples = recorder.stop()
        XCTAssertGreaterThan(samples.count, 1_000, "0.1 s at 48 kHz is about 1 600 samples at 16 kHz")
        XCTAssertLessThanOrEqual(samples.count, 1_616)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01, "the tone, not zeros")
    }

    func testStopTurnsTheCaptureOff() async throws {
        try recorder.start()
        _ = recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        await until { self.captures[0].stopped }
        XCTAssertTrue(captures[0].stopped)
        await settle()
        XCTAssertEqual(captures.count, 1, "nothing binds after stop")
    }

    /// A capture that cannot start is an error at start, as the engine's was.
    func testACaptureThatCannotStartFailsTheStart() {
        captureError = AudioRecordingService.RecordingError.noInputDevice
        XCTAssertThrowsError(try recorder.start())
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - The device changes

    /// The headset disconnected, the default moved: the recording goes on, on whatever the input is now, and keeps
    /// what it had.
    func testADeviceThatGoesAwayIsFollowedKeepingTheAudio() async throws {
        try recorder.start()
        captures[0].deliver(frames: 4_800, sampleTime: 0)
        await until { self.recorder.currentSampleCount > 0 }
        let before = recorder.currentSampleCount
        defaultInput = 4343
        captures[0].emit(.deviceGone)
        XCTAssertFalse(recorder.isRecording, "the lost bind is retired at once")
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(devices, [4242, 4343])
        XCTAssertEqual(delays, [MicDeviceFollow.settleDelaySeconds], "a new device is given time to settle")
        XCTAssertGreaterThanOrEqual(recorder.currentSampleCount, before, "what was captured stays")
        await until { self.captures[0].stopped }
        XCTAssertTrue(captures[0].stopped)
    }

    /// The device's input format changed under the capture: bound again at once, on the same device — waiting
    /// would only lose speech.
    func testAFormatChangeIsFollowedAtOnce() async throws {
        try recorder.start()
        captures[0].emit(.formatChanged)
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(delays, [0])
        XCTAssertEqual(devices, [4242, 4242])
    }

    func testAnEventFromARetiredCaptureChangesNothing() async throws {
        try recorder.start()
        captures[0].emit(.formatChanged)
        await until { self.captures.count == 2 && self.recorder.isRecording }
        captures[0].emit(.deviceGone)
        await settle()
        XCTAssertEqual(captures.count, 2)
        XCTAssertTrue(recorder.isRecording)
    }

    /// AirPods arriving mid-dictation become the default; a recording on the default follows it.
    func testTheDefaultMovingMidDictationIsFollowed() async throws {
        try recorder.start()
        defaultInput = 4343
        recorder.defaultInputChanged()
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(devices, [4242, 4343])
    }

    func testTheDefaultMovingWhileIdleBindsNothing() async {
        defaultInput = 4343
        recorder.defaultInputChanged()
        await settle()
        XCTAssertTrue(captures.isEmpty)
    }

    /// The input-only path keeps the follow's rule: the user stopping while it waits leaves the microphone off.
    func testAFollowPendingAtStopLeavesTheMicrophoneOff() async throws {
        try recorder.start()
        captures[0].emit(.deviceGone)
        _ = recorder.stop()
        await settle()
        XCTAssertEqual(captures.count, 1)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Judged by the clock

    func testNoAudioByTheDeadlineBindsOnceMoreThenTellsTheUser() async throws {
        try recorder.start()
        await advance(by: 1.1)
        await until { self.captures.count == 2 }
        XCTAssertEqual(captures.count, 2, "one more bind")
        XCTAssertNil(recorder.micHealthError)
        await advance(by: 1.1)
        await until { self.recorder.micHealthError != nil }
        XCTAssertEqual(recorder.micHealthError, AudioRecordingService.deadMicMessage)
        await advance(by: 10)
        XCTAssertEqual(captures.count, 2, "and no more")
    }

    func testADeliveringMicrophoneIsLeftAlone() async throws {
        try recorder.start()
        var sampleTime: Int64 = 0
        for _ in 0..<12 {
            captures[0].deliver(frames: 4_800, sampleTime: sampleTime)
            sampleTime += 4_800
            await until { self.recorder.producedByTap > 0 }
            await advance(by: 0.25)
        }
        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(recorder.micHealthError)
    }

    func testAStreamThatStopsIsBoundAgain() async throws {
        try recorder.start()
        captures[0].deliver(frames: 4_800, sampleTime: 0)
        await until { self.recorder.producedByTap > 0 }
        await advance(by: 0.25)
        await advance(by: 1.6)
        await until { self.captures.count == 2 }
        XCTAssertEqual(captures.count, 2)
    }

    /// While a follow brings the microphone back, the clock does not judge it: one owner at a time.
    func testTheClockWaitsWhileAFollowIsInFlight() async throws {
        let held = Hold()
        recorder.followDelay = { _ in await held.wait() }
        try recorder.start()
        captures[0].emit(.deviceGone)
        await advance(by: 5)
        XCTAssertEqual(captures.count, 1, "the clock stands down")
        held.release()
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(captures.count, 2, "the follow binds, once")
    }

    func testTheClockStopsWithTheRecording() async throws {
        try recorder.start()
        _ = recorder.stop()
        await advance(by: 5)
        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(recorder.micHealthError)
    }

    /// A follow that could not bind leaves the recording without a microphone; the clock binds once more, then
    /// tells the user.
    func testAFollowThatFailsIsBoundOnceMoreThenTheUserIsTold() async throws {
        try recorder.start()
        captureError = AudioRecordingService.RecordingError.noInputDevice
        captures[0].emit(.deviceGone)
        await until { self.devices.count == 2 && !self.recorder.followInFlight }
        await advance(by: 0.25)
        await until { self.recorder.micHealthError != nil }
        XCTAssertEqual(devices.count, 3, "the start, the follow, one more")
        XCTAssertEqual(recorder.micHealthError, AudioRecordingService.deadMicMessage)
    }

    /// A follow left over from a recording that ended never releases the next recording's own follow: the clock
    /// trusts that flag, and bound a microphone that was still settling (independent review, 2026-10-13).
    func testAnOldFollowLeavesTheNextRecordingsFollowInFlight() async throws {
        let old = Hold(), current = Hold()
        followHolds = [old, current]
        try recorder.start()
        captures[0].emit(.deviceGone)
        _ = recorder.stop()
        XCTAssertFalse(recorder.followInFlight, "a stopped recorder has no follow in flight")
        try recorder.start()
        captures[1].emit(.deviceGone)
        XCTAssertTrue(recorder.followInFlight)
        old.release()
        await settle()
        XCTAssertTrue(recorder.followInFlight, "the old follow is not this recording's")
        current.release()
        await until { self.captures.count == 3 && self.recorder.isRecording }
        XCTAssertFalse(recorder.followInFlight)
        XCTAssertEqual(captures.count, 3, "the current follow binds, once")
    }

    // MARK: - The verdict tracks the present

    /// The verdict is about now: audio arriving after it — the microphone came back — clears it.
    func testAudioAfterTheVerdictClearsIt() async throws {
        try recorder.start()
        await advance(by: 1.1)
        await until { self.captures.count == 2 }
        await advance(by: 1.1)
        await until { self.recorder.micHealthError != nil }
        XCTAssertNotNil(recorder.micHealthError)
        captures[1].deliver(frames: 4_800, sampleTime: 0)
        await until { self.recorder.micHealthError == nil }
        XCTAssertNil(recorder.micHealthError)
    }

    /// A Bluetooth headset can open with a second of exact zeros while its link comes up; once its audio arrives,
    /// the dictation is fine and must not end with a dead-microphone message.
    func testAHeadsetThatOpensWithZerosIsNotCalledDead() async throws {
        try recorder.start()
        var sampleTime: Int64 = 0
        for _ in 0..<12 {
            captures[0].deliver(frames: 4_800, sampleTime: sampleTime, silent: true)
            sampleTime += 4_800
        }
        await until { self.recorder.micHealthError != nil }
        XCTAssertNotNil(recorder.micHealthError, "1.2 s of exact zeros from the start: the detector speaks")
        captures[0].deliver(frames: 4_800, sampleTime: sampleTime)
        await until { self.recorder.micHealthError == nil }
        XCTAssertNil(recorder.micHealthError)
    }

    // MARK: - The handler's pace

    /// The engine's tap was asked for 1 024 frames and delivered tens of buffers a second; the capture gathers the
    /// device's small renders to the same size, so meters keep their pace and a stop loses no more than a tap did.
    func testTheCaptureDeliversWhatTheTapDelivered() {
        XCTAssertEqual(InputOnlyCapture.deliveryFrames, 1_024)
    }

    // MARK: - Helpers

    /// Moves the clock and lets the checks that see it run.
    private func advance(by seconds: Double) async {
        now = now + .milliseconds(Int(seconds * 1_000))
        await settle()
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<50 { await Task.yield() }
    }

    private func until(_ done: @escaping () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// A capture that delivers what the test hands it.
final class FakeCapture: MicCapture, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var handler: AVAudioNodeTapBlock?
    private var onEvent: (@MainActor (MicCaptureEvent) -> Void)?
    private let lock = NSLock()
    private var stoppedValue = false

    var stopped: Bool { lock.withLock { stoppedValue } }

    func start(handler: @escaping AVAudioNodeTapBlock, onEvent: @escaping @MainActor (MicCaptureEvent) -> Void) throws {
        self.handler = handler
        self.onEvent = onEvent
    }

    func stop() { lock.withLock { stoppedValue = true } }

    /// `frames` of a tone — or of exact zeros — stamped with the device's sample time.
    func deliver(frames: Int, sampleTime: Int64, silent: Bool = false) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = silent ? 0 : 0.1 * sinf(Float(i) * 0.05) }
        handler?(buffer, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate))
    }

    @MainActor
    func emit(_ event: MicCaptureEvent) { onEvent?(event) }
}

/// Holds a follow's wait until the test releases it.
@MainActor
final class Hold {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
