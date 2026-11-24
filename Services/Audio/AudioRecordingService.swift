import AVFAudio
import AVFoundation
import Foundation

/// Records the microphone — the input alone (`InputOnlyCapture`) — as 16 kHz mono Float32 PCM.
///
/// It used AVAudioEngine until ITER-086. The engine runs input and output as one combined device: a Bluetooth headset
/// switching to its call profile reset it in a loop that recorded nothing (owner's log, 2026-10-13, dictation moved
/// off it), and a call ending changed the output side while a meeting recorded, so its rebind held the main thread
/// eight minutes inside AVFAudio (2026-11-24). Every recording now captures the input alone.
@MainActor
final class AudioRecordingService: ObservableObject, AudioSource {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    /// Physical (un-boosted) RMS of the last buffer. `audioLevel` is the
    /// sqrt-boosted UI value — comparing IT against raw-RMS thresholds is the
    /// units-mismatch bug ITER-060 fixed; silence guards must use this one.
    @Published var rawRMSLevel: Float = 0
    @Published var audioBars: [Float] = Array(repeating: 0, count: 24)
    /// Non-nil once the input has been delivering digital silence long enough
    /// to be certain it is dead rather than quiet. The UI surfaces this — the
    /// 2026-08-12 incident swallowed eight recordings without ever telling the
    /// user the mic had stopped producing audio.
    @Published var micHealthError: String?

    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var barPhase: Double = 0
    /// Digital-silence watchdog, re-armed per recording.
    private var deadMic = DeadMicDetector()


    /// Every call into AVAudioEngine goes through here. AVFAudio reports an input it can no longer use — a format the
    /// hardware stopped having, a device gone in a dark wake with the lid closed — by raising an Objective-C
    /// exception; one escaped a main-actor job of this recorder on 2026-10-11 at 23:37, the main queue never ran
    /// again and the app crashed at the wake ten hours later. Caught here, a raise is the call failing; it surfaces
    /// as the format error a bind already has.
    ///
    /// A raise leaks the engine object — the Swift frames it unwinds skip their releases — so an engine that raised
    /// is stopped (`tearDown`), which releases the device and everything it prepared.
    nonisolated static func avf<T>(_ step: String, _ body: () throws -> T) throws -> T {
        do {
            return try ObjCRaise.catching(body)
        } catch let raise as ObjCRaise {
            NSLog("[AudioRecording] AVFAudio raised in %@ — %@", step, raise.description)
            throw RecordingError.formatError
        }
    }

    /// Takes the tap off and stops the engine, each on its own: a raise in the first must not leave the engine
    /// running. Whether both went through.
    nonisolated static func tearDown(_ engine: AVAudioEngine) -> Bool {
        let tapOff = (try? avf("remove tap") { engine.inputNode.removeTap(onBus: 0) }) != nil
        let stopped = (try? avf("stop") { engine.stop() }) != nil
        return tapOff && stopped
    }


    /// When the CURRENT bind's first buffer was accepted — on the monotonic
    /// clock. The log reads it; no timeline arithmetic does.
    private(set) var firstBufferAt: SuspendingClock.Instant?
    /// When this bind's tap last PRODUCED samples. A converter that dies
    /// after its first output keeps the raw callbacks coming while the
    /// buffer stops growing; a stall is judged here.
    private(set) var lastProducedAt: SuspendingClock.Instant?
    /// When this bind last carried NON-ZERO audio. The built-in mic going to
    /// exact zeros after half an hour of speech lost that half hour's tail,
    /// not the whole bind: the outage is measured from here.
    private(set) var lastAudioAt: SuspendingClock.Instant?
    /// Accounting for the meeting recorder, latched between its ticks so
    /// nothing that happens between two polls is lost: seconds of silence
    /// placed into the timeline since the last take, and whether the content
    /// detector tripped since the last take (a run of zeros can begin and end
    /// between two polls — review round nine).
    private var silencePlacedSinceTake: Double = 0
    /// Latched WITH its qualification at trip time — "never saw audio, or the
    /// built-in mic" — because by the time the tick looks, one live buffer may
    /// have flipped `sawAudio` and the loss would be judged away (round ten).
    private var deadTrippedSinceTake = false
    /// Seconds of exact-zero samples accepted while the detector held the
    /// stream dead. They sit on the timeline already (no fill), but they are
    /// missing microphone time all the same and the card must say so.
    private var deadZeroSecondsSinceTake: Double = 0

    /// Hand the latched accounting to the meeting recorder and clear it.
    func takeAccounting() -> (silencePlacedSeconds: Double, deadTripped: Bool, deadZeroSeconds: Double) {
        defer { silencePlacedSinceTake = 0; deadTrippedSinceTake = false; deadZeroSecondsSinceTake = 0 }
        return (silencePlacedSinceTake, deadTrippedSinceTake, deadZeroSecondsSinceTake)
    }

    /// Whether the CURRENT bind is the Mac's own microphone. A live built-in
    /// mic always carries a noise floor, so exact zeros from it after audio
    /// are a dead stream, not a headset's silence suppression (review round
    /// six, refuting an earlier blanket rejection).
    private(set) var boundInputIsBuiltIn = false
    /// Samples the CURRENT bind's tap has produced. Confirmation of a rebound
    /// stream is measured here — in samples produced, not in seconds elapsed —
    /// so one buffer followed by a hang is not delivery, and a converter that
    /// stopped producing shows as a stall even while raw buffers keep coming.
    private(set) var producedByTap = 0
    /// Across every bind of this recording — the meeting's "did the tap ever
    /// produce anything" question. Reset at start(), not at rebind.
    private(set) var producedByTapThisRecording = 0
    /// When this recording's timeline began, on the monotonic clock. While
    /// the stream is down the meeting recorder fills the buffer with silence
    /// up to this clock, so the buffer IS the timeline and nothing has to be
    /// inserted at stop.
    private(set) var timelineStart: SuspendingClock.Instant?
    /// Bind to the built-in microphone instead of the system default on the
    /// next bind. Recovery sets it after the default has failed repeatedly.
    var preferBuiltInInput = false
    /// A follow is scheduled or running. The meeting recorder's tick reads
    /// this and stands down, so one engine never has two owners rebinding it.
    private(set) var followInFlight = false
    private var followAttempts = 0

    /// Incremented on every bind. The tap closure carries its generation and
    /// the main-actor hop drops buffers from a retired engine: they used to
    /// land after a rebind and look like the replacement delivering.
    private(set) var bindGeneration = 0

    /// What the input stream is doing, as the engine reports it. A stream
    /// that HAD audio and went quiet is not dead — headsets with silence
    /// suppression emit exact zeros between phrases (see `DeadMicDetector`).
    var streamState: MicStreamState {
        guard isRecording else { return binding ? .binding : .down }
        guard producedByTap > 0, let last = lastProducedAt else { return .binding }
        // Dead: the detector's window of exact zeros on the BUILT-IN mic,
        // which carries a noise floor whenever it is alive. On an external
        // input exact zeros are ambiguous — a headset or a virtual mic with
        // silence suppression emits them whenever its wearer listens — and
        // restarting one, then moving the meeting to the built-in mic after
        // three misses, would break a working device (independent review,
        // 2026-09-03). An external device that is truly dead reaches the
        // user through `micChannelWasSilent` at stop instead.
        if deadMic.isDead && boundInputIsBuiltIn { return .dead }
        // "Delivering" means now. A bind that produced for a while and then
        // stopped is stalled; its earlier count proves nothing about the present.
        return (SuspendingClock.now - last).seconds >= MicRecoveryPolicy.stalledAfterSeconds ? .stalled : .delivering
    }

    /// The meeting recorder declares when its timeline begins — BEFORE the
    /// first bind is attempted. A mic that fails to start and is recovered a
    /// minute later must land at minute one, not at sample zero: with the
    /// timeline anchored only by a successful bind, the whole outage before it
    /// would have gone unfilled and everything after it would sit that much
    /// early against the system channel.
    func beginTimeline() {
        timelineStart = SuspendingClock.now
        timelineDeclared = true
        producedByTapThisRecording = 0
        zeroRun = MicRecovery.ZeroRunTracker()
    }
    /// Exact zeros this recording's tap delivered after audio, on an input
    /// that is not the Mac's own (the built-in one is restarted and its zeros
    /// counted as an outage instead). See `MicRecovery.ZeroRunTracker`.
    private var zeroRun = MicRecovery.ZeroRunTracker()
    var longestZeroRunSecondsAfterAudio: Double { Double(zeroRun.longest) / targetSampleRate }
    /// A meeting declares its timeline before the bind; dictation does not,
    /// and its timeline begins with its first buffer — otherwise a Bluetooth
    /// link taking seconds to deliver put seconds of zeros at the head of
    /// every dictation (independent review, v14).
    private var timelineDeclared = false

    /// Fill the buffer with silence up to the clock as of `at`. Every buffer
    /// the tap accepts calls this first, with its own capture time, so the
    /// gap lands BEFORE the buffer that came after it; the meeting recorder
    /// calls it while nothing arrives (memory grows smoothly instead of in one
    /// piece) and once more at stop. Returns the samples inserted.
    @discardableResult
    func fillSilence(at instant: SuspendingClock.Instant = SuspendingClock.now) -> Int {
        guard let start = timelineStart else { return 0 }
        let expected = MicRecovery.expectedSamples(elapsed: (instant - start).seconds,
                                                  sampleRate: targetSampleRate)
        return fill(toExpected: expected)
    }

    /// Place by the DEVICE's sample clock within a bind: the expected index of
    /// this buffer is the bind's origin index plus the sample time elapsed
    /// since the origin, converted to the timeline's rate. Immune to tap
    /// delivery jitter (the tap thread can be starved for hundreds of
    /// milliseconds under load and used to insert that as silence inside
    /// speech) and to the CPU clock drifting against the device's (~100 ppm
    /// made a 100 ms hole every quarter hour); bounded by the host clock so a
    /// sample time that jumps ahead cannot be filled as hours of zeros (see
    /// `MicRecovery.DevicePlacement`). The first buffer of a bind — and every
    /// buffer without a valid sample time — falls back to the suspending
    /// clock, which is what measures the gap between binds.
    @discardableResult
    func fillSilence(bufferSampleTime: AVAudioFramePosition?, inputRate: Double,
                     capturedAt: SuspendingClock.Instant) -> Int {
        if let t = bufferSampleTime, var placement = bindPlacement,
           let expected = placement.expected(sampleTime: t, capturedAt: capturedAt, current: samples.count,
                                             inputRate: inputRate, sampleRate: targetSampleRate) {
            // Measured from the bind's origin, never from the previous
            // buffer: the device clock has no jitter to forgive, and no
            // per-step rounding to compound. A jump re-originates the bind.
            bindPlacement = placement
            return fill(toExpected: expected, allowanceSeconds: 0)
        }
        // First buffer of a bind (or no sample time, or a straggler from
        // before the origin): the host clock measures the gap between binds,
        // with its allowance. Where this buffer lands becomes the bind's
        // origin.
        let filled = fillSilence(at: capturedAt)
        if let t = bufferSampleTime {
            bindPlacement = MicRecovery.DevicePlacement(originIndex: samples.count, originSampleTime: t,
                                                        originCapturedAt: capturedAt)
        }
        return filled
    }

    private var bindPlacement: MicRecovery.DevicePlacement?

    /// Silence is stored as real samples: 64 KB per second, 3.84 MB per
    /// minute, about 690 MB for a three-hour meeting whose mic never came
    /// back — the price of a buffer that IS the timeline (round six). A
    /// run-length form for silence is the change if that price ever matters.
    private func fill(toExpected expected: Int,
                      allowanceSeconds: Double = MicRecovery.jitterAllowanceSeconds) -> Int {
        let fill = MicRecovery.fillCount(current: samples.count, expected: expected,
                                         sampleRate: targetSampleRate, allowanceSeconds: allowanceSeconds)
        if fill > 0 {
            samples.append(contentsOf: repeatElement(0, count: fill))
            silencePlacedSinceTake += Double(fill) / targetSampleRate
        }
        return fill
    }

    /// Shown to the user when the input stream is dead. Names the remedy that
    /// actually worked in the field, because the fault is usually below the app.
    static let deadMicMessage =
        "Microphone is delivering no audio. Reconnect it or restart macOS audio "
            + "(Terminal: sudo killall coreaudiod), then record again."

    /// Request microphone permission using multiple strategies.
    func requestPermission(_ ask: PermissionAsk) async -> Bool {
        // Strategy 1: AVAudioApplication (macOS 14+)
        if #available(macOS 14.0, *) {
            let perm = AVAudioApplication.shared.recordPermission
            if perm == .granted { return true }
            if perm == .undetermined {
                do {
                    let granted = try await AVAudioApplication.requestRecordPermission()
                    if granted { return true }
                } catch {
                    NSLog("[AudioRecording] AVAudioApplication error: %@", error.localizedDescription)
                }
            }
        }

        // Strategy 2: AVCaptureDevice
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted { return true }
        }

        // Strategy 3: Touch AVAudioEngine to trigger the macOS permission dialog — off the main thread, as every call
        // into the audio system (ITER-086).
        NSLog("[AudioRecording] Trying AVAudioEngine touch to trigger prompt...")
        // With a deadline: a touch that hangs answers "no" and frees the prompt for the next press (Kimi review, P2).
        let touched: Bool = await withCheckedContinuation { answer in
            MicHardware().run({ () -> Bool in
                let testEngine = AVAudioEngine()
                do {
                    try Self.avf("permission touch") {
                        _ = testEngine.inputNode  // accessing inputNode triggers mic prompt
                        testEngine.prepare()
                        try testEngine.start()
                        testEngine.stop()
                    }
                    return true
                } catch {
                    NSLog("[AudioRecording] AVAudioEngine touch failed: %@", error.localizedDescription)
                    _ = Self.tearDown(testEngine)   // a start that raised skipped the stop above
                    return false
                }
            }, done: { result in answer.resume(returning: (try? result.get()) ?? false) }, late: { _ in })
        }
        if touched {
            // Check again after engine touch
            if #available(macOS 14.0, *) {
                return AVAudioApplication.shared.recordPermission == .granted
            }
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }

        return false
    }

    /// Check current mic permission status.
    var hasPermission: Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The microphone prompt was never answered. Reading it asks nothing.
    var permissionUndetermined: Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .undetermined
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// How a follow waits for the device to settle, and how it binds again: seams for the tests (no microphone there).
    var followDelay: (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    var followResume: (AudioRecordingService) throws -> Void = { try $0.resume() }   // keeps what was captured
    /// The recording a follow belongs to, advanced at every explicit `start()` and `stop()`: a follow scheduled in one
    /// recording never binds after the user stopped or cancelled it, or in the next one (independent review,
    /// 2026-10-13, and step-1 review #4: a follow pending at stop turned the microphone back on). `AudioSource` names
    /// it so a practice's teardown stops only the recording it was listening in.
    private(set) var captureSession = 0

    /// Follows the input device after a configuration change: once it settles, the microphone is bound again.
    func follow(afterChangeWhileRecording wasRecording: Bool,
                settleDelay: Double = MicDeviceFollow.settleDelaySeconds) {
        guard MicDeviceFollow.shouldFollow(wasRecording: wasRecording, attempts: followAttempts) else {
            if wasRecording {
                NSLog("[AudioRecording] ⚠️ the input device kept changing — stopped following after %d switch(es)",
                      followAttempts)
            }
            return
        }
        followAttempts += 1
        followInFlight = true
        let attempt = followAttempts
        let session = captureSession
        NSLog("[AudioRecording] input device changed mid-recording — following it (switch %d of %d)",
              attempt, MicDeviceFollow.maxAttempts)
        Task { @MainActor [weak self] in
            await self?.followDelay(settleDelay)
            // A follow whose recording ended owns nothing now: `stop()` released the flag, and the next recording's
            // own follow may hold it (independent review, 2026-10-13).
            guard let self else { return }
            guard self.captureSession == session else {
                NSLog("[AudioRecording] stopped while the device settled — the follow (switch %d) is dropped", attempt)
                return
            }
            defer { self.followInFlight = false }
            guard !self.isRecording, !self.binding else { return }
            do {
                try self.followResume(self)
                NSLog("[AudioRecording] binding the new input device (switch %d)", attempt)
            } catch {
                NSLog("[AudioRecording] ❌ could not follow the device (switch %d): %@",
                      attempt, error.localizedDescription)
            }
        }
    }

    /// Start recording from the user's preferred input device, or the system default when none is configured. The
    /// microphone is opened off the main thread (ITER-086): `start` returns at once, and `reported` hears how the bind
    /// went — nil when the capture runs, the error when it could not be opened or did not answer in time. It is not
    /// called for a recording stopped before its bind answered.
    func start(reported: @escaping @MainActor (Error?) -> Void) throws {
        guard !isRecording, !binding else { return }
        captureSession += 1
        followAttempts = 0
        try bind(keepingSamples: false, reported: reported)
        // A meeting (it declared its timeline) has its own recovery tick; the readiness loop is dictation's.
        if !timelineDeclared { watchReadiness() }
    }

    /// Bring the input back under a live recording. What was captured stays
    /// exactly as it is — the gap is placed as silence before the first
    /// buffer of the new bind, by the clock (see `fillSilence`).
    /// Whether a bind was asked for: none while one is already answering.
    @discardableResult
    func resume() throws -> Bool {
        guard !isRecording, !binding else { return false }
        try bind(keepingSamples: true, reported: { _ in })
        return true
    }

    /// The stream is up but delivering nothing, or was torn down: make the bind again, keeping what was captured.
    /// Whether a bind was asked for (Kimi review, P3: recovery counted attempts that never started).
    @discardableResult
    func restart() throws -> Bool {
        if isRecording { retireInputOnlyBind() }
        return try resume()
    }

    /// The input a bind records from: the built-in microphone when recovery asked for it, the user's pick (Settings →
    /// Microphone) while it is plugged in, or nil — the system default. A picked device that was unplugged falls back
    /// to the default silently. Reads the device list: off the main thread, inside the bind.
    nonisolated private static func chosenInput(preferBuiltIn: Bool,
                                                preferredUID: String) -> (device: AudioInputDevice, isRecovery: Bool)? {
        if preferBuiltIn, let builtIn = AudioInputCatalog.builtInMicrophone() { return (builtIn, true) }
        if !preferredUID.isEmpty, let dev = AudioInputCatalog.device(forUID: preferredUID) { return (dev, false) }
        return nil
    }

    // MARK: - The capture

    /// The live capture, its device, and whether that device is the system default — which a recording follows —
    /// rather than a pick.
    private var inputCapture: MicCapture?
    private var boundDeviceID: AudioDeviceID = 0
    private var boundToDefault = false
    private var boundIsBluetooth = false
    /// The bound device as one log line, read with the bind.
    private var boundDescription = "<none>"
    private var defaultInputObserver: DefaultInputObserver?
    /// How a capture is made and what macOS's default input is: seams for the tests (no microphone there). Both run off
    /// the main thread.
    var makeCapture: @Sendable (AudioDeviceID) throws -> MicCapture = { try InputOnlyCapture(deviceID: $0) }
    var defaultInputDevice: @Sendable () -> AudioDeviceID = { AudioInputCatalog.systemDefaultInputDeviceID() }

    /// Where the bind talks to the audio system (ITER-086); the tests shorten its deadline.
    var hardware = MicHardware()
    /// A bind was asked for and has not answered yet.
    private(set) var binding = false
    /// Calls into the audio system that missed their deadline and have not returned, each by its own id, with the
    /// time it was found hung. While one hung in the last minute is out, no new bind is tried — each would leave one
    /// more thread waiting on Core Audio. Released by that very call returning (an older call returning releases
    /// only itself), or a minute after it hung: then one more attempt goes through — at most one more waiting thread
    /// a minute. Calls started before the first one was found hung (presses within its 3 s) may hang too: bounded by
    /// the presses, not by this gate (Kimi review, P1).
    private var hungCalls: [UUID: SuspendingClock.Instant] = [:]
    /// Calls out right now, hung or not: a call that answers before its deadline notice is processed is never hung.
    private var callsOut: Set<UUID> = []
    static let wedgeRetryAfterSeconds: Double = 60
    /// A hung call from the last minute is still out: the microphone is not tried again yet.
    var waitingOnHungCall: Bool {
        let now = readinessClock()
        return hungCalls.values.contains { (now - $0).seconds < Self.wedgeRetryAfterSeconds }
    }
    /// The last bind found no input device at all: the meeting's recovery paces itself on it and says so at stop.
    private(set) var lastBindFoundNoDevice = false

    /// What a bind found, off the main thread.
    private struct Opened: @unchecked Sendable {
        let capture: MicCapture
        let deviceID: AudioDeviceID
        let toDefault: Bool
        let bluetooth: Bool
        let builtIn: Bool
        let description: String
        let observer: DefaultInputObserver?
    }

    /// Opens the input off the main thread, prepares the buffer here, starts the capture off the main thread again,
    /// and only then is the recorder recording. Every answer is checked against the recording it was asked for.
    private func bind(keepingSamples keep: Bool, reported: @escaping @MainActor (Error?) -> Void) throws {
        if waitingOnHungCall { throw RecordingError.notResponding }
        binding = true
        bindStartedAt = readinessClock()
        let session = captureSession
        let preferBuiltIn = preferBuiltInInput
        let preferredUID = AppSettings.shared.preferredInputDeviceUID
        let makeCapture = self.makeCapture
        let defaultInput = self.defaultInputDevice
        let needsObserver = defaultInputObserver == nil
        let defaultChanged: @Sendable () -> Void = { [weak self] in
            let newDefault = defaultInput()
            Task { @MainActor in self?.defaultInputChanged(to: newDefault) }
        }
        let call = callStarted()
        hardware.run({
            let chosen = Self.chosenInput(preferBuiltIn: preferBuiltIn, preferredUID: preferredUID)
            let deviceID = chosen?.device.deviceID ?? defaultInput()
            guard deviceID != 0 else { throw RecordingError.noInputDevice }
            let capture = try makeCapture(deviceID)
            return Opened(capture: capture, deviceID: deviceID, toDefault: chosen == nil,
                          bluetooth: AudioInputCatalog.isBluetooth(deviceID), builtIn: AudioInputCatalog.isBuiltIn(deviceID),
                          description: AudioInputCatalog.description(of: deviceID),
                          observer: needsObserver ? DefaultInputObserver(defaultChanged) : nil)
        }, done: { [weak self] result in
            guard let self else { return }
            self.callAnswered(call, result)
            self.opened(result, session: session, keep: keep, reported: reported)
        }, late: { [weak self] result in
            if case .success(let opened) = result { Self.stopOffMain(opened.capture) }   // opened after it was given up
            self?.callReturned(call)
        })
    }

    private func opened(_ result: Result<Opened, Error>, session: Int, keep: Bool,
                        reported: @escaping @MainActor (Error?) -> Void) {
        if case .success(let opened) = result, let observer = opened.observer, defaultInputObserver == nil {
            defaultInputObserver = observer
        }
        guard session == captureSession, binding else {   // stopped while it opened
            if case .success(let opened) = result { Self.stopOffMain(opened.capture) }
            return
        }
        let opened: Opened
        switch result {
        case .failure(let error): return bindFailed(error, reported: reported)
        case .success(let value): opened = value
        }
        let handler: AVAudioNodeTapBlock
        do {
            handler = try prepareBind(inputFormat: opened.capture.format, keepingSamples: keep)
        } catch {
            Self.stopOffMain(opened.capture)
            return bindFailed(error, reported: reported)
        }
        let generation = bindGeneration
        let capture = opened.capture
        let changed: @MainActor (MicCaptureEvent) -> Void = { [weak self] event in
            self?.captureChanged(event, generation: generation)
        }
        let call = callStarted()
        hardware.run({ try capture.start(handler: handler, onEvent: changed) }, done: { [weak self] result in
            guard let self else { return }
            self.callAnswered(call, result)
            self.started(result, opened, session: session, generation: generation, reported: reported)
        }, late: { [weak self] _ in
            Self.stopOffMain(capture)   // its start returned after it was given up: whatever it did, it stops
            self?.callReturned(call)
        })
    }

    private func started(_ result: Result<Void, Error>, _ opened: Opened, session: Int, generation: Int,
                         reported: @escaping @MainActor (Error?) -> Void) {
        let hung = (try? result.get()) == nil && Self.isHung(result)
        guard session == captureSession, binding, generation == bindGeneration else {   // stopped while it started
            if !hung { Self.stopOffMain(opened.capture) }   // a hung start is stopped when it returns
            return
        }
        if case .failure(let error) = result {
            converter = nil
            bindGeneration += 1   // whatever this bind queued is not counted
            if !hung { Self.stopOffMain(opened.capture) }
            return bindFailed(error, reported: reported)
        }
        NSLog("[AudioRecording] bind → %@ | %.0f Hz, %d ch, input only",
              opened.description, opened.capture.format.sampleRate, Int(opened.capture.format.channelCount))
        inputCapture = opened.capture
        boundDeviceID = opened.deviceID
        boundToDefault = opened.toDefault
        boundIsBluetooth = opened.bluetooth
        boundInputIsBuiltIn = opened.builtIn
        boundDescription = opened.description
        lastBindFoundNoDevice = false
        binding = false
        isRecording = true
        reported(nil)
    }

    private func bindFailed(_ error: Error, reported: @escaping @MainActor (Error?) -> Void) {
        binding = false
        lastBindFoundNoDevice = (error as? RecordingError) == .noInputDevice
        NSLog("[AudioRecording] ❌ the microphone could not be bound: %@", error.localizedDescription)
        reported(error)
    }

    private static func isHung<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure(let error) = result { return (error as? RecordingError) == .notResponding }
        return false
    }

    private func callStarted() -> UUID {
        let call = UUID()
        callsOut.insert(call)
        return call
    }

    /// The deadline's answer or the call's own. A call already returned — its late answer can reach the main actor
    /// before the deadline's notice does (Kimi review, P2) — is not hung.
    private func callAnswered<T>(_ call: UUID, _ result: Result<T, Error>) {
        guard Self.isHung(result) else {
            callsOut.remove(call)
            return
        }
        guard callsOut.contains(call) else { return }   // it already returned: its late answer came first
        hungCalls[call] = readinessClock()
        NSLog("[AudioRecording] ⚠️ the audio system did not answer in %.0f s — no new bind until it does",
              hardware.deadline)
    }

    /// A call returned after its deadline: it releases itself, and only itself.
    private func callReturned(_ call: UUID) {
        callsOut.remove(call)
        guard hungCalls.removeValue(forKey: call) != nil else { return }
        NSLog("[AudioRecording] the audio system answered after its deadline — %d call(s) still out", hungCalls.count)
    }

    /// The bound device went away, or its input format changed under the capture: the recording follows — at once
    /// for a new format on the same device, after the settle delay for a device that is leaving.
    private func captureChanged(_ event: MicCaptureEvent, generation: Int) {
        guard generation == bindGeneration, isRecording else { return }   // news of a retired bind
        NSLog("[AudioRecording] 🔄 %@ mid-recording — following",
              event == .deviceGone ? "the input device went away" : "the input format changed")
        retireInputOnlyBind()
        follow(afterChangeWhileRecording: true,
               settleDelay: event == .formatChanged ? 0 : MicDeviceFollow.settleDelaySeconds)
    }

    /// macOS's default input changed (AirPods arrived, a headset left). A capture holds one device and does not move
    /// with the default; a recording on the default follows it, one on the user's pick stays.
    /// `newDefault` is read where the change was heard, off the main thread.
    func defaultInputChanged(to newDefault: AudioDeviceID) {
        guard isRecording,
              MicDeviceFollow.followsDefaultChange(boundToDefault: boundToDefault, bound: boundDeviceID,
                                                   newDefault: newDefault) else { return }
        NSLog("[AudioRecording] 🔄 the default input changed mid-recording — following it")
        retireInputOnlyBind()
        follow(afterChangeWhileRecording: true)
    }

    /// Retires the input-only bind now: its queued buffers are dropped and its capture stops off the main thread —
    /// a background thread may wait on the audio system, the main thread may not.
    private func retireInputOnlyBind() {
        isRecording = false
        bindGeneration += 1
        converter = nil
        if let capture = inputCapture {
            inputCapture = nil
            Self.stopOffMain(capture)
        }
    }

    private static func stopOffMain(_ capture: MicCapture) {
        Task.detached(priority: .utility) { capture.stop() }
    }

    // MARK: - Judged by the clock

    /// How the check waits and what time it is: seams for the tests.
    var readinessDelay: (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    var readinessClock: () -> SuspendingClock.Instant = { SuspendingClock.now }
    /// When the current bind was made, on either path: a bind that has produced nothing is judged from here.
    private(set) var bindStartedAt: SuspendingClock.Instant?
    private var readinessRebinds = 0

    /// Judges the input-only recording by the clock until it ends (see `MicReadiness`): one more bind when the
    /// microphone delivers nothing, then the user is told. Stands down while a follow brings the microphone back.
    private func watchReadiness() {
        let session = captureSession
        readinessRebinds = 0
        Task { @MainActor [weak self] in
            var seenGeneration = -1
            var seenProduced = 0
            var progressAt: SuspendingClock.Instant?
            var lastCheck = self?.readinessClock()
            while true {
                guard let delay = self?.readinessDelay else { return }
                await delay(MicReadiness.checkEverySeconds)
                guard let self, self.captureSession == session else { return }
                let now = self.readinessClock()
                defer { lastCheck = now }
                // A check that came late means the main thread was busy — and with it the buffers' way here.
                if let last = lastCheck, (now - last).seconds > MicReadiness.checkEverySeconds + 0.5 { continue }
                // A follow, or a bind still answering — which ends by `MicHardware.deadline` — has the microphone.
                if self.followInFlight || self.binding { continue }
                if self.bindGeneration != seenGeneration {
                    seenGeneration = self.bindGeneration
                    seenProduced = self.producedByTap
                    progressAt = seenProduced > 0 ? now : nil
                } else if self.producedByTap != seenProduced {
                    seenProduced = self.producedByTap
                    progressAt = now
                }
                switch MicReadiness.judge(bound: self.isRecording,
                                          sinceBind: self.bindStartedAt.map { (now - $0).seconds } ?? 0,
                                          sinceLastBuffer: progressAt.map { (now - $0).seconds },
                                          bluetooth: self.boundIsBluetooth,
                                          rebindsSpent: self.readinessRebinds) {
                case .fine:
                    continue
                case .rebind:
                    self.readinessRebinds += 1
                    NSLog("[AudioRecording] ⚠️ the microphone is delivering nothing — binding it once more")
                    do {
                        try self.restart()
                    } catch {
                        NSLog("[AudioRecording] ❌ binding again failed: %@", error.localizedDescription)
                    }
                case .tellUser:
                    guard self.micHealthError == nil else { continue }
                    NSLog("[AudioRecording] ❌ the microphone delivered nothing, bound once more — telling the user")
                    self.micHealthError = Self.deadMicMessage
                }
            }
        }
    }

    /// What every bind does before its first buffer, whichever path captures it: a converter from the input's format
    /// to 16 kHz mono, the buffer kept or begun anew, this bind's state cleared and a new generation. Returns the
    /// handler for the bind's buffers.
    private func prepareBind(inputFormat: AVAudioFormat, keepingSamples keep: Bool) throws -> AVAudioNodeTapBlock {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.noInputDevice
        }

        // Target format: 16kHz mono Float32
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.formatError
        }

        // Create converter for resampling
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.converterError
        }

        self.converter = converter
        if keep {
            NSLog("[AudioRecording] resuming under a live recording — %d samples kept", self.samples.count)
        } else {
            self.samples = []
            self.samples.reserveCapacity(Int(targetSampleRate) * 60) // ~1 min pre-alloc
            // Dictation starts here directly; a meeting declared its timeline
            // through `beginTimeline` before asking for the bind.
            if !self.timelineDeclared {
                self.timelineStart = nil          // anchored at the first buffer, below
                self.producedByTapThisRecording = 0
                self.zeroRun = MicRecovery.ZeroRunTracker()
            }
        }
        self.deadMic.reset()
        self.micHealthError = nil
        self.firstBufferAt = nil
        self.lastProducedAt = nil
        self.lastAudioAt = nil
        self.bindPlacement = nil
        self.producedByTap = 0
        self.bindGeneration += 1
        return bufferHandler(inputFormat: inputFormat, outputFormat: outputFormat,
                             converter: converter, generation: self.bindGeneration)
    }

    /// What the recorder does with every captured buffer, on the thread that delivered it: levels from the raw
    /// buffer and conversion to 16 kHz mono there, then — on the main actor, for the bind `gen` only — placement on
    /// the timeline, the meters and the dead-stream watchdog.
    private func bufferHandler(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
                               converter: AVAudioConverter, generation gen: Int) -> AVAudioNodeTapBlock {
        return { [weak self] buffer, when in
            guard let self else { return }
            // The buffer's own capture time, taken here on the audio thread —
            // the main-actor hop can run seconds later under load, and the
            // timeline must not inherit that delay. The device's sample clock
            // rides along: within a bind it is what places the buffer.
            let capturedAt = SuspendingClock.now
            let sampleTime: AVAudioFramePosition? = when.isSampleTimeValid ? when.sampleTime : nil

            // Calculate audio level for UI + raw RMS for silence guards
            let (rawRMS, level) = self.calculateLevels(buffer: buffer)
            let inputFrames = Int(buffer.frameLength)

            // Convert to 16kHz mono
            // Capacity rounded UP with headroom, and the input fed exactly
            // once. `1024 × 16000 / 48000` is 341⅓: truncating the capacity
            // to 341 dropped a third of a sample per buffer — a stream 0.1 %
            // slow that per-buffer placement then revealed as a zero every
            // third buffer (review round ten). Same pattern as
            // `StreamingResampler`.
            let frameCount = AVAudioFrameCount(
                (Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate).rounded(.up)
            ) + 16
            var newSamples: [Float] = []
            if frameCount > 0,
               let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) {
                var error: NSError?
                var fed = false
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if fed {
                        // .noDataNow, not .endOfStream: the next tap buffer
                        // continues this stream; ending it would flush and
                        // reset the converter's state.
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status != .error, let channelData = outputBuffer.floatChannelData {
                    newSamples = Array(UnsafeBufferPointer(start: channelData[0],
                                                           count: Int(outputBuffer.frameLength)))
                } else if let error {
                    // This NSError was captured and never read until 2026-08-12,
                    // so a converter that quietly stopped producing audio looked
                    // exactly like a silent room.
                    NSLog("%@", "[AudioRecording] converter failed (status=\(status.rawValue)): "
                        + error.localizedDescription)
                }
            }

            // Meters and the silence watchdog read the RAW input buffer, so they
            // must run whether or not conversion succeeded — publishing them
            // only on success used to hide both halves of a failure.
            Task { @MainActor in
                // A buffer from a retired bind arriving after the rebind must
                // not be mistaken for the replacement delivering.
                guard gen == self.bindGeneration else { return }
                let now = capturedAt
                if self.firstBufferAt == nil { self.firstBufferAt = now }
                if !newSamples.isEmpty {
                    if self.timelineStart == nil { self.timelineStart = now }   // undeclared: begins here
                    // Place this buffer at its own time: whatever went missing
                    // since the last placed sample becomes silence BEFORE it.
                    self.fillSilence(bufferSampleTime: sampleTime, inputRate: inputFormat.sampleRate,
                                     capturedAt: now)
                    self.samples.append(contentsOf: newSamples)
                    self.producedByTap += newSamples.count
                    self.producedByTapThisRecording += newSamples.count
                    self.lastProducedAt = now
                    if rawRMS > 0, rawRMS.isFinite {
                        self.lastAudioAt = now
                        self.zeroRun.note(samples: newSamples.count, silent: false)
                        // The verdict is about now: audio means the microphone delivers again.
                        if self.micHealthError != nil { self.micHealthError = nil }
                    } else if rawRMS == 0, !self.boundInputIsBuiltIn {
                        self.zeroRun.note(samples: newSamples.count, silent: true)
                    }
                    if rawRMS == 0, self.deadMic.isDead, self.boundInputIsBuiltIn {
                        self.deadZeroSecondsSinceTake += Double(newSamples.count) / self.targetSampleRate
                    }
                }
                self.audioLevel = level
                self.rawRMSLevel = rawRMS
                self.updateBars(level: level)
                self.observeStreamHealth(rms: rawRMS, frames: inputFrames,
                                         sampleRate: inputFormat.sampleRate)
            }
        }
    }

    /// Watchdog for an input that has stopped producing audio entirely.
    ///
    /// Runs on the main actor (the tap hands it over) so the detector's state
    /// is never touched from the audio thread.
    private func observeStreamHealth(rms: Float, frames: Int, sampleRate: Double) {
        guard isRecording,
              deadMic.observe(rms: rms, frames: frames, sampleRate: sampleRate) else { return }
        // Latched for the meeting recorder's next tick, qualified NOW: a run
        // can begin and end between two polls, and a live buffer after it
        // must not be allowed to explain it away. The window of zeros that
        // tripped the detector is already on the timeline and already lost —
        // it is counted here, since the per-buffer count starts only after
        // the trip.
        if boundInputIsBuiltIn {
            deadTrippedSinceTake = true
            deadZeroSecondsSinceTake += DeadMicDetector.deadAfterSeconds
        }

        let bind = boundDescription

        // A zero-run on a stream that HAS delivered audio is ambiguous:
        // Bluetooth headsets and interfaces with silence suppression emit
        // bit-exact zeros between phrases, and telling that user their mic is
        // dead would be a lie shown at the worst moment. Log it, don't shout.
        guard !deadMic.sawAudio else {
            NSLog("[AudioRecording] ⚠️ %.1fs of digital silence mid-recording (stream had audio before) — %@",
                  DeadMicDetector.deadAfterSeconds, bind)
            return
        }

        // Nothing but zeros since this recording began — the stream is dead.
        NSLog("[AudioRecording] ❌ input is DIGITAL SILENCE for %.1fs, no audio at all this recording — %@",
              DeadMicDetector.deadAfterSeconds, bind)
        micHealthError = Self.deadMicMessage   // every bind opens a fresh capture
    }

    /// ITER-019 — total samples accumulated so far. `LiveMeetingAdvisor` uses
    /// this as the offset between periodic peeks. Cheap O(1).
    var currentSampleCount: Int { samples.count }

    /// ITER-019 — non-destructive read. Returns samples accumulated since `from`
    /// (exclusive). Doesn't drain or modify the buffer — `stop()` still returns
    /// the FULL recording for final transcription. Used by realtime partial transcribe.
    func peekSamples(from index: Int) -> [Float] {
        guard index < samples.count else { return [] }
        let safeStart = max(0, index)
        return Array(samples[safeStart..<samples.count])
    }

    /// ITER-076 P2 — non-destructive read of a bounded window: the samples
    /// `[from, from + count)`, clamped to what the buffer holds. The live
    /// hints read one utterance at a time and must not copy the whole tail of
    /// the meeting behind it. Same isolation as `peekSamples(from:)`.
    func peekSamples(from index: Int, count: Int) -> [Float] {
        SampleWindow.slice(samples, from: index, count: count)
    }

    /// Stop recording and return the collected PCM samples.
    func stop() -> [Float] {
        // Retire the bind: a tap task already queued must not repopulate the
        // buffer this method is about to clear (review, 2026-09-03).
        bindGeneration += 1
        captureSession += 1   // and a device-change follow still waiting: it binds nothing after stop
        followInFlight = false
        binding = false       // a bind still answering is put away when it does

        if let capture = inputCapture {
            inputCapture = nil
            Self.stopOffMain(capture)
        }
        converter = nil
        isRecording = false
        firstBufferAt = nil
        lastProducedAt = nil
        lastAudioAt = nil
        bindPlacement = nil
        producedByTap = 0
        timelineStart = nil
        timelineDeclared = false
        silencePlacedSinceTake = 0
        deadTrippedSinceTake = false
        deadZeroSecondsSinceTake = 0
        audioLevel = 0
        rawRMSLevel = 0
        audioBars = Array(repeating: 0, count: 24)

        let result = samples
        samples = []
        return result
    }

    private func updateBars(level: Float) {
        barPhase += 0.12
        let count = 24
        let mid = count / 2
        for i in 0..<count {
            let distFromCenter = abs(i - mid)
            let normalizedDist = Double(distFromCenter) / Double(mid)
            // Multiple frequency components for richer spectrum look
            let f1 = sin(barPhase * 1.0 + Double(i) * 0.5) * 0.4
            let f2 = sin(barPhase * 2.3 + Double(i) * 0.8) * 0.25
            let f3 = sin(barPhase * 3.7 + Double(i) * 1.2) * 0.15
            let variation = 0.5 + f1 + f2 + f3
            // Center bars are taller, edges fade
            let envelope = 1.0 - normalizedDist * 0.65
            let raw = Double(level) * variation * envelope
            audioBars[i] = Float(max(0.03, min(1.0, raw)))
        }
    }

    /// Calculate audio level using RMS + non-linear curve for better sensitivity.
    /// Normal speech (~0.01-0.05 raw) maps to ~0.3-0.7 output range.
    private func calculateLevels(buffer: AVAudioPCMBuffer) -> (raw: Float, boosted: Float) {
        guard let channelData = buffer.floatChannelData else { return (0, 0) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return (0, 0) }

        // RMS (root mean square) — better than mean absolute for audio
        var sumSq: Float = 0
        let data = channelData[0]
        for i in 0..<count {
            sumSq += data[i] * data[i]
        }
        let rms = sqrtf(sumSq / Float(count))

        // Non-linear boost: sqrt curve makes quiet sounds more visible
        // rms ~0.005 (whisper) → 0.22, rms ~0.02 (normal) → 0.45, rms ~0.08 (loud) → 0.89
        let boosted = sqrtf(min(rms * 12.0, 1.0))
        return (rms, boosted)
    }

    enum RecordingError: LocalizedError, Equatable {
        case noInputDevice
        case formatError
        case converterError
        /// The audio system did not answer within `MicHardware.deadline` (ITER-086).
        case notResponding

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone found"
            case .formatError: "Failed to create audio format"
            case .converterError: "Failed to create audio converter"
            case .notResponding: "The microphone isn't responding. Try again in a few seconds."
            }
        }
    }
}
