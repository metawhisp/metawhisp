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
    /// RAW (un-boosted) RMS, max of both channels — silence guards read this
    /// (ITER-060 units fix), never the boosted `audioLevel`.
    @Published private(set) var rawRMSLevel: Float = 0
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

    /// ITER-026 v2 — fires when a manual recording crosses the 2h mark. The
    /// owner (AppDelegate) shows a non-blocking "still recording" card.
    /// Recording is NOT stopped — manual sessions keep going until the user
    /// presses STOP themselves.
    var onManualHeartbeat: (() -> Void)?

    /// True when the current recording was started by the user pressing
    /// RECORD (menu bar / hotkey) rather than by the auto-start gate.
    /// Manual recordings disable silence + max-duration guards (per user
    /// 2026-05-02: "Если запускаешь вручную, то останавливаешь тоже всегда
    /// только вручную").
    private(set) var isManualMode = false

    let mic: AudioRecordingService
    let systemAudio: SystemAudioCaptureService
    /// AUD-008 — bumped on every start()/stop(); the async start task bails after
    /// each suspension point if it no longer matches, so a STOP during startup can't
    /// resurrect a recording (start the mic / set isRecording) after the fact.
    private var startGeneration = 0

    private var cancellables = Set<AnyCancellable>()

    // Auto-stop state (ITER-012). Reset on every start/stop so a fresh recording
    // gets a clean slate.
    private var maxDurationTask: Task<Void, Never>?
    /// Wall-clock when audioLevel first dropped below the silence threshold and stayed
    /// there. nil while audio is loud or recording is off. We arm the silence stop
    /// once `silentSince + windowMinutes` is in the past.
    private var silentSince: Date?
    /// RAW-RMS threshold below which audio is considered "silence".
    ///
    /// ITER-060 units fix: this used to be compared against `audioLevel`, which
    /// is the sqrt-BOOSTED UI value (`sqrtf(rms*12)`) — boosted 0.025 equals
    /// raw 5.2e-5, i.e. digital zero, so the silence auto-stop and the
    /// calendar-end quiet probe never fired and recordings ran hours past the
    /// call. The guard now reads `rawRMSLevel` (physical RMS from both
    /// sources). Calibration in RAW terms: ambient noise floor (kbd, fan,
    /// AirPods breathing) ~0.001-0.005; quiet speech ~0.015+; normal speech
    /// 0.01-0.05 (see AudioRecordingService.calculateLevels). 0.012 sits
    /// between ambient and quiet speech.
    static let silenceRMSThreshold: Float = 0.012

    /// Pure guard predicate — pinned by tests so threshold semantics (RAW rms,
    /// not boosted UI level) can't regress silently.
    nonisolated static func isRawSilence(_ rawRMS: Float) -> Bool {
        rawRMS < silenceRMSThreshold
    }
    /// How often we re-check the silence timer (seconds). Cheap — just a Combine
    /// publisher, no I/O.
    private let silenceCheckInterval: TimeInterval = 1.0
    private var silenceCheckTimer: AnyCancellable?

    /// ITER-026 v2 — periods during which the user did a top-level dictation /
    /// voice question / translate. Mic is "paused" by recording the pause
    /// window timestamps; at `stop()` we zero out the matching slice of the
    /// raw mic samples before returning so the dictated text doesn't leak
    /// into the meeting transcript. System audio keeps recording during
    /// pause — meeting may still be going on the other side.
    private var pauseWindows: [(startSec: Double, endSec: Double)] = []
    private var pauseStartedAt: Date?

    /// ITER-026 v2 — manual-mode 2h heartbeat task.
    private var manualHeartbeatTask: Task<Void, Never>?

    init(mic: AudioRecordingService, systemAudio: SystemAudioCaptureService) {
        self.mic = mic
        self.systemAudio = systemAudio

        // Forward system audio error (most likely failure point — TCC, SCStream).
        // Forward nil TOO (ITER-050 B3.6): the old `if let err` swallowed the
        // reset, so a transient SCK failure pinned the red error banner in the
        // popover forever even after capture recovered.
        systemAudio.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                self?.lastError = err
            }
            .store(in: &cancellables)

        // Merge audio level: whichever source is louder drives the UI
        Publishers.CombineLatest(mic.$audioLevel, systemAudio.$audioLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] micLevel, sysLevel in
                self?.audioLevel = max(micLevel, sysLevel)
            }
            .store(in: &cancellables)

        // Merge RAW rms the same way — this is what the silence guards read
        // (ITER-060 units fix; `audioLevel` is the boosted UI value).
        Publishers.CombineLatest(mic.$rawRMSLevel, systemAudio.$rawRMSLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] micRaw, sysRaw in
                self?.rawRMSLevel = max(micRaw, sysRaw)
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

    /// Start a meeting recording. `manualMode = true` means the user pressed
    /// RECORD themselves; auto-stop guards (silence + max duration) are
    /// disabled and a 2h heartbeat is armed instead. `manualMode = false`
    /// (default) means the auto-start gate triggered the recording, full
    /// guards apply.
    func start(manualMode: Bool = false) {
        guard !isRecording, !isStarting else { return }
        lastError = nil
        micOnlyMode = false
        isStarting = true
        isManualMode = manualMode
        startGeneration += 1
        let gen = startGeneration  // AUD-008

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
                if self.startGeneration != gen { return }  // AUD-008: stopped during startup wait
            }

            guard self.systemAudio.isRecording else {
                self.lastError = self.systemAudio.lastError ?? "System audio failed to start"
                self.isStarting = false
                // Review fix — the recorder gave up, so cancel the in-flight
                // system-audio setup too (its retry path can outlast our 5s
                // budget; stop() bumps its generation → the stale setup tears
                // itself down instead of recording into the void).
                _ = self.systemAudio.stop()
                return
            }

            // AUD-008 — final checkpoint: if the user stopped while we waited for
            // system audio, do NOT start the mic or mark the recording active.
            guard self.startGeneration == gen else { return }

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

            // ITER-026 v2 — auto-stop guards apply ONLY to gate-triggered
            // recordings. Manual recordings run unbounded; the only auto-
            // signal is a 2h heartbeat that just shows a card, no stop.
            if self.isManualMode {
                NSLog("[MeetingRecorder] manual mode — silence + maxDuration guards disabled, 2h heartbeat armed")
                self.armManualHeartbeat()
            } else {
                self.armMaxDurationGuard()
                self.armSilenceGuard()
            }
        }
    }

    /// ITER-026 v2 — mark mic stream paused. User just triggered a dictation
    /// or voice question; their voice during that period should NOT land in
    /// the meeting transcript. We don't actually halt the AudioRecording-
    /// Service (sharing one input device makes hard pauses unsafe) — instead
    /// we record the pause start, and `stop()` zeroes out matching mic
    /// samples before returning.
    func pauseMic() {
        guard isRecording, pauseStartedAt == nil else { return }
        pauseStartedAt = Date()
        NSLog("[MeetingRecorder] mic paused (dictation in progress)")
    }

    /// ITER-026 v2 — pair to `pauseMic()`. Closes the pause window using
    /// elapsed seconds since `recordingStartedAt`.
    func resumeMic() {
        guard let pauseStart = pauseStartedAt, let recStart = recordingStartedAt else {
            pauseStartedAt = nil
            return
        }
        let startSec = pauseStart.timeIntervalSince(recStart)
        let endSec = Date().timeIntervalSince(recStart)
        if endSec > startSec {
            pauseWindows.append((startSec: startSec, endSec: endSec))
            NSLog("[MeetingRecorder] mic resumed; muting %.2fs..%.2fs in final stream", startSec, endSec)
        }
        pauseStartedAt = nil
    }

    /// Apply `pauseWindows` to a mic sample buffer — zero out matching time
    /// ranges so dictated audio doesn't reach Whisper.
    private func applyPauseMutes(to micSamples: [Float]) -> [Float] {
        guard !pauseWindows.isEmpty else { return micSamples }
        var muted = micSamples
        let sampleRate = 16000.0
        for window in pauseWindows {
            let startIdx = max(0, Int(window.startSec * sampleRate))
            let endIdx = min(muted.count, Int(window.endSec * sampleRate))
            guard endIdx > startIdx else { continue }
            for i in startIdx..<endIdx { muted[i] = 0 }
        }
        return muted
    }

    /// Stop both captures and return RAW per-channel samples.
    /// Mic and system are kept separate so the dual-stream transcription path
    /// can pseudo-diarize (mic = .me, system = .them) without ever summing the
    /// two streams. `Self.mix` is still available for callers that need a
    /// single-channel mixdown (e.g. `assembleMeetingTranscriptFromLive` tail).
    func stop() -> (mic: [Float], system: [Float]) {
        startGeneration += 1  // AUD-008: invalidate any in-flight start task

        // Disarm backstops first — otherwise a stale silence-timer fire after manual
        // stop could try to fire `onAutoStop` against an already-stopped recorder.
        disarmAutoStopGuards()

        // If a dictation pause was open at stop time, close it so its samples
        // get muted along with the rest. Avoids dictation bleed when user
        // ends the meeting mid-dictation.
        if pauseStartedAt != nil { resumeMic() }

        let rawMicSamples = mic.isRecording ? mic.stop() : []
        let micSamples = applyPauseMutes(to: rawMicSamples)
        let sysSamples = systemAudio.stop()

        isRecording = false
        isStarting = false
        audioLevel = 0
        rawRMSLevel = 0
        audioBars = Array(repeating: 0, count: 24)
        recordingStartedAt = nil
        let mutedWindowCount = pauseWindows.count
        pauseWindows.removeAll()

        NSLog("[MeetingRecorder] Stopped: mic=%d samples (%d pause windows muted), system=%d samples",
              micSamples.count, mutedWindowCount, sysSamples.count)

        return (mic: micSamples, system: sysSamples)
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

    /// Watches `rawRMSLevel`. Once it falls below `silenceRMSThreshold`
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
                let level = self.rawRMSLevel
                if Self.isRawSilence(level) {
                    if self.silentSince == nil {
                        self.silentSince = Date()
                    } else if let start = self.silentSince,
                              Date().timeIntervalSince(start) >= windowSeconds {
                        NSLog("[MeetingRecorder] 🤫 Silence (%.1fm < %.4f RMS) — auto-stop",
                              windowMinutes, Self.silenceRMSThreshold)
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
        manualHeartbeatTask?.cancel()
        manualHeartbeatTask = nil
    }

    // MARK: - Sliding-window quiet probe (ITER-034.1)

    /// Returns `true` iff `rawRMSLevel` has stayed below `silenceRMSThreshold`
    /// continuously for at least `seconds`. Returns `false` if audio
    /// rose above the threshold at any point during that window.
    ///
    /// Used by `AppDelegate.armCalendarEndStopTask` to decide whether a
    /// calendar-end auto-stop should fire. Reading `audioLevel` directly
    /// gave us a false-positive during the 200-500ms pauses between
    /// sentences (the 2026-05-11 user-reported bug «созвон закончился по
    /// календарю в середине обсуждения»). This wraps the silence-guard's
    /// existing `silentSince` so the two pieces of code can't disagree on
    /// "is the room actually quiet."
    ///
    /// Caller convention: pass 30s for the calendar-end probe. Shorter
    /// windows risk the same instantaneous-sample problem; longer windows
    /// burn the user's grace budget.
    func hasBeenContinuouslyQuiet(forAtLeast seconds: TimeInterval) -> Bool {
        guard let start = silentSince else { return false }
        return Date().timeIntervalSince(start) >= seconds
    }

    /// ITER-026 v2 — fires `onManualHeartbeat` once after 2h of recording.
    /// Owner shows a card "Recording 2h elapsed" without stopping. Manual
    /// recordings have no other auto-stop — only user STOP ends them.
    private func armManualHeartbeat() {
        manualHeartbeatTask?.cancel()
        manualHeartbeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2 * 3600))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            NSLog("[MeetingRecorder] ⏱ Manual recording 2h elapsed — heartbeat")
            self.onManualHeartbeat?()
        }
    }

    // MARK: - Audio Mixing

    /// Mix two 16kHz mono Float32 streams into one.
    /// Both sources started roughly at the same time (within a few hundred ms);
    /// we align them at sample 0 and mix sample-by-sample. Tail of the longer
    /// stream is kept as-is. Soft clipping prevents overflow when both are loud.
    /// TR-11 (ITER-046 E2): a TRUE soft clip. Identity for |x| ≤ 0.5 — normal
    /// speech sums pass through bit-exact — then smooth tanh compression with an
    /// asymptote at ±1. The previous `max(-1, min(1, sum))` was a HARD clip
    /// mislabelled "soft": it flat-topped loud overlaps (both speakers loud at
    /// once), adding harsh distortion exactly where ASR needs the waveform most.
    // nonisolated — pure sample math with no actor state; callers off the main
    // actor (Deepgram meeting transcriber, ITER-054) must not hop to Main just
    // to mix a multi-hour buffer.
    nonisolated static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.5 else { return x }
        return (x < 0 ? -1 : 1) * (0.5 + 0.5 * tanhf((a - 0.5) / 0.5))
    }

    nonisolated static func mix(mic: [Float], system: [Float]) -> [Float] {
        // If one side is empty, just return the other (no mixing needed)
        if mic.isEmpty { return system }
        if system.isEmpty { return mic }

        let common = min(mic.count, system.count)
        let total = max(mic.count, system.count)
        var mixed = [Float](repeating: 0, count: total)

        // Overlapping region — mix both
        for i in 0..<common {
            mixed[i] = softClip(mic[i] + system[i])
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
