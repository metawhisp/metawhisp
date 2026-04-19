import Combine
import Foundation

/// Coordinates simultaneous microphone + system audio capture for meeting recording.
/// Mixes both streams on stop so transcription includes the user's voice
/// AND other participants (who are played through speakers).
///
/// Why this exists: SCStream captures system audio only — that's what other people
/// say (through Zoom/Meet speakers). The user's own voice goes into their mic and
/// out to the network, never through the system audio output. Without capturing
/// the mic in parallel, the user's side of the conversation is lost.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var audioLevel: Float = 0
    @Published var audioBars: [Float] = Array(repeating: 0, count: 24)
    @Published var lastError: String?
    /// True if mic capture failed but system audio is still active (user will lose their own voice).
    @Published var micOnlyMode = false

    let mic: AudioRecordingService
    let systemAudio: SystemAudioCaptureService

    private var cancellables = Set<AnyCancellable>()

    init(mic: AudioRecordingService, systemAudio: SystemAudioCaptureService) {
        self.mic = mic
        self.systemAudio = systemAudio

        // Forward system audio error (most likely failure point — TCC, SCStream)
        systemAudio.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                if let err { self?.lastError = err }
            }
            .store(in: &cancellables)

        // Merge audio level: whichever source is louder drives the UI
        Publishers.CombineLatest(mic.$audioLevel, systemAudio.$audioLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] micLevel, sysLevel in
                self?.audioLevel = max(micLevel, sysLevel)
            }
            .store(in: &cancellables)

        // Merge bars: take the louder source's bars for the waveform viz
        Publishers.CombineLatest(mic.$audioBars, systemAudio.$audioBars)
            .receive(on: RunLoop.main)
            .sink { [weak self] micBars, sysBars in
                // Element-wise max so both sources influence the visualization
                let count = max(micBars.count, sysBars.count)
                var merged = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let m = i < micBars.count ? micBars[i] : 0
                    let s = i < sysBars.count ? sysBars[i] : 0
                    merged[i] = max(m, s)
                }
                self?.audioBars = merged
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isRecording, !isStarting else { return }
        lastError = nil
        micOnlyMode = false
        isStarting = true

        Task { [weak self] in
            guard let self else { return }

            // 1. Start system audio first — it's the path with TCC prompts.
            //    `start()` returns immediately; actual stream setup is async inside it.
            do {
                try self.systemAudio.start()
            } catch {
                self.lastError = "Meeting start failed: \(error.localizedDescription)"
                self.isStarting = false
                return
            }

            // 2. Wait for system audio to actually transition (up to 5s).
            //    SCStream setup takes ~100-500ms normally.
            for _ in 0..<50 {
                if self.systemAudio.isRecording { break }
                if let err = self.systemAudio.lastError {
                    self.lastError = err
                    self.isStarting = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard self.systemAudio.isRecording else {
                self.lastError = self.systemAudio.lastError ?? "System audio failed to start"
                self.isStarting = false
                return
            }

            // 3. Start microphone in parallel. If mic fails (permission denied, etc.)
            //    keep recording system audio only — the user still gets the other side.
            if self.mic.hasPermission {
                do {
                    try self.mic.start()
                } catch {
                    NSLog("[MeetingRecorder] ⚠️ Mic start failed, system-only: %@", error.localizedDescription)
                    self.micOnlyMode = true
                }
            } else {
                NSLog("[MeetingRecorder] ⚠️ No mic permission — system audio only")
                self.micOnlyMode = true
            }

            self.isRecording = true
            self.isStarting = false
            NSLog("[MeetingRecorder] ✅ Recording (mic=%@, system=yes)",
                  self.micOnlyMode ? "NO" : "yes")
        }
    }

    /// Stop both captures and return the MIXED audio samples.
    func stop() -> [Float] {
        let micSamples = mic.isRecording ? mic.stop() : []
        let sysSamples = systemAudio.stop()

        isRecording = false
        isStarting = false
        audioLevel = 0
        audioBars = Array(repeating: 0, count: 24)

        NSLog("[MeetingRecorder] Stopped: mic=%d samples, system=%d samples",
              micSamples.count, sysSamples.count)

        return Self.mix(mic: micSamples, system: sysSamples)
    }

    // MARK: - Audio Mixing

    /// Mix two 16kHz mono Float32 streams into one.
    /// Both sources started roughly at the same time (within a few hundred ms);
    /// we align them at sample 0 and mix sample-by-sample. Tail of the longer
    /// stream is kept as-is. Soft clipping prevents overflow when both are loud.
    static func mix(mic: [Float], system: [Float]) -> [Float] {
        // If one side is empty, just return the other (no mixing needed)
        if mic.isEmpty { return system }
        if system.isEmpty { return mic }

        let common = min(mic.count, system.count)
        let total = max(mic.count, system.count)
        var mixed = [Float](repeating: 0, count: total)

        // Overlapping region — mix both
        for i in 0..<common {
            let sum = mic[i] + system[i]
            // Soft clip to [-1, 1]
            mixed[i] = max(-1.0, min(1.0, sum))
        }

        // Tail from whichever is longer — keep at full gain
        if mic.count > common {
            for i in common..<mic.count { mixed[i] = mic[i] }
        } else if system.count > common {
            for i in common..<system.count { mixed[i] = system[i] }
        }

        return mixed
    }
}
