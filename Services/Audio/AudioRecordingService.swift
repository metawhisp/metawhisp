import AVFAudio
import AVFoundation
import Foundation

/// Records audio from the microphone using AVAudioEngine.
/// Outputs 16kHz mono Float32 PCM suitable for WhisperKit.
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

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var barPhase: Double = 0
    private var engineWarmed = false
    private var configObserver: Any?
    /// Digital-silence watchdog, re-armed per recording.
    private var deadMic = DeadMicDetector()
    /// Set when the watchdog fires: this engine is suspect, so `stop()` drops
    /// it and the next `start()` binds a fresh one. Rebuilding mid-recording is
    /// deliberately NOT done — see the DEADLOCK RULES on `observeDeviceChanges`.
    private var engineNeedsRebuild = false

    /// Holds an engine's LAST strong reference so its deallocation happens on
    /// a background thread, per the DEADLOCK RULES below. A detached task that
    /// merely retains a copy is not enough: if the task finishes first, the
    /// main-local reference performs the final release (review probe: 44 of
    /// 10,000 runs). With the grave, the main thread never holds the engine
    /// once it has been handed over.
    private final class EngineGrave {
        private var engine: AVAudioEngine?
        init(_ engine: AVAudioEngine?) { self.engine = engine }
        func bury(tearDown: Bool) {
            if tearDown {
                engine?.inputNode.removeTap(onBus: 0)
                engine?.stop()
            }
            engine = nil
        }
    }

    private static func releaseOffMain(_ grave: EngineGrave, tearDown: Bool) {
        Task.detached(priority: .utility) { grave.bury(tearDown: tearDown) }
    }

    /// A fresh engine whose `start()` threw inside `bind()`. The grave is
    /// created there but buried only HERE, from the caller — after bind()'s
    /// own local reference has gone out of scope — so the grave's is the last
    /// reference and the release is off-main deterministically.
    private var pendingGrave: EngineGrave?

    private func buryPending() {
        guard let grave = pendingGrave else { return }
        pendingGrave = nil
        Self.releaseOffMain(grave, tearDown: false)
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
    /// Incremented on every bind. The tap closure carries its generation and
    /// the main-actor hop drops buffers from a retired engine: they used to
    /// land after a rebind and look like the replacement delivering.
    private var bindGeneration = 0

    /// What the input stream is doing, as the engine reports it. A stream
    /// that HAD audio and went quiet is not dead — headsets with silence
    /// suppression emit exact zeros between phrases (see `DeadMicDetector`).
    var streamState: MicStreamState {
        guard isRecording else { return .down }
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
    func requestPermission() async -> Bool {
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

        // Strategy 3: Touch AVAudioEngine to trigger the macOS permission dialog
        NSLog("[AudioRecording] Trying AVAudioEngine touch to trigger prompt...")
        let testEngine = AVAudioEngine()
        let _ = testEngine.inputNode  // accessing inputNode triggers mic prompt
        do {
            testEngine.prepare()
            try testEngine.start()
            testEngine.stop()
            // Check again after engine touch
            if #available(macOS 14.0, *) {
                return AVAudioApplication.shared.recordPermission == .granted
            }
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } catch {
            NSLog("[AudioRecording] AVAudioEngine touch failed: %@", error.localizedDescription)
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

    /// Pre-warm audio engine at app startup (call once).
    func warmUp() {
        guard !engineWarmed else { return }
        let eng = AVAudioEngine()
        let _ = eng.inputNode // force lazy init of input node
        eng.prepare()
        self.engine = eng
        engineWarmed = true
        observeDeviceChanges()
        NSLog("[AudioRecording] Engine pre-warmed")
    }

    /// Listen for audio device changes (AirPods connect/disconnect, etc.)
    /// Observer is added only once — subsequent calls are no-ops.
    /// Without this guard, each `warmUp()` adds another observer,
    /// and each observer triggers warmUp again → cascading infinite loop
    /// when the OS fires configuration-change notifications back-to-back.
    ///
    /// DEADLOCK RULES (2026-07-22 — founder's app froze for good; proven by
    /// sampling the wedged process, both sides of the cycle on file):
    /// - `queue:` MUST stay nil. With `queue: .main`, AVFAudio's internal
    ///   "engine" queue posts this notification and BLOCKS in
    ///   `-[NSOperation waitUntilFinished]` until the main thread runs the
    ///   block — one half of the deadlock. With nil the block runs inline on
    ///   the posting thread and only spawns a Task, never blocking it.
    /// - The old engine MUST be released OFF the main thread.
    ///   `-[AVAudioEngine dealloc]` does `dispatch_sync` onto that same
    ///   "engine" queue; if a second config-change is in flight there, the
    ///   main thread waits forever (`__DISPATCH_WAIT_FOR_QUEUE__`) — the
    ///   other half. A background thread may wait; the main thread may not.
    private func observeDeviceChanges() {
        guard configObserver == nil else { return }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: nil
        ) { [weak self] note in
            // The engine that changed, by identity only — holding the object
            // could make this task's stale reference its final release, on
            // the main thread. A notification from an engine already retired
            // must not tear down its replacement (review, 2026-09-03).
            let changedID = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            NSLog("[AudioRecording] 🔄 Audio device changed — resetting engine")
            Task { @MainActor in
                guard let self else { return }
                if let changedID, let current = self.engine, changedID != ObjectIdentifier(current) {
                    NSLog("[AudioRecording] config change for an engine that is not this recording's (retired, or the other instance's) — ignored")
                    return
                }
                let wasRecording = self.isRecording
                if wasRecording {
                    self.isRecording = false
                    // Retire the bind NOW: its queued callbacks must not land
                    // after the replacement is installed.
                    self.bindGeneration += 1
                    NSLog("[AudioRecording] Recording interrupted by device change")
                }
                // Detach the engine; next `start()` lazy-inits a fresh one.
                // DON'T call warmUp() here — inputNode lazy init probes the
                // device again → another config-change → observer loop.
                let grave = EngineGrave(self.engine)
                self.engine = nil
                self.converter = nil
                self.engineWarmed = false
                // Tear down + release off-main (see DEADLOCK RULES above).
                Task.detached(priority: .utility) {
                    grave.bury(tearDown: wasRecording)
                    // engine released inside bury(), on a background thread.
                }
            }
        }
    }

    /// Start recording from the user's preferred input device, or system
    /// default when none is configured.
    func start() throws {
        guard !isRecording else { return }
        defer { buryPending() }
        try bind(keepingSamples: false)
    }

    /// Bring the input back under a live recording. What was captured stays
    /// exactly as it is — the gap is placed as silence before the first
    /// buffer of the new bind, by the clock (see `fillSilence`).
    func resume() throws {
        guard !isRecording else { return }
        defer { buryPending() }
        try bind(keepingSamples: true)
    }

    /// The stream is up but delivering nothing, or was torn down: make the
    /// bind again, keeping what was captured. The old engine goes to the grave
    /// — released off the main thread, per the DEADLOCK RULES above.
    func restart() throws {
        if isRecording {
            let grave = EngineGrave(engine)
            engine = nil
            converter = nil
            engineWarmed = false
            isRecording = false
            bindGeneration += 1   // retire this bind's queued callbacks now
            Self.releaseOffMain(grave, tearDown: true)
        }
        try resume()
    }

    private func bind(keepingSamples keep: Bool) throws {
        // ITER-060.3 (Codex) — the device-change observer used to be installed
        // only via warmUp(), which AppDelegate calls for the DICTATION mic
        // alone. The meeting mic instance never observed device changes, so an
        // AirPods connect/disconnect mid-meeting silently killed its capture
        // while the recording looked alive through the system channel.
        // observeDeviceChanges() is idempotent — installing here covers every
        // instance that records.
        observeDeviceChanges()

        // Reuse existing engine or create new
        let fresh = self.engine == nil
        let engine = self.engine ?? AVAudioEngine()
        do {
            try bindBody(engine: engine, keepingSamples: keep)
        } catch {
            // Whatever threw — format, converter, start — the engine must not
            // perform its final release on the main thread; the caller buries
            // it once this frame is gone. A REUSED engine that threw is dropped
            // too: kept warm across recordings, a stale one threw on every
            // recovery attempt for a whole meeting while the built-in mic sat
            // available (independent review, v14).
            if fresh {
                self.pendingGrave = EngineGrave(engine)
            } else {
                self.pendingGrave = EngineGrave(self.engine)
                self.engine = nil
                self.converter = nil
                self.engineWarmed = false
            }
            throw error
        }
    }

    private func bindBody(engine: AVAudioEngine, keepingSamples keep: Bool) throws {

        // Apply user-picked input device (Settings → Microphone) BEFORE
        // touching the input node. If the picked device was unplugged we
        // silently fall back to whatever macOS has as default.
        let preferredUID = AppSettings.shared.preferredInputDeviceUID
        if preferBuiltInInput, let builtIn = AudioInputCatalog.builtInMicrophone() {
            // Recovery: the default after a device change has failed enough
            // times to stop trusting it. The Mac's own microphone always exists.
            // The engine is dropped at stop so the NEXT recording rebinds per
            // the user's settings — clearing the flag alone left the reused
            // engine on the built-in mic (review, 2026-09-03).
            let ok = AudioInputCatalog.setInputDevice(builtIn, on: engine)
            engineNeedsRebuild = true
            NSLog("[AudioRecording] recovery → built-in microphone %@ (%@)", builtIn.name, ok ? "OK" : "FAIL")
        } else if !preferredUID.isEmpty,
           let dev = AudioInputCatalog.device(forUID: preferredUID) {
            let ok = AudioInputCatalog.setInputDevice(dev, on: engine)
            NSLog("[AudioRecording] input device → %@ (%@)", dev.name, ok ? "OK" : "FAIL")
        }

        let inputNode = engine.inputNode
        // A bind that failed after installing its tap used to leave that tap
        // in place; the next bind installed a second one on the same bus and
        // the process was terminated. Removing a tap that is not there is a
        // no-op, so this is unconditional (review, 2026-09-03).
        inputNode.removeTap(onBus: 0)

        // ITER-060.5 — AEC (setVoiceProcessingEnabled) REMOVED, 2026-08-10.
        // It shipped in 1.3.23 and broke meeting recording: measured on the
        // founder's Mac, enabling voice processing flips the built-in mic's
        // input format from 3 channels to NINE, layout
        // kAudioChannelLayoutTag_DiscreteInOrder — a shape this pipeline's
        // «read channelData[0], downmix to 16k mono» path was never designed
        // for. Symptom: meetings finalized with an empty transcript and
        // «No speech detected in recording» while dictation (same hardware,
        // no voice processing) worked fine in the same minute.
        // Echo duplicates stay handled at the TEXT layer by
        // MeetingTranscriptSanitizer.dedupeCrossChannelEcho (1.3.22, measured
        // against 863 real duplicates) — that is the shipping defense.
        // Any future AEC attempt must first prove, on real hardware, that the
        // post-VP format still yields speech through the converter.
        let inputFormat = inputNode.outputFormat(forBus: 0)

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
        let gen = self.bindGeneration

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, when in
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

        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                // Leave nothing behind: no tap on a stopped engine. The fresh
                // engine, if it was one, is buried by `bind()`'s catch.
                inputNode.removeTap(onBus: 0)
                self.converter = nil
                throw error
            }
        }

        // The bind, on the record. Absent this line the 2026-08-12 dead-mic
        // investigation had nothing to reason about: not the device, not the
        // channel count, not the layout. Logged on EVERY start because the
        // failure is intermittent and only the failing run's values matter.
        NSLog("[AudioRecording] bind → %@ | %.0f Hz, %d ch, layout=%@",
              AudioInputCatalog.boundInputDescription(for: engine),
              inputFormat.sampleRate,
              Int(inputFormat.channelCount),
              inputFormat.channelLayout.map { "0x" + String($0.layoutTag, radix: 16) } ?? "<nil>")

        self.engine = engine
        self.isRecording = true
        self.boundInputIsBuiltIn = AudioInputCatalog.boundInputIsBuiltIn(for: engine)
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

        let bind = engine.map { AudioInputCatalog.boundInputDescription(for: $0) } ?? "<no engine>"

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
        micHealthError = Self.deadMicMessage
        engineNeedsRebuild = true
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

    /// Stop recording and return the collected PCM samples.
    func stop() -> [Float] {
        // Retire the bind: a tap task already queued must not repopulate the
        // buffer this method is about to clear (review, 2026-09-03).
        bindGeneration += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Keep engine alive for reuse — don't nil it...
        // ...unless this recording caught the input delivering digital silence.
        // Then the bind is suspect and reuse would carry the fault into every
        // later recording, which is exactly how one dead mic ate eight
        // dictations on 2026-08-12. Rebuilding happens HERE, between
        // recordings — never mid-tap, per the DEADLOCK RULES above — and the
        // release is handed off-main for the same reason.
        if engineNeedsRebuild {
            let grave = EngineGrave(engine)
            engine = nil
            engineWarmed = false
            engineNeedsRebuild = false
            NSLog("[AudioRecording] engine dropped after a recovery rebuild — next start() rebinds per settings")
            Self.releaseOffMain(grave, tearDown: false)
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

    enum RecordingError: LocalizedError {
        case noInputDevice
        case formatError
        case converterError

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone found"
            case .formatError: "Failed to create audio format"
            case .converterError: "Failed to create audio converter"
            }
        }
    }
}
