import AVFAudio
import AVFoundation
import Foundation

/// Records audio from the microphone using AVAudioEngine.
/// Outputs 16kHz mono Float32 PCM suitable for WhisperKit.
@MainActor
final class AudioRecordingService: ObservableObject, AudioSource {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    @Published var audioBars: [Float] = Array(repeating: 0, count: 24)

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var barPhase: Double = 0
    private var engineWarmed = false
    private var configObserver: Any?

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
    private func observeDeviceChanges() {
        guard configObserver == nil else { return }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            NSLog("[AudioRecording] 🔄 Audio device changed — resetting engine")
            Task { @MainActor in
                let wasRecording = self.isRecording
                if wasRecording {
                    // Stop current recording — engine is invalid
                    self.engine?.inputNode.removeTap(onBus: 0)
                    self.engine?.stop()
                    self.isRecording = false
                    NSLog("[AudioRecording] Recording interrupted by device change")
                }
                // Force new engine on next start — but DON'T call warmUp()
                // here. Lazy-init happens in `start()`. Re-warming from inside
                // the observer callback can itself trigger another config-change
                // notification (inputNode lazy init probes the device again),
                // which re-enters the observer → loop.
                self.engine = nil
                self.converter = nil
                self.engineWarmed = false
            }
        }
    }

    /// Start recording from the default input device.
    func start() throws {
        guard !isRecording else { return }

        // Reuse existing engine or create new
        let engine = self.engine ?? AVAudioEngine()
        let inputNode = engine.inputNode
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate audio level for UI
            let level = self.calculateLevel(buffer: buffer)

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData, let channelData = outputBuffer.floatChannelData {
                let count = Int(outputBuffer.frameLength)
                let newSamples = Array(UnsafeBufferPointer(start: channelData[0], count: count))

                Task { @MainActor in
                    self.samples.append(contentsOf: newSamples)
                    self.audioLevel = level
                    self.updateBars(level: level)
                }
            }
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        self.engine = engine
        self.isRecording = true
    }

    /// Stop recording and return the collected PCM samples.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Keep engine alive for reuse — don't nil it
        converter = nil
        isRecording = false
        audioLevel = 0
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
    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

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
        return boosted
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
