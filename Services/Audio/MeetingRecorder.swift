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
    /// Wall-clock time when the current recording actually began. The MeetingTimer
    /// reads this so the elapsed counter is correct regardless of how many times
    /// the user opens / closes the menu-bar popover (previously the timer used
    /// `Date()` captured on first view-appear and reset on every popover open).
    @Published var recordingStartedAt: Date?

    /// Reasons MeetingRecorder may auto-stop itself. Owner (AppDelegate) routes these
    /// to the same downstream pipeline as a manual stop, plus posts a user-facing
    /// notification so the user understands why the recording ended.
    /// spec://iterations/ITER-012-meeting-stop-guarantee
    enum AutoStopReason {
        case callEnded            // window-title transition signalled call ended
        case silenceTimeout       // audioLevel below threshold for N minutes
        case maxDurationReached   // total duration crossed user-configured cap
    }

    /// Owner installs this to receive auto-stop events. Closure runs on MainActor.
    var onAutoStop: ((AutoStopReason) -> Void)?

    let mic: AudioRecordingService
    let systemAudio: SystemAudioCaptureService

    private var cancellables = Set<AnyCancellable>()

    // Auto-stop state (ITER-012). Reset on every start/stop so a fresh recording
    // gets a clean slate.
    private var maxDurationTask: Task<Void, Never>?
    /// Wall-clock when audioLevel first dropped below the silence threshold and stayed
    /// there. nil while audio is loud or recording is off. We arm the silence stop
    /// once `silentSince + windowMinutes` is in the past.
    private var silentSince: Date?
    /// RMS threshold below which audio is considered "silence". 0.005 picks up
    /// background noise/breathing too — but the WINDOW (3 min default) makes false
    /// positives near-zero. Same threshold as the existing transcription guard.
    private let silenceRMSThreshold: Float = 0.005
    /// How often we re-check the silence timer (seconds). Cheap — just a Combine
    /// publisher, no I/O.
    private let silenceCheckInterval: TimeInterval = 1.0
    private var silenceCheckTimer: AnyCancellable?

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
            self.recordingStartedAt = Date()
            NSLog("[MeetingRecorder] ✅ Recording (mic=%@, system=yes)",
                  self.micOnlyMode ? "NO" : "yes")

            // Arm the two backstops that prevent zombie recordings (ITER-012).
            self.armMaxDurationGuard()
            self.armSilenceGuard()
        }
    }

    /// Stop both captures and return the MIXED audio samples.
    func stop() -> [Float] {
        // Disarm backstops first — otherwise a stale silence-timer fire after manual
        // stop could try to fire `onAutoStop` against an already-stopped recorder.
        disarmAutoStopGuards()

        let micSamples = mic.isRecording ? mic.stop() : []
        let sysSamples = systemAudio.stop()

        isRecording = false
        isStarting = false
        audioLevel = 0
        audioBars = Array(repeating: 0, count: 24)
        recordingStartedAt = nil

        NSLog("[MeetingRecorder] Stopped: mic=%d samples, system=%d samples",
              micSamples.count, sysSamples.count)

        return Self.mix(mic: micSamples, system: sysSamples)
    }

    // MARK: - Auto-stop guards (ITER-012)

    /// Hard cap on total recording duration. After `meetingMaxDurationMinutes`,
    /// fires `onAutoStop(.maxDurationReached)` so the owner can run the same
    /// stop+transcribe pipeline as a manual stop.
    private func armMaxDurationGuard() {
        maxDurationTask?.cancel()
        let cap = max(5, AppSettings.shared.meetingMaxDurationMinutes) // floor 5 min for sanity
        let seconds = cap * 60
        maxDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            NSLog("[MeetingRecorder] ⏱️ Max duration (%.0fm) reached — auto-stop", cap)
            self.onAutoStop?(.maxDurationReached)
        }
    }

    /// Watches `audioLevel` via Combine. Once it falls below `silenceRMSThreshold`
    /// for `meetingSilenceStopMinutes` consecutively, fires `onAutoStop(.silenceTimeout)`.
    /// Resets the silence window any time audio crosses back above threshold.
    private func armSilenceGuard() {
        silenceCheckTimer?.cancel()
        silentSince = nil
        let windowMinutes = max(0.5, AppSettings.shared.meetingSilenceStopMinutes)
        let windowSeconds = windowMinutes * 60
        // Use a periodic timer (cheap) over $audioLevel.debounce to keep
        // the check cadence independent of how often audioLevel publishes —
        // RMS bursts could otherwise prevent us from ever evaluating "silent for X".
        silenceCheckTimer = Timer.publish(every: silenceCheckInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                let level = self.audioLevel
                if level < self.silenceRMSThreshold {
                    if self.silentSince == nil {
                        self.silentSince = Date()
                    } else if let start = self.silentSince,
                              Date().timeIntervalSince(start) >= windowSeconds {
                        NSLog("[MeetingRecorder] 🤫 Silence (%.1fm < %.4f RMS) — auto-stop",
                              windowMinutes, self.silenceRMSThreshold)
                        self.onAutoStop?(.silenceTimeout)
                    }
                } else {
                    // Audio came back — reset the silence window.
                    if self.silentSince != nil {
                        self.silentSince = nil
                    }
                }
            }
    }

    private func disarmAutoStopGuards() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        silenceCheckTimer?.cancel()
        silenceCheckTimer = nil
        silentSince = nil
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
