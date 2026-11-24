import AVFoundation
import XCTest
@testable import MetaWhisp

/// Dictation records through an input-only capture. AVAudioEngine runs input and output as one combined device on
/// macOS; a Bluetooth headset switches to its call profile the moment its microphone opens, which changes the
/// output side, and the engine resets — the recorder followed, the new engine opened the microphone again, and the
/// owner's three headset dictations of 2026-10-13 each ended with 0 samples after 3, 5 and 6 switches. A capture of
/// the input alone is not touched by the output side. Meetings record through it too since ITER-086.
@MainActor
final class InputOnlyDictationTests: XCTestCase {

    private var recorder: AudioRecordingService!
    /// What the capture seam saw and made — it runs off the main thread (ITER-086), so it is shared under a lock.
    private let capturesMade = SharedValue<[FakeCapture]>([])
    private let devicesAsked = SharedValue<[AudioDeviceID]>([])
    private let failure = SharedValue<Error?>(nil)
    private let defaultDevice = SharedValue<AudioDeviceID>(4242)
    private var captures: [FakeCapture] { capturesMade.value }
    private var devices: [AudioDeviceID] { devicesAsked.value }
    private var captureError: Error? { get { failure.value } set { failure.value = newValue } }
    private var defaultInput: AudioDeviceID { get { defaultDevice.value } set { defaultDevice.value = newValue } }
    private var delays: [Double] = []
    private var now = SuspendingClock.now
    /// Each follow waits on the next of these when a test queues them; otherwise it only yields.
    private var followHolds: [Hold] = []

    override func setUp() async throws {
        recorder = AudioRecordingService()
        let capturesMade = capturesMade, devicesAsked = devicesAsked, failure = failure, defaultDevice = defaultDevice
        recorder.makeCapture = { device in
            dispatchPrecondition(condition: .notOnQueue(.main))   // ITER-086: never on the main thread
            devicesAsked.mutate { $0.append(device) }
            if let error = failure.value { throw error }
            let capture = FakeCapture()
            capturesMade.mutate { $0.append(capture) }
            return capture
        }
        recorder.defaultInputDevice = { defaultDevice.value }
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

    // MARK: - An audio system that does not answer (ITER-086)

    /// 2026-11-24: a call into Core Audio held the main thread eight minutes after a call ended. Now the bind runs off
    /// the main thread: at the deadline the start hears "not responding", and the main actor ran all the while.
    func testAMicrophoneThatDoesNotAnswerIsNotRespondingAndTheMainThreadRuns() async throws {
        let release = hang()
        var answer: Error?
        try recorder.start(reported: { answer = $0 ?? CancellationError() })
        var ticks = 0
        let ticking = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(5)) } }
        await until { answer != nil }
        ticking.cancel()
        XCTAssertEqual(answer as? AudioRecordingService.RecordingError, .notResponding)
        XCTAssertGreaterThan(ticks, 3, "the main actor ran while the audio system hung")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.binding)
        release.signal()
    }

    /// While that call is out no new bind is tried: each would leave one more thread waiting on Core Audio.
    func testNoNewBindWhileTheHungCallIsOut() async throws {
        let release = hang()
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        _ = recorder.stop()
        XCTAssertThrowsError(try recorder.start()) {
            XCTAssertEqual($0 as? AudioRecordingService.RecordingError, .notResponding)
        }
        XCTAssertEqual(devices.count, 1, "no second call into the audio system")
        release.signal()
    }

    /// Its release: once the hung call returns, the microphone binds again — and what that call opened late is put away.
    func testTheMicrophoneBindsAgainOnceTheHungCallReturns() async throws {
        let release = hang()
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        _ = recorder.stop()
        release.signal()
        await until { !self.recorder.waitingOnHungCall }
        XCTAssertFalse(recorder.waitingOnHungCall)
        await until { self.captures.first?.stopped == true }
        XCTAssertTrue(captures.first?.stopped == true, "opened after it was given up, and stopped")
        try await startBound()
        XCTAssertEqual(captures.count, 2)
    }

    /// And its ceiling: a call hung for a minute no longer blocks — one more attempt goes through.
    func testAHungCallOlderThanAMinuteLetsOneMoreAttemptThrough() async throws {
        let release = hang()
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        _ = recorder.stop()
        now = now + .seconds(AudioRecordingService.wedgeRetryAfterSeconds + 1)
        XCTAssertNoThrow(try recorder.start())
        await until { self.devices.count == 2 }
        XCTAssertEqual(devices.count, 2, "one more attempt")
        release.signal()
    }

    /// The second call — the capture's start — hangs: "not responding" at the deadline, the capture is stopped once,
    /// after its start returns (never while it runs), and nothing records (Kimi review: the start phase untested).
    func testAStartThatHangsIsNotRespondingAndItsCaptureStopsOnceItReturns() async throws {
        recorder.hardware = MicHardware(deadline: 0.1)
        let release = DispatchSemaphore(value: 0)
        let capturesMade = capturesMade
        recorder.makeCapture = { _ in
            let capture = FakeCapture()
            capture.holdStart = release
            capturesMade.mutate { $0.append(capture) }
            return capture
        }
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        XCTAssertEqual(answer as? AudioRecordingService.RecordingError, .notResponding)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.waitingOnHungCall)
        XCTAssertEqual(captures.first?.stops, 0, "not stopped while its start still runs")
        release.signal()
        await until { self.captures.first?.stops == 1 }
        XCTAssertEqual(captures.first?.stops, 1, "stopped once, after its start returned")
        await until { !self.recorder.waitingOnHungCall }
        XCTAssertFalse(recorder.waitingOnHungCall)
    }

    /// An older hung call returning releases only itself: the newer one still out keeps the gate (Kimi review, P1).
    func testAnOlderHungCallReturningDoesNotReleaseANewerOne() async throws {
        recorder.hardware = MicHardware(deadline: 0.1)
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let calls = SharedValue(0)
        recorder.makeCapture = { _ in
            calls.mutate { $0 += 1 }
            (calls.value == 1 ? first : second).wait()
            return FakeCapture()
        }
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        _ = recorder.stop()
        now = now + .seconds(AudioRecordingService.wedgeRetryAfterSeconds + 1)
        answer = nil
        try recorder.start(reported: { answer = $0 })   // the minute is up: one more attempt, which hangs too
        await until { answer != nil }
        _ = recorder.stop()
        first.signal()                                  // the older call returns
        await settle()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(recorder.waitingOnHungCall, "the newer hung call still holds the gate")
        XCTAssertThrowsError(try recorder.start())
        second.signal()
        await until { !self.recorder.waitingOnHungCall }
        XCTAssertFalse(recorder.waitingOnHungCall)
    }

    /// Every capture the recorder starts is started off the main thread.
    func testTheCaptureIsStartedOffTheMainThread() async throws {
        try await startBound()
        XCTAssertEqual(captures.first?.startedOnMain, false)
    }

    /// Makes the next capture hang until the returned semaphore is signalled; the deadline is short.
    private func hang() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        let hung = SharedValue(true)
        let capturesMade = capturesMade, devicesAsked = devicesAsked
        recorder.hardware = MicHardware(deadline: 0.1)
        recorder.makeCapture = { device in
            devicesAsked.mutate { $0.append(device) }
            if hung.value { hung.value = false; release.wait() }
            let capture = FakeCapture()
            capturesMade.mutate { $0.append(capture) }
            return capture
        }
        return release
    }

    // MARK: - Under a meeting

    /// ITER-086 — meetings record through the input-only capture too (2026-11-24: the engine's input+output device
    /// held the main thread eight minutes after a call ended). The meeting's own recovery tick owns its microphone;
    /// dictation's readiness loop — one rebind, then a message to the user — must not run beside it: two owners
    /// rebinding one capture is the race the follow's flag exists to prevent.
    func testUnderAMeetingTheDictationReadinessLoopDoesNotRun() async throws {
        var checks = 0
        recorder.readinessDelay = { _ in checks += 1; await Task.yield() }
        recorder.beginTimeline()
        try await startBound()
        await settle()
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(recorder.isRecording)
    }

    /// Its pair: a dictation still has the loop.
    func testADictationStillHasTheReadinessLoop() async throws {
        var checks = 0
        recorder.readinessDelay = { _ in checks += 1; await Task.yield() }
        try await startBound()
        await until { checks > 0 }
        XCTAssertGreaterThan(checks, 0)
    }

    // MARK: - Recording

    /// What the device delivers is what the dictation holds: converted to 16 kHz mono by the same handler the
    /// engine's tap uses.
    func testADictationRecordsWhatItsDeviceDelivers() async throws {
        try await startBound()
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
        try await startBound()
        _ = recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        await until { self.captures[0].stopped }
        XCTAssertTrue(captures[0].stopped)
        await settle()
        XCTAssertEqual(captures.count, 1, "nothing binds after stop")
    }

    /// A capture that cannot be opened is the start's answer: reported after `start` returned (ITER-086).
    func testACaptureThatCannotStartFailsTheStart() async throws {
        captureError = AudioRecordingService.RecordingError.noInputDevice
        var answer: Error?
        try recorder.start(reported: { answer = $0 })
        await until { answer != nil }
        XCTAssertEqual(answer as? AudioRecordingService.RecordingError, .noInputDevice)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.lastBindFoundNoDevice)
    }

    /// A push-to-talk tap: stopped before the microphone answered. The capture opened after the stop is put away, and
    /// nothing records.
    func testAStopBeforeTheBindAnsweredLeavesNothingRunning() async throws {
        var heard = false
        try recorder.start(reported: { _ in heard = true })
        _ = recorder.stop()
        await until { self.captures.first?.stopped == true }
        XCTAssertTrue(captures.first?.stopped == true, "opened after the stop, and stopped")
        await settle()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(heard, "no report for a recording the caller stopped")
    }

    // MARK: - The device changes

    /// The headset disconnected, the default moved: the recording goes on, on whatever the input is now, and keeps
    /// what it had.
    func testADeviceThatGoesAwayIsFollowedKeepingTheAudio() async throws {
        try await startBound()
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
        try await startBound()
        captures[0].emit(.formatChanged)
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(delays, [0])
        XCTAssertEqual(devices, [4242, 4242])
    }

    func testAnEventFromARetiredCaptureChangesNothing() async throws {
        try await startBound()
        captures[0].emit(.formatChanged)
        await until { self.captures.count == 2 && self.recorder.isRecording }
        captures[0].emit(.deviceGone)
        await settle()
        XCTAssertEqual(captures.count, 2)
        XCTAssertTrue(recorder.isRecording)
    }

    /// AirPods arriving mid-dictation become the default; a recording on the default follows it.
    func testTheDefaultMovingMidDictationIsFollowed() async throws {
        try await startBound()
        defaultInput = 4343
        recorder.defaultInputChanged(to: defaultInput)
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(devices, [4242, 4343])
    }

    func testTheDefaultMovingWhileIdleBindsNothing() async {
        defaultInput = 4343
        recorder.defaultInputChanged(to: defaultInput)
        await settle()
        XCTAssertTrue(captures.isEmpty)
    }

    /// The input-only path keeps the follow's rule: the user stopping while it waits leaves the microphone off.
    func testAFollowPendingAtStopLeavesTheMicrophoneOff() async throws {
        try await startBound()
        captures[0].emit(.deviceGone)
        _ = recorder.stop()
        await settle()
        XCTAssertEqual(captures.count, 1)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Judged by the clock

    func testNoAudioByTheDeadlineBindsOnceMoreThenTellsTheUser() async throws {
        try await startBound()
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
        try await startBound()
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
        try await startBound()
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
        try await startBound()
        captures[0].emit(.deviceGone)
        await advance(by: 5)
        XCTAssertEqual(captures.count, 1, "the clock stands down")
        held.release()
        await until { self.captures.count == 2 && self.recorder.isRecording }
        XCTAssertEqual(captures.count, 2, "the follow binds, once")
    }

    func testTheClockStopsWithTheRecording() async throws {
        try await startBound()
        _ = recorder.stop()
        await advance(by: 5)
        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(recorder.micHealthError)
    }

    /// A follow that could not bind leaves the recording without a microphone; the clock binds once more, then
    /// tells the user.
    func testAFollowThatFailsIsBoundOnceMoreThenTheUserIsTold() async throws {
        try await startBound()
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
        try await startBound()
        captures[0].emit(.deviceGone)
        _ = recorder.stop()
        XCTAssertFalse(recorder.followInFlight, "a stopped recorder has no follow in flight")
        try await startBound()
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
        try await startBound()
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
        try await startBound()
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

    /// Starts and waits for the bind, which answers off the main thread.
    private func startBound() async throws {
        try recorder.start()
        await until { self.recorder.isRecording }
        XCTAssertTrue(recorder.isRecording, "bound")
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
    private var stopsValue = 0
    private var startedOnMainValue = false
    /// A start that waits for this before it returns — an audio system that does not answer.
    var holdStart: DispatchSemaphore?

    var stopped: Bool { lock.withLock { stoppedValue } }
    var stops: Int { lock.withLock { stopsValue } }
    /// ITER-086: the recorder starts a capture off the main thread.
    var startedOnMain: Bool { lock.withLock { startedOnMainValue } }

    func start(handler: @escaping AVAudioNodeTapBlock, onEvent: @escaping @MainActor (MicCaptureEvent) -> Void) throws {
        lock.withLock { startedOnMainValue = startedOnMainValue || Thread.isMainThread }
        holdStart?.wait()
        self.handler = handler
        self.onEvent = onEvent
    }

    func stop() { lock.withLock { stoppedValue = true; stopsValue += 1 } }

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
