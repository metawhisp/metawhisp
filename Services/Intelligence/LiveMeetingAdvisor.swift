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
    @Published private(set) var isActive = false
    /// Last partial text we transcribed — useful for diagnostics + UI status pill.
    @Published private(set) var lastPartial: String = ""
    @Published private(set) var lastFireAt: Date?

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
        guard isActive else { return }
        isActive = false
        timerTask?.cancel()
        timerTask = nil
        micOffset = 0
        sysOffset = 0
        NSLog("[LiveAdvise] ⏹ disarmed")
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
                promptWords: ["MetaWhisp"]
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Advance offsets on success — this audio is now "consumed".
            micOffset = micCurrent
            sysOffset = sysCurrent

            // Filter the well-known Whisper hallucinations (matches existing path).
            if text.isEmpty || TranscriptionCoordinator.isAlwaysHallucination(text) { return }
            if rms < 0.003, TranscriptionCoordinator.isHallucination(text) { return }

            lastPartial = text
            lastFireAt = Date()
            adviceService?.triggerOnTranscription(text: text, source: "meeting-live")
            NSLog("[LiveAdvise] 🎯 partial fired (%d chars, rms=%.4f)", text.count, rms)
        } catch {
            // Don't advance offsets — try again next round.
            NSLog("[LiveAdvise] transcribe failed (will retry): %@",
                  error.localizedDescription)
        }
    }
}
