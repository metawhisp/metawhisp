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
        ) { [weak self] _ in
            NSLog("[AudioRecording] 🔄 Audio device changed — resetting engine")
            Task { @MainActor in
                guard let self else { return }
                let wasRecording = self.isRecording
                if wasRecording {
                    self.isRecording = false
                    NSLog("[AudioRecording] Recording interrupted by device change")
                }
                // Detach the engine; next `start()` lazy-inits a fresh one.
                // DON'T call warmUp() here — inputNode lazy init probes the
                // device again → another config-change → observer loop.
                let oldEngine = self.engine
                self.engine = nil
                self.converter = nil
                self.engineWarmed = false
                // Tear down + release off-main (see DEADLOCK RULES above).
                Task.detached(priority: .utility) {
                    if wasRecording {
                        oldEngine?.inputNode.removeTap(onBus: 0)
                        oldEngine?.stop()
                    }
                    // oldEngine released here, on a background thread.
                }
            }
        }
    }

    /// Start recording from the user's preferred input device, or system
    /// default when none is configured.
    func start() throws {
        guard !isRecording else { return }

        // ITER-060.3 (Codex) — the device-change observer used to be installed
        // only via warmUp(), which AppDelegate calls for the DICTATION mic
        // alone. The meeting mic instance never observed device changes, so an
        // AirPods connect/disconnect mid-meeting silently killed its capture
        // while the recording looked alive through the system channel.
        // observeDeviceChanges() is idempotent — installing here covers every
        // instance that records.
        observeDeviceChanges()

        // Reuse existing engine or create new
        let engine = self.engine ?? AVAudioEngine()

        // Apply user-picked input device (Settings → Microphone) BEFORE
        // touching the input node. If the picked device was unplugged we
        // silently fall back to whatever macOS has as default.
        let preferredUID = AppSettings.shared.preferredInputDeviceUID
        if !preferredUID.isEmpty,
           let dev = AudioInputCatalog.device(forUID: preferredUID) {
            let ok = AudioInputCatalog.setInputDevice(dev, on: engine)
            NSLog("[AudioRecording] input device → %@ (%@)", dev.name, ok ? "OK" : "FAIL")
        }

        let inputNode = engine.inputNode

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
        self.samples = []
        self.samples.reserveCapacity(Int(targetSampleRate) * 60) // ~1 min pre-alloc
        self.deadMic.reset()
        self.micHealthError = nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate audio level for UI + raw RMS for silence guards
            let (rawRMS, level) = self.calculateLevels(buffer: buffer)
            let inputFrames = Int(buffer.frameLength)

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate
            )
            var newSamples: [Float] = []
            if frameCount > 0,
               let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) {
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData, let channelData = outputBuffer.floatChannelData {
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
                if !newSamples.isEmpty { self.samples.append(contentsOf: newSamples) }
                self.audioLevel = level
                self.rawRMSLevel = rawRMS
                self.updateBars(level: level)
                self.observeStreamHealth(rms: rawRMS, frames: inputFrames,
                                         sampleRate: inputFormat.sampleRate)
            }
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
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
    }

    /// Watchdog for an input that has stopped producing audio entirely.
    ///
    /// Runs on the main actor (the tap hands it over) so the detector's state
    /// is never touched from the audio thread.
    private func observeStreamHealth(rms: Float, frames: Int, sampleRate: Double) {
        guard isRecording,
              deadMic.observe(rms: rms, frames: frames, sampleRate: sampleRate) else { return }

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
            let dying = engine
            engine = nil
            engineWarmed = false
            engineNeedsRebuild = false
            NSLog("[AudioRecording] engine dropped after digital silence — next start() rebinds")
            Task.detached(priority: .utility) { _ = dying?.isRunning }
        }
        converter = nil
        isRecording = false
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
