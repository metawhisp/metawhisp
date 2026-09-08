import AppKit
import AVFoundation
import Foundation
import os

/// Single-point lifecycle coordinator for transcription pipeline.
/// States: Idle -> Recording -> Processing -> Idle
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    enum Stage: String, Equatable {
        case idle
        case recording
        case processing
        case postProcessing
    }

    @Published var stage: Stage = .idle
    @Published var lastResult: TranscriptionResult?
    @Published var lastError: String?
    /// Per-recording flag: translate this recording (set by Right ⌥ shortcut).
    @Published var translateNext = false

    private let recorder: any AudioSource
    /// The on-device WhisperKit model id currently loaded and ready (nil = none).
    /// FREE-1/FREE-7: onboarding gates on "the SELECTED model is loaded", not just
    /// "downloaded" or "some model loaded" — downloading Tiny then Large must load
    /// Large, not silently keep Tiny.
    @Published var loadedWhisperModelId: String? = nil
    /// FREE-2: set true once a BYOK cloud key has validated against the provider,
    /// so the onboarding gate reacts (an @AppStorage key write doesn't publish).
    /// Onboarding-transient: onboarding has no provider switcher (so it can't go
    /// stale there) and this flag is not consulted after onboarding completes.
    @Published var cloudKeyValidated: Bool = false
    var whisperEngine: WhisperKitEngine?
    private let cloudEngine = CloudWhisperEngine()
    private let textInserter: TextInsertionService
    private let soundService: SoundService
    private let settings: AppSettings
    var historyService: HistoryService?
    var textProcessor: TextProcessor?
    var correctionDictionary: CorrectionDictionary?
    var correctionMonitor: CorrectionMonitor?
    /// Optional. If set and AI Advice is enabled, each successful transcription
    /// fires a trigger that may generate a contextual advice.
    /// spec://intelligence/FEAT-0003#triggers.transcription
    weak var adviceService: AdviceService?

    /// Optional. If set and memory collection is enabled, each successful transcription
    /// fires a trigger that may extract up to 2 memories.
    /// spec://iterations/ITER-001#architecture.extractor
    weak var memoryExtractor: MemoryExtractor?

    /// Optional. If set and tasks enabled, each successful transcription fires a trigger
    /// that may extract action items (dedup over 2 days).
    /// spec://BACKLOG#B1
    weak var taskExtractor: TaskExtractor?

    /// Optional. Groups consecutive transcripts into Conversations (aggregation root).
    /// spec://BACKLOG#C1.1
    weak var conversationGrouper: ConversationGrouper?

    /// Optional. When voiceQuestionMode is active, the transcript is routed to ChatService
    /// (as a voice question) instead of the clipboard.
    /// spec://BACKLOG#Phase6
    weak var chatService: ChatService?

    /// ITER-035 v2 — after a dictation HistoryItem is saved + assigned to a
    /// Conversation, fire-and-forget a markdown export to the user's Obsidian
    /// vault. No-op when sync isn't enabled.
    weak var obsidianExporter: ObsidianExporter?

    /// True while user is holding Right ⌘ (long-press). Set by `startVoiceQuestion()` /
    /// cleared by `stopVoiceQuestion()` handler after the transcript is sent.
    var voiceQuestionMode: Bool = false

    /// Source label for history items (set when switching audio source).
    var audioSourceLabel: String = "microphone"

    /// Returns the active transcription engine based on settings.
    /// Internal so meeting recording can reuse the same engine without duplicating logic.
    var activeEngine: (any TranscriptionEngine)? {
        settings.transcriptionEngine == "cloud" ? cloudEngine : whisperEngine
    }

    private static let debounceInterval: TimeInterval = 0.03
    private var lastToggleTime: Date = .distantPast

    init(
        recorder: any AudioSource,
        whisperEngine: WhisperKitEngine?,
        textInserter: TextInsertionService,
        soundService: SoundService,
        settings: AppSettings
    ) {
        self.recorder = recorder
        self.whisperEngine = whisperEngine
        self.textInserter = textInserter
        self.soundService = soundService
        self.settings = settings
    }

    /// Toggle with translation — called by Right ⌥ shortcut.
    func toggleWithTranslation() {
        if stage == .idle { translateNext = true }
        NSLog("[Coordinator] Translate requested (stage=%@, armed=%@)", "\(stage)", translateNext ? "YES" : "NO")
        toggle()
    }

    /// PTT start — called on key down in push-to-talk mode.
    func startPTT() {
        guard stage == .idle else {
            NSLog("[Coordinator] PTT start ignored: stage=%@", "\(stage)")
            return
        }
        NSLog("[Coordinator] PTT start")
        startRecording()
    }

    /// PTT stop — called on key release in push-to-talk mode.
    func stopPTT() {
        guard stage == .recording else {
            NSLog("[Coordinator] PTT stop ignored: stage=%@", "\(stage)")
            return
        }
        NSLog("[Coordinator] PTT stop")
        stopAndTranscribe()
    }

    /// Toggle recording on/off. Debounces rapid presses.
    func toggle() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > Self.debounceInterval else {
            NSLog("[Coordinator] Debounced toggle")
            return
        }
        lastToggleTime = now

        NSLog("[Coordinator] Toggle called, stage: %@", "\(stage)")

        switch stage {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing, .postProcessing:
            NSLog("[Coordinator] Ignoring toggle: processing in progress")
        }
    }

    /// Right ⌘ long-press → start voice question recording. Routed to MetaChat on release.
    /// spec://BACKLOG#Phase6
    func startVoiceQuestion() {
        guard stage == .idle else {
            NSLog("[Coordinator] Voice question: busy (stage=\(stage)) — skipping")
            return
        }
        voiceQuestionMode = true
        VoiceQuestionState.shared.startListening()
        NSLog("[Coordinator] 🎤 Voice question mode ON")
        startRecording()
    }

    /// Right ⌘ release after long-press → stop + transcribe + send to ChatService.
    func stopVoiceQuestion() {
        guard stage == .recording, voiceQuestionMode else {
            NSLog("[Coordinator] Voice question stop called but not in voice question recording state")
            voiceQuestionMode = false
            return
        }
        NSLog("[Coordinator] 🎤 Voice question mode STOPPING")
        VoiceQuestionState.shared.transcribing()
        stopAndTranscribe()
        // voiceQuestionMode flag reset inside the transcription completion path.
    }

    private func startRecording() {
        // Check microphone permission before starting
        guard recorder.hasPermission else {
            translateNext = false
            lastError = "🎤 Microphone access denied — open System Settings > Privacy > Microphone"
            NSLog("[Coordinator] ❌ Mic permission denied, cannot record")
            soundService.playError()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // ITER-026 v2 — if a meeting is recording, signal AppDelegate to pause
        // mic capture for the meeting so this dictation/voice question doesn't
        // leak into the meeting transcript. AppDelegate also pushes an
        // "End meeting?" card on the user's first dictation hotkey.
        AppDelegate.shared?.dictationDidStart()

        do {
            // Remember which app had focus before recording (for auto-paste back)
            textInserter.savePreviousApp()
            try recorder.start()
            stage = .recording
            lastError = nil
            soundService.playStart()
            NSLog("[Coordinator] ✅ Recording started (translate=%@)", translateNext ? "YES" : "NO")
        } catch {
            translateNext = false
            lastError = error.localizedDescription
            NSLog("[Coordinator] ❌ Failed to start: %@", error.localizedDescription)
            soundService.playError()
            // Failed before any audio → resume meeting mic immediately so we
            // don't leave a dangling pause window.
            AppDelegate.shared?.dictationDidEnd()
        }
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        // ITER-026 v2 — resume meeting mic capture (if a meeting was running
        // it was paused by `dictationDidStart` in `startRecording`). Once
        // recorder.stop() returns, dictation mic is off, so it's safe.
        AppDelegate.shared?.dictationDidEnd()
        // Capture & reset translate flag immediately — prevents leaking to next recording
        let shouldTranslate = translateNext
        translateNext = false
        stage = .processing
        soundService.playStop()
        NSLog("[Coordinator] Recording stopped, %d samples, translate=%@", samples.count, shouldTranslate ? "YES" : "NO")

        // Discard accidental triggers (< 0.3s of audio = 4800 samples at 16kHz)
        guard samples.count > 4800 else {
            NSLog("[Coordinator] Too short (%d samples), discarding", samples.count)
            abortVoiceQuestionIfActive(reason: "Too short — try holding longer.")
            stage = .idle
            return
        }

        // Silence detection: check if audio has enough energy to contain speech
        // Built-in MacBook mic: silence ~0.0002, quiet speech ~0.0005-0.002, normal ~0.003+
        // Threshold lowered to avoid dropping real speech recorded quietly
        let rms = Self.calculateRMS(samples)
        // Digital silence is NOT a quiet room. RMS is zero only when every
        // sample is zero, i.e. no signal arrived at all. Telling that user to
        // "speak closer to the mic" is the advice that cost a day on
        // 2026-08-12, when macOS fed the process eight recordings of nothing
        // and the app never once said the microphone had gone dead.
        if rms == 0, !samples.isEmpty {
            NSLog("[Coordinator] ❌ recording was DIGITAL SILENCE (%d samples, RMS=0) — the mic delivered no audio",
                  samples.count)
            lastError = AudioRecordingService.deadMicMessage
            abortVoiceQuestionIfActive(reason: AudioRecordingService.deadMicMessage)
            stage = .idle
            return
        }
        if rms < 0.0003 {
            NSLog("[Coordinator] Audio too quiet (RMS=%.5f), skipping transcription", rms)
            abortVoiceQuestionIfActive(reason: "Audio too quiet — speak closer to the mic.")
            stage = .idle
            return
        }

        Task {
            await transcribe(samples: samples, shouldTranslate: shouldTranslate, rms: rms)
        }
    }

    /// Voice-question mode aborts must reset BOTH the flag (so the next
    /// short-tap dictation doesn't get routed to MetaChat) AND the popup
    /// state (so the floating answer window doesn't sit there forever in
    /// `.listening` / `.transcribing`). 2026-05-01 user report:
    /// "нажимаю долго но не успеваю сказать → попап зависает; следующий
    /// короткий tap вставляется в этот VoiceBlock". Pair-reset fixes both
    /// in one helper called from every early-return path.
    private func abortVoiceQuestionIfActive(reason: String) {
        guard voiceQuestionMode else { return }
        NSLog("[Coordinator] 🎤 voice question aborted: %@", reason)
        voiceQuestionMode = false
        VoiceQuestionState.shared.failed(reason)
    }

    private func transcribe(samples: [Float], shouldTranslate: Bool, rms: Float) async {
        guard let currentEngine = activeEngine, currentEngine.isModelLoaded else {
            lastError = settings.transcriptionEngine == "cloud" ? "API key not set for cloud transcription" : "No model loaded. Go to Settings to download one."
            abortVoiceQuestionIfActive(reason: "Transcription engine not ready.")
            stage = .idle
            soundService.playError()
            NSLog("[Coordinator] ❌ Engine not ready")
            NSLog("[Coordinator] engine=%@, %d samples (%.1fs) dropped — %@", settings.transcriptionEngine, samples.count, Double(samples.count) / 16000.0, lastError ?? "?")
            return
        }

        NSLog("[Coordinator] Transcribing %d samples via %@...", samples.count, currentEngine.name)

        do {
            let lang = TranscriptionLanguageResolver.resolveLanguage(settings.transcriptionLanguage)
            // Prompt = curated brand glossary only, EN-gated (see
            // enginePromptWords). The correction dictionary is deliberately NOT
            // in the prompt: its values are applied post-hoc by
            // CorrectionDictionary.apply below; feeding them to the decoder made
            // Whisper echo them back verbatim on silence (2026-08-06).
            let promptWords = TranscriptionLanguageResolver.enginePromptWords(language: lang)
            let result = try await currentEngine.transcribe(audioSamples: samples, language: lang, promptWords: promptWords)

            var trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                NSLog("[Coordinator] Empty result")
                NSLog("[Coordinator] empty transcript after %.2fs engine time, RMS=%.5f", result.processingTime, rms)
                // Surface to user — silent return left them wondering why
                // pressing ⌘ produced nothing. Most common cause is Cloud
                // Whisper / on-device engine returning a blank string when
                // it can't decode the audio. Suggest retry.
                lastError = "Transcription returned empty — try again louder/closer."
                abortVoiceQuestionIfActive(reason: "Transcription returned empty.")
                stage = .idle
                return
            }

            // Filter Whisper hallucinations.
            // Phase 1: Always-filter toxic tokens (YouTube artifacts) regardless of RMS.
            if Self.isAlwaysHallucination(trimmed) {
                NSLog("[Coordinator] ⚠️ Filtered hallucination (always): %d chars", trimmed.count)
                // CRITICAL: do NOT auto-paste, but DO save text to clipboard +
                // expose via lastResult so user can recover. Filter is heuristic;
                // false positives have lost real dictations (3 times today,
                // 2026-05-01). Better to put suspect text on clipboard than
                // silently discard 30-60s of speech.
                Self.saveSuspectToClipboard(trimmed)
                lastResult = result
                lastError = "Looked like a hallucination — text saved to clipboard, ⌘V to paste anyway."
                abortVoiceQuestionIfActive(reason: "Filtered as hallucination.")
                stage = .idle
                return
            }
            // ITER-035-followup #2 (2026-05-12) — long-form dictation MAY still
            // contain a hallucination artifact spliced into a momentary silence
            // mid-speech (Whisper inserts «DimaTorzok» / «Subtitles by» between
            // real phrases). `isAlwaysHallucination` returned false for these
            // (text was long enough to be real speech), but we still need to
            // strip the toxic substring before sending to TextProcessor.
            let lowerCheck = trimmed.lowercased()
            let stillHasToxic = Self.toxicHallucinationTokens.contains { lowerCheck.contains($0) }
            if stillHasToxic {
                let cleaned = Self.stripHallucinationTokens(trimmed)
                if cleaned != trimmed {
                    NSLog("[Coordinator] 🧹 Stripped hallucination tokens (was %d chars, now %d)",
                          trimmed.count, cleaned.count)
                    trimmed = cleaned
                }
            }
            // Phase 2: Pattern-match only on near-silence audio (RMS < 0.003).
            // Built-in MacBook mic: silence ~0.0005, quiet speech ~0.002, normal speech ~0.005+
            if rms < 0.003, Self.isHallucination(trimmed) {
                NSLog("[Coordinator] ⚠️ Filtered hallucination (RMS=%.4f): %d chars", rms, trimmed.count)
                // Same recovery path — text on clipboard so user has the
                // option even on quiet-audio false positives.
                Self.saveSuspectToClipboard(trimmed)
                lastResult = result
                lastError = "Audio too quiet, but text saved to clipboard — ⌘V to paste anyway."
                abortVoiceQuestionIfActive(reason: "Audio too quiet for voice question.")
                stage = .idle
                return
            }

            // TR-5: metric-based hallucination guard. The pattern filters above
            // catch known artifacts; this catches SEMANTIC hallucinations they miss,
            // using Whisper's own per-segment confidence metrics (aggregated over the
            // clip). Precision-first thresholds, and — critically — it routes to the
            // SAME clipboard recovery, never the silent-discard path, so a false
            // positive costs the user a ⌘V, not their dictation.
            if let reason = TranscriptionConfidenceGate.rejectionReason(
                TranscriptionConfidenceGate.aggregateMetrics(result.segments),
                text: trimmed
            ) {
                NSLog("[Coordinator] 🎚️ Low-confidence metrics (%@) — saved to clipboard, not pasted", reason)
                Self.saveSuspectToClipboard(trimmed)
                lastResult = result
                lastError = "Low transcription confidence — text saved to clipboard, ⌘V to paste anyway."
                abortVoiceQuestionIfActive(reason: "Low transcription confidence.")
                stage = .idle
                return
            }

            lastResult = result
            NSLog("[Coordinator] ✅ lang=%@, %.2fs, %d chars", result.language ?? "?", result.processingTime, result.text.count)

            // AUD-011 — establish ONE normalized transcript value, used for
            // post-processing, history, Obsidian export, downstream AI and paste.
            // Start from the sanitized `trimmed` (hallucination tokens already
            // stripped), NOT the raw result.text which would re-introduce them.
            var finalText = trimmed

            let needsProcess = (textProcessor?.needsProcessing ?? false) || shouldTranslate
            if let processor = textProcessor, needsProcess {
                stage = .postProcessing
                do {
                    let (processed, wasProcessed) = try await processor.process(finalText, translate: shouldTranslate)
                    if wasProcessed {
                        finalText = processed
                        NSLog("[Coordinator] ✅ Post-processed: %d chars", processed.count)
                    }
                } catch {
                    NSLog("[Coordinator] ⚠️ Post-processing failed: %@", error.localizedDescription)
                    NSLog("[Coordinator] continuing with UNPROCESSED text (%d chars, translate=%@) — no translation applied", finalText.count, shouldTranslate ? "YES" : "NO")
                    lastError = error.localizedDescription
                }
            }

            // 2026-05-28: brand-name auto-correct (BrandGlossary) BEFORE the user
            // dictionary apply so an explicit user override still wins. Only
            // unambiguous Cyrillic mangles (Бриво→Brevo, etc.) — see BrandGlossary.
            let glossaryCorrected = BrandGlossary.applyCorrections(finalText)
            if glossaryCorrected != finalText {
                NSLog("[Coordinator] 📚 BrandGlossary corrected (%d chars)", glossaryCorrected.count)
                finalText = glossaryCorrected
            }

            // Apply learned corrections (after all processing, before paste).
            if let dict = correctionDictionary {
                let corrected = dict.apply(finalText)
                if corrected != finalText {
                    NSLog("[Coordinator] 📝 Applied corrections (%d chars)", corrected.count)
                    finalText = corrected
                }
            }

            // AUD-011 — save history with the SAME normalized value used for paste,
            // so Library, Obsidian export and downstream AI extraction all match it.
            // processedText carries the normalized string whenever it differs from the
            // raw transcript (displayText falls back to the raw text otherwise).
            if let hs = historyService {
                let item = hs.save(result)
                NSLog("[Coordinator] history %@ (translatedTo=%@, %d chars)", item == nil ? "NOT saved" : "saved", shouldTranslate ? settings.translateTo : "-", finalText.count)
                NSLog("[Coordinator] History save: %@", item == nil ? "SKIPPED (store degraded or save failed)" : "OK")
                item?.processedText = (finalText == result.text) ? nil : finalText
                item?.translatedTo = shouldTranslate ? settings.translateTo : nil
                item?.modelName = settings.selectedModel
                item?.source = audioSourceLabel
                // Assign to Conversation (C1.1) — sets conversationId on the item.
                if let item {
                    conversationGrouper?.assign(historyItem: item)
                    // ITER-035 v2 — export this dictation as a markdown file in the
                    // user's Obsidian vault. Fire-and-forget; ObsidianExporter gates.
                    if let exporter = obsidianExporter {
                        let itemID = item.id
                        Task { @MainActor in
                            await exporter.exportHistoryItem(itemID)
                        }
                    }
                }
            }

            // Voice question mode (Phase 6) — route to MetaChat instead of clipboard paste.
            if voiceQuestionMode {
                voiceQuestionMode = false
                NSLog("[Coordinator] 🎤 Voice question transcript → MetaChat (%d chars)", finalText.count)
                VoiceQuestionState.shared.thinking(transcript: finalText)
                if let chat = chatService {
                    // F1.9 — keep the handle so Esc (dismiss) can cancel the
                    // in-flight generation instead of letting it run blind.
                    VoiceQuestionState.shared.activeSendTask = Task {
                        await chat.send(finalText, source: .voice)
                        NSLog("[Coordinator] 🎤 voice question send returned (chatError=%@)", chat.lastError ?? "none")
                    }
                } else {
                    NSLog("[Coordinator] ⚠️ chatService nil — voice question dropped")
                    VoiceQuestionState.shared.failed("Chat not available")
                }
                // Skip clipboard / paste for voice questions.
            } else if settings.autoSubmit {
                let outcome = textInserter.insertResult(text: finalText)
                switch outcome {
                case .autoPasted:
                    // Auto-learn corrections after successful paste.
                    correctionMonitor?.startMonitoring(pastedText: finalText)
                case .clipboardOnly:
                    lastError = "Copied to clipboard — press ⌘V to paste"
                case .clipboardFailed:
                    // Honest message — clipboard write actually failed (race
                    // with another process owning the pasteboard). User
                    // manually pressing ⌘V would paste nothing. Tell them
                    // where to recover from.
                    lastError = "Clipboard write failed — recover from Library → History"
                }
            }

            // Memory + task extractors no longer fire per-transcript. They run once on
            // conversation close (via ConversationGrouper.scheduleOnClose) so the LLM sees
            // the whole conversation context — needed for resolution, assignee filter, dedup.
            // spec://BACKLOG#B1

            soundService.playSuccess()
            NSLog("[Coordinator] ✅ Dictation done: translate=%@, %d chars, autoPaste=%@", shouldTranslate ? "YES" : "NO", finalText.count, settings.autoSubmit ? "ON" : "OFF")
            NSLog("[Coordinator] ✅ Done: %d chars, autoPaste=%@", finalText.count, settings.autoSubmit ? "on" : "off")
            stage = .idle

        } catch {
            // Cloud Whisper / on-device engine failed (network blip, 502, etc).
            // Save raw audio to a recovery folder so the user can re-submit
            // later — losing 30-60 seconds of speech to a transient HTTP
            // glitch is unacceptable for a dictation tool.
            let recoveryURL = Self.saveSamplesAsWav(samples)
            let baseMsg = error.localizedDescription
            if let url = recoveryURL {
                lastError = "\(baseMsg) — audio saved to \(url.path)"
                NSLog("[Coordinator] ❌ Transcription failed: %@ — audio recovery: %@",
                      baseMsg, url.path)
            } else {
                lastError = baseMsg
                NSLog("[Coordinator] ❌ Transcription failed: %@ (recovery save also failed)", baseMsg)
            }
            abortVoiceQuestionIfActive(reason: "Transcription failed: \(baseMsg)")
            soundService.playError()
            stage = .idle
        }
    }

    // MARK: - Recovery

    /// Save filtered/suspect transcription text to system pasteboard. Called
    /// from hallucination-filter discard paths so user never loses 30-60s of
    /// speech to a false positive. We DON'T auto-paste — just put text on
    /// clipboard and let user decide. Paired with `lastResult` + `lastError`
    /// surfacing so the popover shows a preview + recovery hint.
    static func saveSuspectToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSLog("[Coordinator] 💾 Suspect text saved to clipboard (%d chars)", text.count)
    }

    /// Save raw 16kHz mono Float32 samples as a WAV in
    /// `~/Library/Application Support/MetaWhisp/Recovery/`.
    /// Used when transcription fails — gives the user something they can
    /// re-submit instead of losing the dictation entirely.
    static func saveSamplesAsWav(_ samples: [Float], named fileName: String? = nil) -> URL? {
        guard !samples.isEmpty else { return nil }

        // Resolve / create the recovery folder.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("MetaWhisp", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Coordinator] saveSamplesAsWav: mkdir failed — %@", error.localizedDescription)
            return nil
        }

        let stamp: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            return fmt.string(from: Date())
        }()
        let url = dir.appendingPathComponent(fileName ?? "recording-\(stamp).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                return nil
            }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ptr in
                if let dst = buf.floatChannelData?.pointee, let src = ptr.baseAddress {
                    dst.update(from: src, count: samples.count)
                }
            }
            try file.write(from: buf)
            NSLog("[Coordinator] 💾 Wrote recovery WAV: %@ (%d samples / %.1fs)",
                  url.path, samples.count, Double(samples.count) / 16000.0)
            return url
        } catch {
            NSLog("[Coordinator] saveSamplesAsWav: write failed — %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Audio Analysis

    /// Calculate RMS energy of audio samples.
    static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return sqrtf(sumSq / Float(samples.count))
    }

    // MARK: - Hallucination Filter

    /// Tokens that are ALWAYS hallucinations — filter regardless of audio energy.
    /// These are YouTube artifacts that Whisper never produces from real speech.
    /// Exposed internally so meeting recording can reuse the same filter.
    /// Tokens that NEVER appear in real human speech — they're Whisper's
    /// «I don't know what to emit on this silent fragment» fillers. Single
    /// source of truth for both detection (this method) and surgical removal
    /// (`stripHallucinationTokens`).
    static let toxicHallucinationTokens = [
        "♪", "♫", "торзок", "torzok", "dimatorzok", "dima torzok",
        "amara.org", "переводчик:", "translator:",
    ]

    /// Surgical removal of hallucination artifacts from a transcript that's
    /// OTHERWISE real speech. Catches both bare tokens («DimaTorzok») and the
    /// usual attribution sentences («Subtitles by DimaTorzok»). Cleans up
    /// double-spaces and dangling punctuation after removal. Caller checks
    /// for toxic-token presence first; this just does the cleanup.
    static func stripHallucinationTokens(_ text: String) -> String {
        var result = text

        // Order matters — longer / more specific patterns first so we don't
        // leave «Subtitles by» behind after removing «DimaTorzok».
        //
        // 2026-05-28 expansion: meeting transcripts in production were
        // leaking «Субтитры сделал DimaTorzok», «Субтитры создавал
        // DimaTorzok», «Продолжение следует…», «Спасибо за просмотр»,
        // «Подписывайтесь». 14× DimaTorzok in last 10 long meetings. The
        // old regex only covered «by/от» attribution; Whisper actually
        // emits the verb forms «сделал/создавал/делал/подогнал/писал/
        // предоставил/корректировал/написал». Added verb-attribution
        // branch + standalone YouTube boilerplate patterns. Regression-
        // pinned by `HallucinationStripTests`.
        let patterns: [String] = [
            // 1. Full attribution with name — Whisper YouTube artifact.
            //    Covers both English «by/от» and Russian verb forms.
            #"(?i)\s*\b(subtitles?|субтитры|перевод(ил)?|translated)\s+(by\s+|от\s+|сделал\s+|создавал\s+|делал\s+|подогнал\s+|писал\s+|предоставил\s+|корректировал\s+|написал\s+)?(dima\s*torzok|dimatorzok|amara\.org)\b\.?"#,

            // 2. Bare verb-attribution (no name after, or name was already
            //    stripped by pattern 3 below). «Субтитры сделал» on its own
            //    is never real meeting speech.
            #"(?i)\s*\b(subtitles?|субтитры|перевод(ил)?)\s+(by|от|сделал|создавал|делал|подогнал|писал|предоставил|корректировал|написал)\b\.?"#,

            // 3. Standalone «DimaTorzok» / variants
            #"(?i)\bdima\s*torzok\b"#,
            #"(?i)\bdimatorzok\b"#,
            #"(?i)\bторзок\b"#,

            // 4. Translator attribution
            #"(?i)переводчик:\s*\S+"#,
            #"(?i)translator:\s*\S+"#,

            // 5. «Продолжение следует» / «To be continued» — YouTube outro
            //    that Whisper inserts on silence at chunk boundaries.
            //    Trailing ellipsis (3 dots OR single … char) optional.
            #"(?i)\bпродолжение\s+следует\b\.{0,3}…?"#,
            #"(?i)\bto\s+be\s+continued\b\.{0,3}…?"#,

            // 6. YouTube subscribe boilerplate. Specific multi-word framings
            //    only — bare «subscribe» can be a legit business word.
            #"(?i)\bподписывайтесь(\s+на\s+канал)?\b\.?"#,
            #"(?i)\bplease\s+like\s+and\s+subscribe\b\.?"#,
            #"(?i)\blike\s+and\s+subscribe\b\.?"#,
            #"(?i)\bplease\s+subscribe\b\.?"#,

            // 7. YouTube thanks-for-watching boilerplate
            #"(?i)\bспасибо\s+за\s+просмотр\b\.?"#,
            #"(?i)\bthanks?\s+for\s+watching\b\.?"#,

            // 8. Music notation runs
            "♪+",
            "♫+",

            // 9. amara.org standalone
            #"(?i)\bamara\.org\b"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Collapse multi-space + clean dangling punctuation pairs.
        if let r = try? NSRegularExpression(pattern: #"\s{2,}"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = r.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        // Fix « , » → « ,» and « . » → «. » left by mid-sentence removal.
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ?", with: "?")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAlwaysHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        let containsToxic = Self.toxicHallucinationTokens.contains { lower.contains($0) }
        if containsToxic {
            // ITER-035-followup #2 (2026-05-12) — split the decision.
            // SHORT text + toxic token = pure hallucination (Whisper emitted
            // «Subtitles by DimaTorzok» on silent audio and stopped). DROP.
            // LONG text + toxic token = real speech with the artifact spliced
            // mid-stream. We DON'T drop the whole thing — caller is expected
            // to call `stripHallucinationTokens(_:)` to surgically remove the
            // artifact substring and pass the cleaned remainder through to
            // TextProcessor. Returning `false` here means «not all-hallucination»,
            // not «no cleanup needed».
            return text.count < 200
        }
        // Text is ONLY "субтитры" + attribution (no real speech content)
        if lower.hasPrefix("субтитры") && text.count < 60 { return true }
        if lower.hasPrefix("subtitles") && text.count < 60 { return true }

        // Multi-script gibberish: real speech doesn't mix 3+ Unicode scripts.
        // Whisper hallucinations often produce Cyrillic+Latin+CJK+Greek mush.
        if isMixedScriptGibberish(text) { return true }

        // NOTE (2026-05-01): excessive phrase repetition USED to fire here as
        // an always-discard. Bug report: user dictates 30s, pauses 3s mid-speech
        // to think, Whisper hallucinates "ну и комьюнити ну и комьюнити …" in
        // the silence. The repetition check fired on the COMBINED text (real
        // prefix + hallucinated loop + real suffix) → entire dictation
        // discarded, clipboard empty, animation looked normal. User lost real
        // words to a false positive. Moved into `isHallucination` (silence-only
        // path) so the check only fires when the audio was actually quiet —
        // real speech with a momentary internal pause survives.
        return false
    }

    /// Detect Whisper repetition-loop hallucinations. Three independent checks:
    /// 1. Any 3-word phrase repeats 3+ times across the text
    /// 2. Any 2-word phrase (with at least one ≥4-char word) repeats 4+ times
    /// 3. Any single word repeats 5+ times CONSECUTIVELY
    /// Real speech rarely triggers any of these — they're characteristic of
    /// Whisper getting stuck in a generation loop on uncertain audio.
    nonisolated static func containsExcessivePhraseRepetition(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 6 else { return false }

        // Check 3-grams.
        var trigramCounts: [String: Int] = [:]
        for i in 0...(words.count - 3) {
            let trigram = "\(words[i]) \(words[i+1]) \(words[i+2])"
            trigramCounts[trigram, default: 0] += 1
        }
        if trigramCounts.values.contains(where: { $0 >= 3 }) { return true }

        // Check 2-grams (skip noise pairs like "и я").
        var bigramCounts: [String: Int] = [:]
        for i in 0...(words.count - 2) {
            let w1 = words[i], w2 = words[i+1]
            if w1.count < 4 && w2.count < 4 { continue }
            let bigram = "\(w1) \(w2)"
            bigramCounts[bigram, default: 0] += 1
        }
        if bigramCounts.values.contains(where: { $0 >= 4 }) { return true }

        // Single-word consecutive run.
        var current = ""
        var run = 0
        for word in words {
            if word == current {
                run += 1
                if run >= 5 { return true }
            } else {
                current = word
                run = 1
            }
        }

        return false
    }

    /// Detect multi-script gibberish — text mixing 3+ distinct Unicode scripts.
    /// Normal bilingual speech mixes at most 2 scripts (e.g. Cyrillic + Latin for brands).
    private static func isMixedScriptGibberish(_ text: String) -> Bool {
        var hasLatin = false
        var hasCyrillic = false
        var hasCJK = false       // Chinese/Japanese/Korean ideographs
        var hasHangul = false     // Korean
        var hasGreek = false
        var hasArabic = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x024F: hasLatin = true     // Basic Latin + Extended
            case 0x0400...0x04FF: hasCyrillic = true  // Cyrillic
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: hasCJK = true  // CJK Unified
            case 0x3040...0x30FF: hasCJK = true       // Hiragana + Katakana
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hasHangul = true // Hangul
            case 0x0370...0x03FF: hasGreek = true     // Greek
            case 0x0600...0x06FF: hasArabic = true    // Arabic
            default: break
            }
        }

        let scriptCount = [hasLatin, hasCyrillic, hasCJK, hasHangul, hasGreek, hasArabic]
            .filter { $0 }.count
        return scriptCount >= 3
    }

    /// Detect common Whisper hallucinations (generated from silence/noise).
    /// IMPORTANT: Only called on near-silence audio (RMS < 0.008).
    /// Uses strict matching — short texts must be primarily a hallucination phrase,
    /// not just contain a keyword (the user might actually say "music" or "subscribe").
    /// Exposed internally so meeting recording can reuse the same filter.
    static func isHallucination(_ text: String) -> Bool {
        // Phrase-repetition loop check — moved here from `isAlwaysHallucination`
        // 2026-05-01. Only fires on low-RMS audio (caller gates), so real
        // dictation with brief internal pauses isn't punished.
        if containsExcessivePhraseRepetition(text) { return true }

        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        // Exact-match hallucinations — text IS the hallucination (with minor variations)
        let exactPatterns = [
            "субтитры", "субтитры сделал", "субтитры от",
            "subtitles", "subtitles by",
            "подписывайтесь", "подписывайтесь на канал",
            "subscribe", "please subscribe",
            "thanks for watching", "thank you for watching",
            "спасибо за просмотр",
            "продолжение следует", "to be continued",
            "музыка", "music",
            "amara.org",
        ]

        for pattern in exactPatterns {
            // Match if text is just the pattern (possibly with minor prefix/suffix)
            if lower == pattern || lower.hasPrefix(pattern + " ") || lower.hasSuffix(" " + pattern) {
                return true
            }
        }

        // Always-hallucination tokens
        let alwaysFilter = ["♪", "♫", "торзок", "torzok", "торжок", "dimatorzok", "dima torzok"]
        for pattern in alwaysFilter {
            if lower.contains(pattern) { return true }
        }

        // Repeated short phrases are hallucinations (e.g. "..." or "Так. Так. Так.")
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 3 {
            let unique = Set(words.map { $0.lowercased() })
            if unique.count == 1 { return true } // All same word repeated
        }

        // Very short + all punctuation = hallucination
        let stripped = text.replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
        if stripped.count < 2 { return true }

        return false
    }
}
