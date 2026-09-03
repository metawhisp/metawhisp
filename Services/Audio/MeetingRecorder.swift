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
    @Published private(set) var rawRMSLevel: Float = 0 {
        // Peak since the post-start sniff began. The sniff used to read the
        // latest buffer once every five seconds and could miss every audible
        // moment in between; a latch cannot (review round twelve).
        didSet { sniffPeakRMS = max(sniffPeakRMS, rawRMSLevel) }
    }
    private(set) var sniffPeakRMS: Float = 0
    func markSniffStart() { sniffPeakRMS = 0 }
    @Published var audioBars: [Float] = Array(repeating: 0, count: 24)
    @Published var lastError: String?
    /// True if mic capture failed but system audio is still active (user will lose their own voice).
    @Published var micOnlyMode = false
    /// Set at `stop()`: the mic channel was bit-exact zero for the whole call.
    /// Published separately from `lastError` because this can be true even when
    /// the meeting transcribed FINE — the other side comes through the system
    /// channel, so a call with a dead mic saves a complete-looking Them:-only
    /// transcript and nothing else in the pipeline notices.
    @Published private(set) var micChannelWasSilent = false
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
    /// Which recording is running. A sniff task from an earlier recording
    /// must not judge — or stop — the one that replaced it.
    var recordingGeneration: Int { startGeneration }

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
    /// AirPods breathing) ~0.001-0.005; quiet/distant speech can dip to
    /// ~0.006-0.011; normal speech 0.01-0.05 (AudioRecordingService
    /// .calculateLevels). Codex review 2026-08-07: biased LOW (0.008, not
    /// 0.012) — cutting a live quiet-speaker meeting is worse than letting a
    /// zombie recording run to the calendar/max-duration stops. The gray band
    /// 0.005-0.008 counts as silence by design.
    static let silenceRMSThreshold: Float = 0.008

    /// Pure guard predicate — pinned by tests so threshold semantics (RAW rms,
    /// not boosted UI level) can't regress silently.
    nonisolated static func isRawSilence(_ rawRMS: Float) -> Bool {
        rawRMS < silenceRMSThreshold
    }

    /// ITER-060.5 — why a meeting finalized with an empty transcript. A
    /// mic-start failure is swallowed into `micOnlyMode` (see `start()`), so
    /// without this the finalize path blamed the USER's silence for the APP's
    /// own capture failure («No speech detected» after the founder spoke for
    /// minutes, 2026-08-10).
    enum EmptyTranscriptReason: Equatable {
        case chunksFailed(Int)
        case micNeverCaptured
        case micDeliveredSilence
        case genuinelySilent

        var userMessage: String {
            switch self {
            case let .chunksFailed(n):
                return "❌ Meeting couldn't be transcribed (\(n) segment(s) failed) — nothing saved"
            case .micNeverCaptured:
                return "🎤 Microphone captured nothing — check mic permission and the input device in Settings"
            case .micDeliveredSilence:
                // ⚠️, not 🎤: the menu bar routes 🎤 to the Privacy pane, and
                // this is a dead device, not a permission.
                return "⚠️ Mic input ran but produced no audio — " + AudioRecordingService.deadMicMessage
            case .genuinelySilent:
                return "🔇 No speech detected in recording"
            }
        }
    }

    /// Half a second of mic audio — below this the capture was broken, not quiet.
    private static let minMicSamplesForRealCapture = 8000

    /// A mic channel that is bit-exact zero from end to end.
    ///
    /// This is a DIFFERENT failure from `micNeverCaptured`, which counts
    /// samples: on 2026-08-12 the mic delivered 758 400 perfectly well-formed
    /// samples that were every one of them zero, so every count-based guard
    /// waved it through. Checked against the RAW buffer, before pause windows
    /// are muted, so dictation pauses can't fake the verdict.
    nonisolated static func isDigitalSilence(_ samples: [Float]) -> Bool {
        guard samples.count >= minMicSamplesForRealCapture else { return false }
        return !samples.contains { $0 != 0 }
    }

    /// `micPeakWasZero` defaults to `false` so existing callers keep their
    /// behaviour; pass the measured verdict to get the sharper diagnosis.
    nonisolated static func emptyTranscriptReason(
        failedChunks: Int, micSamples: Int, systemSamples: Int,
        micPeakWasZero: Bool = false
    ) -> EmptyTranscriptReason {
        if failedChunks > 0 { return .chunksFailed(failedChunks) }
        if micSamples < minMicSamplesForRealCapture { return .micNeverCaptured }
        if micPeakWasZero { return .micDeliveredSilence }
        return .genuinelySilent
    }
    /// How often we re-check the silence timer (seconds). Cheap — just a Combine
    /// publisher, no I/O.
    private let silenceCheckInterval: TimeInterval = 1.0
    private var silenceCheckTimer: AnyCancellable?

    // A meeting must never lose a channel silently — see `MicRecovery`.
    private var micWatchdogTimer: AnyCancellable?
    private var micOutage: MicOutageEpisode?
    private var micProducedAtLastTick = 0
    /// A loss the latches reported on a tick where the stream was not yet at
    /// a healthy rate: counted at the first healthy tick, or folded into the
    /// episode that opens meanwhile — never both.
    private var micCarriedLoss = false
    /// The "no input device" line is logged once per meeting, not on every
    /// probe of a meeting-long wait.
    private var micLoggedNoDevice = false
    private var micHealthyTicks = 0
    private var micLowRateTicks = 0
    private var micLastTickAt: SuspendingClock.Instant?
    private var micLateTicks = 0
    /// When the rate window opened — the last tick that JUDGED. A skipped
    /// late tick does not close it, so the count and the window agree.
    private var micRateWindowStart: SuspendingClock.Instant?
    private var micOutageCount = 0
    private var micOutageSeconds: Double = 0
    /// The mic has been down at some point this meeting, or is down now. The
    /// post-start silence sniff must not discard such a recording: RMS says
    /// nothing about a microphone that was, or is, being recovered.
    var micHadOutage: Bool { micOutageCount > 0 || micOutage != nil }
    var micHasPermission: Bool { mic.hasPermission }
    /// The mic delivered at least one sample this recording. A mic that never
    /// existed (no device, no permission) is not an outage that excuses an
    /// all-silent auto-recording from the sniff's discard.
    var micProducedThisRecording: Bool { mic.producedByTapThisRecording > 0 }
    /// The stream is down, stalled or dead RIGHT NOW, whatever the last tick
    /// saw. The post-start silence sniff asks this so a device change after
    /// the last tick cannot make it discard a recording whose mic just died.
    var micIsDownNow: Bool {
        let s = mic.streamState
        return s == .down || s == .stalled || s == .dead
    }

    /// The meeting's start on the monotonic clock: the retry schedule and
    /// every recency test run on it, never on the wall clock.
    private var micClockStart: SuspendingClock.Instant?
    /// The outage note for this meeting's finalization. Later finalization
    /// errors join it rather than replace it — an outage plus one failed
    /// transcription chunk used to leave only the chunk warning.
    private var finalizationNote: String?

    /// What `stop()` hands back — a snapshot, so a meeting whose transcription
    /// is still in flight when the next one stops is diagnosed with its OWN
    /// numbers, not the next meeting's (review, 2026-09-03).
    struct Capture {
        let mic: [Float]
        let system: [Float]
        /// Samples the tap produced across the whole meeting, before pause
        /// mutes: an empty capture must not look like a quiet one.
        let tapSamples: Int
        let micChannelWasSilent: Bool
        /// How many times the mic went down, and for how long in total. The
        /// user's side is missing for that long; finalization says so.
        let outages: Int
        let outageSeconds: Double
        /// The mic was still down when the meeting ended — the card must not
        /// say it was brought back.
        let micDownAtStop: Bool
        /// Why the mic could not be brought back, if the app can tell: a
        /// denied (or revoked) permission gets the permission note; a Mac
        /// with no input device gets a log line, not a card after every
        /// meeting.
        enum Unavailable { case noPermission, noInputDevice }
        let micUnavailable: Unavailable?
        /// The longest stretch, in seconds, that an external input delivered
        /// exact zeros after it had delivered audio. Not an outage; reported
        /// when long enough (`MicOutageReport.silentRunFloorSeconds`).
        let micZeroRunSeconds: Double
        /// The tap carried audio (not zeros) within the last seconds before
        /// stop — the permission wording depends on it.
        let micAudioAtStop: Bool
        /// Which meeting this was. A finalization that finishes after the next
        /// meeting started must not write its outcome over the live one.
        let generation: Int
    }

    /// Record a finalization outcome for the meeting it belongs to. Ignored
    /// when a newer meeting has started since (review, 2026-09-03).
    /// The generation of the last recording that actually went live. A start
    /// that failed before going live (no system audio) must not swallow the
    /// previous meeting's outcome (independent review, v14).
    private var liveGeneration = 0

    func reportFinalization(error: String?, for generation: Int) {
        guard generation == liveGeneration || (!isRecording && !isStarting) else {
            NSLog("[MeetingRecorder] finalization for an earlier meeting — outcome not shown over the live one")
            return
        }
        lastError = [finalizationNote, error].compactMap { $0 }.joined(separator: "\n")
        if lastError?.isEmpty == true { lastError = nil }
    }

    /// A new meeting starts with a clean banner: the previous meeting's note
    /// and error go together, SYNCHRONOUSLY. The note used to be cleared only
    /// once the start had gone live, after asynchronous waits — and the
    /// relay, composing every reset with the note, put the previous meeting's
    /// "your side is missing" back into the popover for the whole next
    /// meeting (independent review, v18). A start that then fails shows its
    /// own error; the outcome of the earlier meeting is protected by
    /// `liveGeneration`, not by the note.
    func forgetOutcome() {
        finalizationNote = nil
        lastError = nil
    }

    /// A fact about the capture that every later finalization message must
    /// keep — the microphone-loss note.
    func keepFinalizationNote(_ note: String, for generation: Int) {
        guard generation == liveGeneration || (!isRecording && !isStarting) else { return }
        finalizationNote = note
        lastError = note
    }

    /// ITER-026 v2 — periods during which the user did a top-level dictation /
    /// voice question / translate. Mic is "paused" by recording the pause
    /// window timestamps; at `stop()` we zero out the matching slice of the
    /// raw mic samples before returning so the dictated text doesn't leak
    /// into the meeting transcript. System audio keeps recording during
    /// pause — meeting may still be going on the other side.
    private var pauseWindows: [(startSec: Double, endSec: Double)] = []
    /// On the suspending clock, like the mic timeline it is applied to: a
    /// wall-clock window around a sleep used to mute every sample after
    /// wake (review round eight).
    private var pauseStartedAt: SuspendingClock.Instant?

    /// ITER-026 v2 — manual-mode 2h heartbeat task.
    private var manualHeartbeatTask: Task<Void, Never>?

    init(mic: AudioRecordingService, systemAudio: SystemAudioCaptureService) {
        self.mic = mic
        self.systemAudio = systemAudio

        // Forward system audio error (most likely failure point — TCC, SCStream).
        // Forward nil TOO (ITER-050 B3.6): the old `if let err` swallowed the
        // reset, so a transient SCK failure pinned the red error banner in the
        // popover forever even after capture recovered.
        // Composed with the sticky finalization note, exactly as
        // `reportFinalization` does: the user-toggle stop resets this error
        // BEFORE stopping, and that reset landed here asynchronously — after
        // `keepFinalizationNote` — erasing the mic-loss banner (independent
        // review, v17).
        systemAudio.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                guard let self else { return }
                let joined = [self.finalizationNote, err].compactMap { $0 }.joined(separator: "\n")
                self.lastError = joined.isEmpty ? nil : joined
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
        forgetOutcome()
        micOnlyMode = false
        isStarting = true
        isManualMode = manualMode
        startGeneration += 1
        let gen = startGeneration  // AUD-008

        Task { [weak self] in
            guard let self else { return }
            // A stop that landed between `start()` and this Task must not
            // bring up system audio for a meeting nobody is having — and it
            // makes the synchronous half of `start()` testable (independent
            // review, v20).
            guard self.startGeneration == gen else { return }

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
            //    keep recording system audio only — the user still gets the other
            //    side — and recovery keeps trying to bring the mic in. The
            //    timeline begins now either way, so a mic recovered later lands
            //    at the right place against the system channel.
            self.mic.beginTimeline()
            self.micClockStart = SuspendingClock.now
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
            self.liveGeneration = gen
            self.recordingStartedAt = Date()
            NSLog("[MeetingRecorder] ✅ Recording (mic=%@, system=yes)",
                  self.micOnlyMode ? "NO" : "yes")
            self.armMicRecovery()

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
        pauseStartedAt = SuspendingClock.now
        NSLog("[MeetingRecorder] mic paused (dictation in progress)")
    }

    /// ITER-026 v2 — pair to `pauseMic()`. Closes the pause window using
    /// elapsed seconds since `recordingStartedAt`.
    func resumeMic() {
        guard let pauseStart = pauseStartedAt, let clockStart = micClockStart else {
            pauseStartedAt = nil
            return
        }
        let startSec = (pauseStart - clockStart).seconds
        let endSec = (SuspendingClock.now - clockStart).seconds
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
    func stop() -> Capture {
        startGeneration += 1  // AUD-008: invalidate any in-flight start task

        // Disarm backstops first — otherwise a stale silence-timer fire after manual
        // stop could try to fire `onAutoStop` against an already-stopped recorder.
        disarmAutoStopGuards()

        // If a dictation pause was open at stop time, close it so its samples
        // get muted along with the rest. Avoids dictation bleed when user
        // ends the meeting mid-dictation.
        if pauseStartedAt != nil { resumeMic() }

        // Drain the mic UNCONDITIONALLY: during an outage the engine is down
        // but everything captured before it is still in the buffer, and the
        // old `isRecording ? stop() : []` threw the whole first part of the
        // call away if the user stopped mid-recovery (review, 2026-09-03).
        // Judge the LIVE stream at stop, not the cached episode: a drop after
        // the last tick would otherwise go unreported, and a rebound already
        // producing but not yet confirmed would be reported as still down.
        let liveState = mic.streamState
        // The buffer follows the clock to the end: the last buffers may have
        // stopped a few seconds ago without any tick having judged it.
        // Account BEFORE the tail fill: the tail is the host clock's view of
        // the end, and against device-clock placement it carries drift and
        // latency — a healthy mic must not be called "down at stop" by it
        // (independent review, v14). The tail is filled for the timeline
        // only; the stream's own state decides whether the mic was down.
        let accounting = mic.takeAccounting()
        if mic.producedByTapThisRecording > 0 { mic.fillSilence() }
        _ = mic.takeAccounting()   // the tail's own seconds are not an outage
        micOutageSeconds += accounting.silencePlacedSeconds + accounting.deadZeroSeconds
        let latchedLoss = accounting.silencePlacedSeconds >= 1 || accounting.deadTripped || micCarriedLoss
        micCarriedLoss = false
        // A tail of a second or more (past the jitter allowance) is missing
        // microphone time and is counted as an outage; a permission gone or
        // an engine down at stop is one too, whatever the ticks saw. Counted
        // ONCE: the synthetic episode covers the latched loss when it opens;
        // otherwise the latches — a gap that ended, or a run of zeros, in the
        // second before Stop — are counted on their own (rounds ten, eleven).
        if micOutage == nil, let clockStart = micClockStart {
            let now = (SuspendingClock.now - clockStart).seconds
            if !mic.hasPermission {
                openMicOutage(since: mic.lastProducedAt ?? clockStart, now: now,
                              reason: "microphone permission revoked, seen at stop")
            } else if liveState == .down || liveState == .stalled || liveState == .dead {
                openMicOutage(since: micOutageStart(for: liveState, clockStart: clockStart),
                              now: now, reason: "down at stop")
            } else if latchedLoss {
                micOutageCount += 1
                NSLog("[MeetingRecorder] 🎙️ mic time went missing just before stop — %.1fs placed as silence, dead run: %@",
                      accounting.silencePlacedSeconds, accounting.deadTripped ? "yes" : "no")
            }
        }
        // "Back" means the rate went healthy, not that something arrived
        // recently: a dead device's zeros, one drip, and a just-torn-down
        // engine all produced half a second ago and none is back. Judged
        // AFTER any outage opened above, so the card cannot say "brought
        // back" about a mic the stop itself found down.
        let backNow = mic.hasPermission && liveState == .delivering && micHealthyTicks >= 1
        let micDownAtStop = micOutage != nil && !backNow
        micOutage = nil
        // Everything the tap produced across every bind of this meeting —
        // the digital-silence judgement and the "captured nothing" diagnosis
        // must not see the timeline's silence as audio.
        let tapSamples = mic.producedByTapThisRecording
        // A permission gone at stop is reported as such whether the mic ever
        // produced or not — revoked at minute ten, the card must still say
        // "permission" so the menu bar routes its click to the Privacy pane
        // (independent review, v16). No input device at all is known only
        // for a mic that never produced.
        var micUnavailable: Capture.Unavailable? = nil
        if !mic.hasPermission { micUnavailable = .noPermission }
        else if tapSamples == 0, AudioInputCatalog.availableInputDevices().isEmpty { micUnavailable = .noInputDevice }
        let micZeroRunSeconds = mic.longestZeroRunSecondsAfterAudio
        // Audio (not zeros) within the last seconds: a permission the system
        // reports as off while the stream still carries audio must not be
        // told as "your side is missing" (independent review, v17).
        let micAudioAtStop = mic.lastAudioAt.map { (SuspendingClock.now - $0).seconds < 5 } ?? false
        let rawMicSamples = mic.stop()
        // Judge the mic on the RAW buffer — `applyPauseMutes` writes literal
        // zeros by design, so measuring after it would confuse "the user
        // dictated" with "the microphone was dead".
        micChannelWasSilent = tapSamples > 0 && Self.isDigitalSilence(rawMicSamples)
        let outages = micOutageCount
        let outageSeconds = micOutageSeconds
        micOutageCount = 0
        micOutageSeconds = 0
        if outages > 0 {
            NSLog("[MeetingRecorder] %d mic outage(s), %.1fs in total — silence on the timeline, the user's side is missing there",
                  outages, outageSeconds)
        }
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

        NSLog("[MeetingRecorder] Stopped: mic=%d samples (%d produced by the tap, %d pause windows muted), system=%d samples",
              micSamples.count, tapSamples, mutedWindowCount, sysSamples.count)

        return Capture(mic: micSamples, system: sysSamples, tapSamples: tapSamples,
                       micChannelWasSilent: micChannelWasSilent, outages: outages,
                       outageSeconds: outageSeconds, micDownAtStop: micDownAtStop,
                       micUnavailable: micUnavailable, micZeroRunSeconds: micZeroRunSeconds,
                       micAudioAtStop: micAudioAtStop, generation: liveGeneration)
    }

    // MARK: - Mic recovery

    /// One signal, one episode, and a buffer that keeps its own timeline.
    ///
    /// The once-a-second tick reads the engine's account of its stream —
    /// `streamState` and the rate since the last tick — never a raw count
    /// that zeros or a retired bind could grow. An outage opens when the
    /// stream is down, dead, stalled, or unpermitted. While it is open the
    /// tick fills the mic buffer with silence up to the clock, so the buffer
    /// stays on the meeting's timeline by construction and nothing is
    /// inserted at stop; whatever a dead attempt appended already occupies
    /// exactly its own time. The outage keeps its attempt count until the
    /// rebound stream has held a healthy rate for
    /// `MicRecoveryPolicy.confirmTicks` ticks — one buffer and a hang is not
    /// delivery — and only that clears the banner.
    ///
    /// The one thing this cannot fix is a revoked microphone permission. The
    /// outage opens all the same so the banner says so; nothing is attempted.
    private func armMicRecovery() {
        micOutage = nil
        micCarriedLoss = false
        micLoggedNoDevice = false
        micProducedAtLastTick = 0
        micHealthyTicks = 0
        micLowRateTicks = 0
        micOutageCount = 0
        micOutageSeconds = 0
        micLastTickAt = nil
        micLateTicks = 0
        // Anchored here, not left to the first tick's fallback: a meeting
        // starts with the main thread busy (screen capture, TCC, the
        // popover), so the first tick can be seconds late — and against a
        // one-second bar a drip would read as healthy (independent review,
        // v21).
        micRateWindowStart = SuspendingClock.now
        micWatchdogTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.micRecoveryTick() }
    }

    private func micRecoveryTick() {
        guard isRecording, let clockStart = micClockStart else { return }
        // A tick the main thread held back judges nothing (see
        // `MicRecoveryPolicy.lateTickSeconds`); the third in a row does.
        let tickAt = SuspendingClock.now
        let sinceLastTick = micLastTickAt.map { (tickAt - $0).seconds }
        micLastTickAt = tickAt
        let late = sinceLastTick.map { $0 > MicRecoveryPolicy.lateTickSeconds } ?? false
        if MicRecoveryPolicy.skipsJudgement(sinceLastTick: sinceLastTick, consecutiveLate: micLateTicks) {
            micLateTicks += 1
            NSLog("[MeetingRecorder] mic tick %.1fs late — the main thread was held; judging nothing this tick",
                  sinceLastTick ?? 0)
            return
        }
        micLateTicks = late ? micLateTicks + 1 : 0
        let now = (tickAt - clockStart).seconds
        let sampleRate = 16000.0

        // What the tap did since the last tick: silence it placed into the
        // timeline (exact seconds of missing microphone), and whether the
        // content detector tripped — both latched, so nothing between two
        // polls is lost.
        let accounting = mic.takeAccounting()
        micOutageSeconds += accounting.silencePlacedSeconds + accounting.deadZeroSeconds
        // Whether the latches describe a loss the tick never saw as an
        // outage — a drip, a run of zeros that began and ended between polls,
        // a bind that blocked — or one carried over from a tick where the
        // stream was not yet healthy. Counted below, ONCE: either the episode
        // this tick opens covers it, or it is counted on its own at a
        // healthy tick, or it is carried again.
        let latchedLoss = accounting.silencePlacedSeconds >= 1 || accounting.deadTripped || micCarriedLoss
        micCarriedLoss = false

        // The rate this tick, and how long it has been healthy or poor. Reset
        // when the bind changes (a rebind starts its own streak).
        let produced = mic.producedByTap
        let sinceLast = max(0, produced - micProducedAtLastTick)
        // The window this count covers: since the last tick that judged, so a
        // skipped late tick cannot inflate the rate.
        let rateWindow = micRateWindowStart.map { (tickAt - $0).seconds } ?? 1
        if MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: sinceLast, seconds: rateWindow,
                                           sampleRate: sampleRate) {
            micHealthyTicks += 1; micLowRateTicks = 0
        } else {
            micHealthyTicks = 0
            if mic.streamState == .delivering { micLowRateTicks += 1 } else { micLowRateTicks = 0 }
        }
        micProducedAtLastTick = produced
        micRateWindowStart = tickAt

        // A trip whose run already ended is a loss to count, not a stream to
        // restart: forcing a healthy stream into `.dead` opened an episode
        // that then restarted a working mic and cut a second gap (round 11).
        // Only a stream that is dead NOW is judged dead.
        let state = mic.streamState
        let input = MicTickInput(hasPermission: mic.hasPermission,
                                 state: state,
                                 producedSinceLastTick: sinceLast,
                                 healthyTicks: micHealthyTicks,
                                 lowRateTicks: micLowRateTicks,
                                 secondsSinceLastTick: rateWindow,
                                 elapsed: now,
                                 outageOpen: micOutage != nil,
                                 attemptDue: micOutage?.shouldAttempt(at: now) ?? false)
        let decision = MicRecoveryPolicy.decide(input, sampleRate: sampleRate)

        if let reason = decision.open {
            openMicOutage(since: micOutageStart(for: state, clockStart: clockStart), now: now, reason: reason)
        } else if latchedLoss, micOutage == nil, micHealthyTicks >= 1 {
            // Counted on its own only when the stream is back at a healthy
            // rate THIS tick. A gap followed by a drip is not back: if the
            // drip goes on, "stream degraded" opens and counts it then; if
            // it recovers, the next healthy tick counts it here (round 12:
            // counting it now and again at degraded made one outage two).
            micOutageCount += 1
            NSLog("[MeetingRecorder] 🎙️ mic time went missing between ticks (%.1fs placed as silence, dead run: %@) — the stream is back on its own",
                  accounting.silencePlacedSeconds, accounting.deadTripped ? "yes" : "no")
        } else if latchedLoss, micOutage == nil {
            // Loss seen, stream not yet healthy: carry it to the next tick.
            micCarriedLoss = true
        }
        if decision.fill, mic.producedByTapThisRecording > 0 {
            // Nothing is arriving: keep the buffer following the clock so the
            // gap is placed as it grows rather than in one piece later. A
            // buffer that does arrive places its own gap before itself. A mic
            // that has never produced this recording (no device, no
            // permission) keeps an EMPTY buffer, as before — hours of zeros
            // for a channel that never existed would cost hundreds of MB and
            // align nothing.
            mic.fillSilence()
        }
        if decision.close {
            closeMicOutage()
            return
        }
        if decision.attempt, var outage = micOutage {
            mic.preferBuiltInInput = outage.preferBuiltIn
            var boundBuiltIn = false
            // A Mac with no input device at all: probing the device list is a
            // property read; building an engine to learn the same thing is
            // churn. The probe counts as a built-in attempt so the schedule
            // slows to its 30 s cadence — and that cadence is the release:
            // when a microphone appears, the next probe binds it.
            if AudioInputCatalog.availableInputDevices().isEmpty {
                boundBuiltIn = true
                if !micLoggedNoDevice {
                    micLoggedNoDevice = true
                    NSLog("[MeetingRecorder] mic recovery: no input device on this Mac — probing every %.0f s",
                          MicRecoverySchedule.maxDelayOnBuiltInSeconds)
                }
            } else {
                do {
                    try mic.restart()
                    // A Mac with no built-in microphone (mini, Studio, Pro)
                    // that was asked for it has nothing else to try either:
                    // the schedule slows as if the built-in bind had failed
                    // (independent review, v17).
                    let builtInAskedForButAbsent = outage.preferBuiltIn && AudioInputCatalog.builtInMicrophone() == nil
                    boundBuiltIn = mic.boundInputIsBuiltIn || builtInAskedForButAbsent
                    NSLog("[MeetingRecorder] mic recovery attempt %d bound (%@)",
                          outage.attempts + 1,
                          mic.boundInputIsBuiltIn ? "built-in" : builtInAskedForButAbsent ? "default input; no built-in exists" : "default input")
                } catch {
                    // A throw — the device vanished between the probe and the
                    // bind, a format the pipeline cannot take — slows the
                    // schedule like a failed built-in bind: there is nothing
                    // else to try.
                    boundBuiltIn = true
                    NSLog("[MeetingRecorder] mic recovery attempt %d failed: %@",
                          outage.attempts + 1, error.localizedDescription)
                }
            }
            outage.noteAttempt(at: (SuspendingClock.now - clockStart).seconds, boundBuiltIn: boundBuiltIn)
            micOutage = outage
            // A new bind starts its own streaks.
            micProducedAtLastTick = mic.producedByTap
            micHealthyTicks = 0
            micLowRateTicks = 0
            return
        }
    }

    /// When the outage began, for the accounting: the last production where
    /// there was one; for a bind that never carried audio (`.dead`) its first
    /// buffer — every zero since then was lost time, not the latest one; for
    /// a mic that never started, the meeting's start.
    private func micOutageStart(for state: MicStreamState,
                                clockStart: SuspendingClock.Instant) -> SuspendingClock.Instant {
        switch state {
        case .binding: return clockStart
        case .dead:    return mic.lastAudioAt ?? mic.firstBufferAt ?? mic.lastProducedAt ?? SuspendingClock.now
        default:       return mic.lastProducedAt ?? clockStart
        }
    }

    private func openMicOutage(since: SuspendingClock.Instant, now: Double, reason: String) {
        guard micOutage == nil else { return }
        micOutage = MicOutageEpisode(since: since, now: now)
        micOnlyMode = true   // the banner tells the truth while the mic is down
        micOutageCount += 1
        micHealthyTicks = 0
        micLowRateTicks = 0
        NSLog("[MeetingRecorder] 🎙️ mic down (%@) — recovering", reason)
    }

    private func closeMicOutage() {
        guard let outage = micOutage else { return }
        micOutage = nil
        micOnlyMode = false
        // Seconds are not added here: the silence the tap placed into the
        // timeline is the outage's exact length, and it was counted as it was
        // placed. The episode is the count and the banner.
        micLowRateTicks = 0
        mic.preferBuiltInInput = false
        NSLog("[MeetingRecorder] ✅ mic back after %.1fs and %d attempt(s) — the gap is silence on the timeline",
              (SuspendingClock.now - outage.since).seconds, outage.attempts)
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
        micWatchdogTimer?.cancel()
        micWatchdogTimer = nil
        // A recovery cut short must not leave the NEXT recording bound to the
        // built-in mic instead of the device the user chose.
        mic.preferBuiltInInput = false
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
