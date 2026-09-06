import Combine
import Foundation

/// Realtime advice during an active meeting recording (ITER-019).
///
/// Problem before this iteration: `MeetingRecorder` collects audio in a single
/// buffer and only transcribes on `stop()`. So `AdviceService.triggerOnTranscription`
/// — which already exists for push-to-talk dictations — never fires WHILE a
/// meeting is in progress. The user is talking for an hour and gets advice only
/// after hanging up.
///
/// Approach: every `chunkSeconds` (default 30) we ask the underlying `mic` and
/// `systemAudio` services for the samples accumulated since our last read
/// (`peekSamples(from:)`), mix them, run the same transcription engine the
/// final pass uses (cloud preferred via `TranscriptionCoordinator.activeEngine`),
/// and feed the partial text into `AdviceService.triggerOnTranscription` with
/// `source: "meeting-live"`. The Advice service already has its own per-source
/// cooldown, so actual advice fires stay rare even at 30s polling.
///
/// Lifecycle: armed when `meetingRecorder.isRecording` becomes true, disarmed
/// when it becomes false. Internal sample offset resets on disarm so a new
/// meeting starts from sample 0.
///
/// Cost: 1 transcription call per chunk. With 30s chunks a 60-min meeting =
/// 120 partial transcribes. On Pro (cloud) that's ~$0.05 per hour-long meeting.
/// Settings toggle (`liveMeetingAdviceEnabled`) lets the user opt out.
///
/// spec://iterations/ITER-019-realtime-meeting-advice
@MainActor
final class LiveMeetingAdvisor: ObservableObject {
    // LiveMeetingAdvisor does not call the Pro proxy directly — partial
    // transcriptions flow into MeetingCoachService.shared.process(...)
    // which owns the LLM call + tier declaration. Phase D will add a
    // pre-tick mini gate here to skip uneventful windows.
    @Published private(set) var isActive = false
    /// Last partial text we transcribed — useful for diagnostics + UI status pill.
    @Published private(set) var lastPartial: String = ""
    @Published private(set) var lastFireAt: Date?

    /// All non-empty, non-hallucinated partials collected during the meeting,
    /// in arrival (= sample) order. Reset on `arm()` for a fresh meeting,
    /// kept across `disarm()` so `finalize()` can return them after the
    /// recorder's `isRecording = false` Combine signal.
    /// Used by `AppDelegate.stopMeetingRecording` to skip a 2nd transcription
    /// pass over the same audio (saves 50% of cloud transcribe minutes).
    private var collectedPartials: [String] = []

    private weak var meetingRecorder: MeetingRecorder?
    private weak var coordinator: TranscriptionCoordinator?
    private weak var adviceService: AdviceService?
    private let settings = AppSettings.shared

    /// Polling cadence. 30s balances LLM cost vs latency. Hard floor 10s, max 120s.
    var chunkSeconds: TimeInterval = 30
    /// Min samples in chunk to bother transcribing — filters mic-startup silence.
    private let minChunkSamples = 16000  // ≥ 1s at 16kHz

    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?
    private var micOffset = 0
    private var sysOffset = 0

    func configure(meetingRecorder: MeetingRecorder,
                    coordinator: TranscriptionCoordinator,
                    adviceService: AdviceService) {
        self.meetingRecorder = meetingRecorder
        self.coordinator = coordinator
        self.adviceService = adviceService

        // Auto-arm/disarm based on the recorder's @Published isRecording.
        meetingRecorder.$isRecording
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] recording in
                if recording { self?.arm() } else { self?.disarm() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    private func arm() {
        guard settings.liveMeetingAdviceEnabled else {
            NSLog("[LiveAdvise] disabled in settings — skip arm")
            return
        }
        guard !isActive else { return }
        isActive = true
        // Reset offsets — fresh meeting reads from sample 0.
        micOffset = 0
        sysOffset = 0
        lastPartial = ""
        // Reset accumulator — previous meeting's partials must not leak into this one.
        collectedPartials = []
        // Show the meeting copilot overlay & reset its rolling LLM window.
        MeetingCoachState.shared.arm()
        MeetingCoachService.shared.reset()
        let interval = max(10, min(120, chunkSeconds))
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            // First chunk after `interval`, not immediately — gives the meeting
            // time to accumulate something worth transcribing.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.isActive else { return }
                await self.processChunk()
            }
        }
        NSLog("[LiveAdvise] ✅ armed (chunk=%.0fs)", interval)
    }

    private func disarm() {
        // ALWAYS hide the overlay — even if `isActive` is already false because
        // `finalize()` (called from `AppDelegate.stopMeetingRecording`) flipped
        // it before this Combine-driven sink fired. Without the unconditional
        // call here, the overlay was getting stuck visible after a stop and
        // the next user click on the overlay's STOP button would `toggle` to
        // a NEW recording instead of dismissing the stale overlay.
        MeetingCoachState.shared.disarm()
        guard isActive else { return }
        isActive = false
        timerTask?.cancel()
        timerTask = nil
        // Note: do NOT reset `micOffset`/`sysOffset`/`collectedPartials` here.
        // `AppDelegate.stopMeetingRecording` may call `finalize()` AFTER this
        // (Combine sink races with the explicit close path), and it needs the
        // accumulated state. Offsets/partials reset on next `arm()`.
        NSLog("[LiveAdvise] ⏹ disarmed")
    }

    // MARK: - Finalization (consumed by AppDelegate.stopMeetingRecording)

    /// Snapshot of the advisor's state at meeting close. Caller uses
    /// `micOffsetAtFinalize` / `sysOffsetAtFinalize` to peek the tail audio
    /// (between the last successful tick and the moment the user clicked
    /// stop) BEFORE calling `meetingRecorder.stop()` — at which point the
    /// recorder buffers are wiped.
    struct FinalizationResult {
        let text: String
        let partialCount: Int
        let micOffsetAtFinalize: Int
        let sysOffsetAtFinalize: Int
    }

    /// Stop ticking and return accumulated partials. Caller is responsible
    /// for transcribing the residual tail audio (≤ chunkSeconds worth) using
    /// the offsets returned here.
    ///
    /// Returns nil if the advisor wasn't running (e.g. `liveMeetingAdviceEnabled`
    /// disabled, never armed) or collected zero partials — in that case the
    /// caller MUST fall back to a full re-transcribe of the raw samples.
    func finalize() -> FinalizationResult? {
        timerTask?.cancel()
        timerTask = nil
        let wasActive = isActive
        isActive = false
        // Hide the overlay immediately on the explicit close path. The
        // Combine-driven `disarm()` will run too (idempotently) when the
        // recorder publishes `isRecording = false`, but doing it here means
        // the overlay disappears the moment we begin teardown, not later.
        MeetingCoachState.shared.disarm()

        guard wasActive, !collectedPartials.isEmpty else {
            NSLog("[LiveAdvise] finalize → nil (active=%@, partials=%d)",
                  wasActive ? "true" : "false", collectedPartials.count)
            return nil
        }

        let text = collectedPartials.joined(separator: "\n\n")
        NSLog("[LiveAdvise] finalize → %d partials, %d chars, micOff=%d sysOff=%d",
              collectedPartials.count, text.count, micOffset, sysOffset)
        return FinalizationResult(
            text: text,
            partialCount: collectedPartials.count,
            micOffsetAtFinalize: micOffset,
            sysOffsetAtFinalize: sysOffset
        )
    }

    // MARK: - Chunk processing

    private func processChunk() async {
        guard let mr = meetingRecorder, mr.isRecording else { return }
        guard let engine = coordinator?.activeEngine, engine.isModelLoaded else {
            NSLog("[LiveAdvise] no active engine — skip chunk")
            return
        }

        // Snapshot current sample offsets to bound this chunk.
        let micCurrent = mr.mic.currentSampleCount
        let sysCurrent = mr.systemAudio.currentSampleCount
        let micChunk = mr.mic.peekSamples(from: micOffset)
        let sysChunk = mr.systemAudio.peekSamples(from: sysOffset)
        // Advance offsets ONLY after a successful read so a transcription failure
        // can be retried on the next chunk (LLM/cloud blip → don't lose audio).
        let mixed = MeetingRecorder.mix(mic: micChunk, system: sysChunk)
        guard mixed.count >= minChunkSamples else {
            // Too quiet / too short — don't waste an LLM call. Don't advance
            // either, accumulate into next chunk.
            return
        }

        // RMS guard — silence/noise blocks below ~0.0005 are dropped (matches
        // the same-named filter in AppDelegate's full-meeting transcribe path).
        let rms = TranscriptionCoordinator.calculateRMS(mixed)
        NSLog("[LiveAdvise] chunk — %d samples (%.1fs), rms=%.4f", mixed.count, Double(mixed.count) / 16000.0, rms)
        if rms < 0.0008 {
            // Advance offsets — quiet samples never need re-attempt.
            micOffset = micCurrent
            sysOffset = sysCurrent
            return
        }

        do {
            let lang = settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage
            let result = try await engine.transcribe(
                audioSamples: mixed,
                language: lang,
                // TR-3 (4th site, ITER-046): these live partials feed the Meeting
                // Copilot AND the assembled recap transcript. The English-only
                // glossary as an initial_prompt biased RU meetings toward <|en|>,
                // so the copilot/recap saw EN-bled garbage. Gate like the other
                // three sites; brand names are still fixed post-hoc by
                // applyCorrections below.
                promptWords: TranscriptionLanguageResolver.enginePromptWords(language: lang),
                // ITER-054 — live-advice chunks are part of THIS meeting, which
                // is billed once by wall-clock at finalize (applyMeetingStop).
                // Metering them here (Codex review) double-booked opt-in
                // live-advice meetings on top of the final log. Ride free.
                countUsage: false
            )
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[LiveAdvise] transcribed %d chars", rawText.count)

            // Advance offsets on success — this audio is now "consumed".
            micOffset = micCurrent
            sysOffset = sysCurrent

            // Filter the well-known Whisper hallucinations (matches existing path).
            if rawText.isEmpty || TranscriptionCoordinator.isAlwaysHallucination(rawText) { return }
            if rms < 0.003, TranscriptionCoordinator.isHallucination(rawText) { return }

            // 2026-05-28: surgically strip mid-text hallucination artifacts
            // BEFORE storing in `collectedPartials`. Without this, the final
            // meeting transcript (assembled from these partials in
            // `assembleMeetingTranscriptFromLive`) inherited DimaTorzok /
            // «Субтитры сделал» / «Продолжение следует» mid-stream. Pinned
            // by `HallucinationStripTests`. Then auto-correct unambiguous
            // brand mangles (Brevo from Cyrillic transliteration).
            let stripped = TranscriptionCoordinator.stripHallucinationTokens(rawText)
            if stripped.isEmpty {
                NSLog("[LiveAdvise] 🧹 partial emptied by strip (was %d chars)", rawText.count)
                return
            }
            if stripped != rawText {
                NSLog("[LiveAdvise] 🧹 stripped hallucination from partial (was %d → %d chars)", rawText.count, stripped.count)
            }
            let text = BrandGlossary.applyCorrections(stripped)

            lastPartial = text
            lastFireAt = Date()
            // Accumulate for later reuse as the FINAL meeting transcript — skips the
            // 2nd cloud transcription pass that `AppDelegate.stopMeetingRecording`
            // used to do over the same audio (was 50% of all cloud minutes per meeting).
            collectedPartials.append(text)
            // ITER-041 Phase D — gate the heavy MeetingCoach LLM tick.
            // Skip the floating Copilot overlay when the cheap gate sees no
            // coachable moment in this 30s partial. Without a Pro license
            // the gate is bypassed (MeetingCoach already no-ops on non-Pro).
            // Standard advice trigger below has its own Phase C gate.
            if LicenseService.shared.isPro, let key = LicenseService.shared.licenseKey {
                let gate = await GateClient.call(
                    context: text,
                    purpose: .meetingCoach,
                    recentTopics: [],
                    serviceId: MeetingCoachService.llmServiceId,
                    licenseKey: key
                )
                if gate.shouldFire {
                    Task { await MeetingCoachService.shared.process(partialText: text) }
                } else {
                    NSLog("[LiveAdvise] gate-skipped MeetingCoach score=%.2f — %@",
                          gate.score, String(gate.reasoning.prefix(80)))
                }
            } else {
                Task { await MeetingCoachService.shared.process(partialText: text) }
            }
            // Standard advice path stays — it posts the macOS notification and
            // populates Insights. Meeting Copilot adds the live overlay on TOP of that.
            adviceService?.triggerOnTranscription(text: text, source: "meeting-live")
            NSLog("[LiveAdvise] 🎯 partial fired (%d chars, rms=%.4f)", text.count, rms)
        } catch {
            // Don't advance offsets — try again next round.
            NSLog("[LiveAdvise] transcribe failed (will retry): %@",
                  error.localizedDescription)
        }
    }
}
