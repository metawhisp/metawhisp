import Foundation

/// C6 / PRD P0 3 — the onboarding's "Try your voice": one sentence through the
/// real engine, shown in its own window and nowhere else.
///
/// It records with a microphone of its own once the capture arbiter gives it
/// the microphone, and transcribes with the engine dictation uses — unbilled,
/// through dictation's pure filters. It holds no way to keep or deliver the
/// text: on success, error and cancel alike nothing reaches a clipboard, the
/// history, an export, the recovery folder or the focused app (pinned by a
/// source guard in PracticeRecorderTests). Every attempt carries a token; a
/// result that comes back for an attempt cancelled, ended or replaced is
/// dropped.
@MainActor
final class PracticeRecorder: ObservableObject {
    enum Phase: Equatable {
        /// A dictation or a meeting has the microphone; the practice gets it
        /// when they end.
        case waiting(String)
        case ready
        case listening
        case transcribing
        case result(String)
        case noSpeech
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ready

    private let microphone: any AudioSource
    private let engine: @MainActor () -> (any TranscriptionEngine)?
    private let language: @MainActor () -> String?
    private let arbiter: CaptureArbiter
    /// The attempt in flight; a result for any other is dropped.
    private var attempt = UUID()
    /// The first press on a microphone nobody answered asks, as dictation's does.
    private let microphonePrompt = MicrophonePrompt()
    static let microphoneOff = "Microphone access is off. Allow MetaWhisp in System Settings → Privacy & Security → Microphone."

    private var transcription: Task<Void, Never>?
    /// The microphone's recording this practice is listening in; nil when it
    /// is not listening — after a stop, a cancel and so `end()`, which leaves
    /// a teardown nothing to stop. A teardown stops that recording only: the
    /// microphone is the app's, and the next practice records on it
    /// (round-2 N3).
    private var listeningSession: Int?

    init(microphone: any AudioSource,
         engine: @escaping @MainActor () -> (any TranscriptionEngine)?,
         arbiter: CaptureArbiter,
         language: @escaping @MainActor () -> String? = {
             TranscriptionLanguageResolver.resolveLanguage(AppSettings.shared.transcriptionLanguage)
         }) {
        self.microphone = microphone
        self.engine = engine
        self.arbiter = arbiter
        self.language = language
    }

    /// The practice screen is up: it takes the microphone, or waits for the
    /// dictation or meeting that has it.
    func begin() {
        if let reason = arbiter.claim(for: self) {
            phase = .waiting(reason)
        } else if case .waiting = phase {
            phase = .ready
        }
    }

    /// The arbiter let a waiting practice in.
    func granted() {
        if case .waiting = phase { phase = .ready }
    }

    /// The record button, Space, Right ⌘.
    func toggle() {
        phase == .listening ? stop() : start()
    }

    func start() {
        guard arbiter.owns(self) else { return }
        switch phase {
        case .waiting, .listening, .transcribing: return
        case .ready, .result, .noSpeech, .failed: break
        }
        guard microphone.hasPermission else {
            guard microphone.permissionUndetermined else {
                phase = .failed(Self.microphoneOff)
                return
            }
            // The press that asks records nothing; the next one records.
            microphonePrompt.ask(microphone, PermissionAsk()) { [weak self] granted in
                guard let self, phase == .ready else { return }
                if !granted { phase = .failed(Self.microphoneOff) }
            }
            return
        }
        do {
            try microphone.start()
        } catch {
            phase = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        attempt = UUID()
        listeningSession = microphone.captureSession
        phase = .listening
        arbiter.practice(self, isBusy: true)
    }

    func stop() {
        guard phase == .listening else { return }
        let samples = microphone.stop()
        listeningSession = nil
        if let early = Self.precheck(samples, microphoneVerdict: microphone.micHealthError) {
            finish(early)
            return
        }
        guard let engine = engine(), engine.isModelLoaded else {
            finish(.failed("The speech model isn't ready yet."))
            return
        }
        phase = .transcribing
        let mine = attempt
        let language = language()
        let rms = TranscriptionCoordinator.calculateRMS(samples)
        // Weak: a screen that goes away mid-transcription must not be kept
        // alive by it, holding capture and the lease (step-1 review #5).
        transcription = Task { [weak self] in
            let outcome: Phase
            do {
                let result = try await engine.transcribe(
                    audioSamples: samples, language: language,
                    promptWords: TranscriptionLanguageResolver.enginePromptWords(language: language),
                    countUsage: false)
                outcome = Self.outcome(of: result, rms: rms)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard let self, mine == attempt else { return }
            finish(outcome)
        }
    }

    /// A screen torn down without `end()`: its weak claim on capture is gone
    /// already; the arbiter is told now so the lease goes idle at once, and the
    /// microphone stops if it is still in the recording this practice was
    /// listening in — a device change may have paused it — and in no other.
    deinit {
        let arbiter = arbiter
        let microphone = microphone
        let session = listeningSession
        Task { @MainActor in
            if let session, microphone.captureSession == session { _ = microphone.stop() }
            arbiter.recheck()
        }
    }

    /// Esc during an attempt: the microphone stops and the attempt is dropped;
    /// the screen keeps the microphone.
    func cancel() {
        attempt = UUID()
        transcription?.cancel()
        transcription = nil
        // A device change mid-attempt shows the microphone as not recording
        // while its follow waits to resume it: stop it all the same, which
        // drops the follow (step-1 review #4).
        if phase == .listening || microphone.isRecording { _ = microphone.stop() }
        listeningSession = nil
        if phase == .listening || phase == .transcribing { phase = .ready }
        arbiter.practice(self, isBusy: false)
    }

    /// The screen goes away — Back, Next, the window closing: the attempt is
    /// dropped and the microphone given back.
    func end() {
        cancel()
        arbiter.release(self)
    }

    private func finish(_ outcome: Phase) {
        transcription = nil
        phase = outcome
        arbiter.practice(self, isBusy: false)
    }

    /// Before any transcription: an accidental tap, a dead microphone, a
    /// silent room — dictation's own thresholds. A recording too short to
    /// judge is the microphone's fault when the microphone judged itself
    /// dead: dictation's capture path finds a device that delivers nothing by
    /// the clock and says so, as dictation does (59a8953) — not "no speech".
    static func precheck(_ samples: [Float], microphoneVerdict: String? = nil) -> Phase? {
        guard samples.count > 4800 else { return microphoneVerdict.map { .failed($0) } ?? .noSpeech }
        let rms = TranscriptionCoordinator.calculateRMS(samples)
        if rms == 0 { return .failed(AudioRecordingService.deadMicMessage) }
        if rms < 0.0003 { return .noSpeech }
        return nil
    }

    /// What dictation's pure filters make of a transcript. Where a dictation
    /// keeps a suspect transcript for the user to recover, the practice simply
    /// asks for another try.
    static func outcome(of result: TranscriptionResult, rms: Float) -> Phase {
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !TranscriptionCoordinator.isAlwaysHallucination(text) else { return .noSpeech }
        let lower = text.lowercased()
        if TranscriptionCoordinator.toxicHallucinationTokens.contains(where: { lower.contains($0) }) {
            text = TranscriptionCoordinator.stripHallucinationTokens(text)
        }
        if rms < 0.003, TranscriptionCoordinator.isHallucination(text) { return .noSpeech }
        if TranscriptionConfidenceGate.rejectionReason(
            TranscriptionConfidenceGate.aggregateMetrics(result.segments), text: text) != nil {
            return .noSpeech
        }
        text = BrandGlossary.applyCorrections(text)
        return text.isEmpty ? .noSpeech : .result(text)
    }
}
