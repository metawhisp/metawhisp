import AppKit
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
        }
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        // Capture & reset translate flag immediately — prevents leaking to next recording
        let shouldTranslate = translateNext
        translateNext = false
        stage = .processing
        soundService.playStop()
        NSLog("[Coordinator] Recording stopped, %d samples, translate=%@", samples.count, shouldTranslate ? "YES" : "NO")

        // Discard accidental triggers (< 0.3s of audio = 4800 samples at 16kHz)
        guard samples.count > 4800 else {
            NSLog("[Coordinator] Too short (%d samples), discarding", samples.count)
            stage = .idle
            return
        }

        // Silence detection: check if audio has enough energy to contain speech
        // Built-in MacBook mic: silence ~0.0002, quiet speech ~0.0005-0.002, normal ~0.003+
        // Threshold lowered to avoid dropping real speech recorded quietly
        let rms = Self.calculateRMS(samples)
        if rms < 0.0003 {
            NSLog("[Coordinator] Audio too quiet (RMS=%.5f), skipping transcription", rms)
            stage = .idle
            return
        }

        Task {
            await transcribe(samples: samples, shouldTranslate: shouldTranslate, rms: rms)
        }
    }

    private func transcribe(samples: [Float], shouldTranslate: Bool, rms: Float) async {
        guard let currentEngine = activeEngine, currentEngine.isModelLoaded else {
            lastError = settings.transcriptionEngine == "cloud" ? "API key not set for cloud transcription" : "No model loaded. Go to Settings to download one."
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
                stage = .idle
                return
            }

            // Filter Whisper hallucinations.
            // Phase 1: Always-filter toxic tokens (YouTube artifacts) regardless of RMS.
            if Self.isAlwaysHallucination(trimmed) {
                NSLog("[Coordinator] ⚠️ Filtered hallucination (always): '%@'", String(trimmed.prefix(80)))
                stage = .idle
                return
            }
            // Phase 2: Pattern-match only on near-silence audio (RMS < 0.003).
            // Built-in MacBook mic: silence ~0.0005, quiet speech ~0.002, normal speech ~0.005+
            if rms < 0.003, Self.isHallucination(trimmed) {
                NSLog("[Coordinator] ⚠️ Filtered hallucination (RMS=%.4f): '%@'", rms, String(trimmed.prefix(80)))
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
            // Keep the saved item reference so downstream triggers can link back via transcriptId + conversationId.
            var savedItemId: UUID? = nil
            var savedConvId: UUID? = nil
            if let hs = historyService {
                let item = hs.save(result)
                item?.processedText = processedText
                item?.translatedTo = shouldTranslate ? settings.translateTo : nil
                item?.modelName = settings.selectedModel
                item?.source = audioSourceLabel
                savedItemId = item?.id
                // Assign to Conversation (C1.1) — sets conversationId on the item.
                if let item {
                    conversationGrouper?.assign(historyItem: item)
                    savedConvId = item.conversationId
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
                let autoPasted = textInserter.insert(text: finalText)
                if !autoPasted {
                    lastError = "Copied to clipboard — press ⌘V to paste"
                }
                // Start monitoring for user corrections (auto-learn)
                if autoPasted { correctionMonitor?.startMonitoring(pastedText: finalText) }
            }

            // Fire memory + task triggers on meaningful transcripts (≥20 chars).
            // Both now carry conversationId FK so downstream records link back to the Conversation (C1.3).
            if finalText.count >= 20 {
                memoryExtractor?.triggerOnTranscription(text: finalText, source: audioSourceLabel, conversationId: savedConvId)
                taskExtractor?.triggerOnTranscription(text: finalText, source: audioSourceLabel, transcriptId: savedItemId, conversationId: savedConvId)
            }

            soundService.playSuccess()
            stage = .idle

        } catch {
            lastError = error.localizedDescription
            NSLog("[Coordinator] ❌ Transcription failed: %@", error.localizedDescription)
            soundService.playError()
            stage = .idle
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
        for token in toxicTokens {
            if lower.contains(token) { return true }
        }
        // Text is ONLY "субтитры" + attribution (no real speech content)
        if lower.hasPrefix("субтитры") && text.count < 60 { return true }
        if lower.hasPrefix("subtitles") && text.count < 60 { return true }

        // Multi-script gibberish: real speech doesn't mix 3+ Unicode scripts.
        // Whisper hallucinations often produce Cyrillic+Latin+CJK+Greek mush.
        if isMixedScriptGibberish(text) { return true }

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
