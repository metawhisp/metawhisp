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
            return
        }

        NSLog("[Coordinator] Transcribing %d samples via %@...", samples.count, currentEngine.name)

        do {
            let lang = settings.transcriptionLanguage == "auto" ? nil : settings.transcriptionLanguage
            var promptWords = correctionDictionary.map { Array(Set($0.corrections.values)) } ?? []
            // Always include our brand in prompt to bias Whisper toward it
            promptWords.append("MetaWhisp")
            let result = try await currentEngine.transcribe(audioSamples: samples, language: lang, promptWords: promptWords)

            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                NSLog("[Coordinator] Empty result")
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
                NSLog("[Coordinator] ⚠️ Filtered hallucination (always): '%@'", String(trimmed.prefix(80)))
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
            // Phase 2: Pattern-match only on near-silence audio (RMS < 0.003).
            // Built-in MacBook mic: silence ~0.0005, quiet speech ~0.002, normal speech ~0.005+
            if rms < 0.003, Self.isHallucination(trimmed) {
                NSLog("[Coordinator] ⚠️ Filtered hallucination (RMS=%.4f): '%@'", rms, String(trimmed.prefix(80)))
                // Same recovery path — text on clipboard so user has the
                // option even on quiet-audio false positives.
                Self.saveSuspectToClipboard(trimmed)
                lastResult = result
                lastError = "Audio too quiet, but text saved to clipboard — ⌘V to paste anyway."
                abortVoiceQuestionIfActive(reason: "Audio too quiet for voice question.")
                stage = .idle
                return
            }

            lastResult = result
            NSLog("[Coordinator] ✅ lang=%@, %.2fs: %@", result.language ?? "?", result.processingTime, String(result.text.prefix(100)))

            // Post-process (translate / clean / polish) if needed
            var finalText = result.text
            var processedText: String?

            let needsProcess = (textProcessor?.needsProcessing ?? false) || shouldTranslate
            if let processor = textProcessor, needsProcess {
                stage = .postProcessing
                do {
                    let (processed, wasProcessed) = try await processor.process(result.text, translate: shouldTranslate)
                    if wasProcessed {
                        finalText = processed
                        processedText = processed
                        NSLog("[Coordinator] ✅ Post-processed: %@", String(processed.prefix(100)))
                    }
                } catch {
                    NSLog("[Coordinator] ⚠️ Post-processing failed: %@", error.localizedDescription)
                    lastError = error.localizedDescription
                }
            }

            // Save to history (with processed text if available).
            if let hs = historyService {
                let item = hs.save(result)
                item?.processedText = processedText
                item?.translatedTo = shouldTranslate ? settings.translateTo : nil
                item?.modelName = settings.selectedModel
                item?.source = audioSourceLabel
                // Assign to Conversation (C1.1) — sets conversationId on the item.
                if let item {
                    conversationGrouper?.assign(historyItem: item)
                    // ITER-035 v2 — export this dictation as a markdown file
                    // in the user's Obsidian vault. Fire-and-forget;
                    // ObsidianExporter handles all gates (sync enabled, path
                    // valid, etc) and silently no-ops otherwise.
                    if let exporter = obsidianExporter {
                        let itemID = item.id
                        Task { @MainActor in
                            await exporter.exportHistoryItem(itemID)
                        }
                    }
                }
            }

            // Apply learned corrections (before paste, after all processing)
            if let dict = correctionDictionary {
                let corrected = dict.apply(finalText)
                if corrected != finalText {
                    NSLog("[Coordinator] 📝 Applied corrections: %@", String(corrected.prefix(80)))
                    finalText = corrected
                }
            }

            // Voice question mode (Phase 6) — route to MetaChat instead of clipboard paste.
            if voiceQuestionMode {
                voiceQuestionMode = false
                NSLog("[Coordinator] 🎤 Voice question transcript → MetaChat: %@", String(finalText.prefix(80)))
                VoiceQuestionState.shared.thinking(transcript: finalText)
                if let chat = chatService {
                    Task { await chat.send(finalText, source: .voice) }
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
    static func saveSamplesAsWav(_ samples: [Float]) -> URL? {
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
        let url = dir.appendingPathComponent("recording-\(stamp).wav")

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
    static func isAlwaysHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        let toxicTokens = [
            "♪", "♫", "торзок", "torzok", "dimatorzok", "dima torzok",
            "amara.org", "переводчик:", "translator:",
        ]
        // ITER-035-followup (2026-05-12) — long-form mention safety net.
        // Hallucinations from silence are SHORT — Whisper emits a tag like
        // «Subtitles by DimaTorzok» on quiet audio and stops. A 1000-char
        // dictation that mentions the same name MID-TEXT is the user
        // referencing the artifact, not the artifact itself. User report:
        // user dictated «и Дима Торзок ебаный опять вылез» → filter
        // greedy-matched on the substring → entire 1084-char dictation
        // discarded → user pasted clipboard raw without structured cleanup.
        // 200 chars chosen as the upper bound of typical hallucination
        // verbiage; real long-form dictation always exceeds this.
        let isLongForm = text.count >= 200
        for token in toxicTokens {
            if lower.contains(token) {
                if isLongForm {
                    // Long real speech — keep, process normally. Caller
                    // gets the verbatim text; TextProcessor still runs.
                    continue
                }
                return true
            }
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
    static func containsExcessivePhraseRepetition(_ text: String) -> Bool {
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
