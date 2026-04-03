import Foundation
import WhisperKit

/// WhisperKit-based transcription engine. Runs entirely on-device using Metal.
final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit"
    let supportsStreaming = false
    let supportsTranslation = true

    private var whisperKit: WhisperKit?
    private let lock = NSLock()

    var isModelLoaded: Bool {
        lock.withLock { whisperKit != nil }
    }

    /// Load a model by its variant name (e.g. "openai_whisper-large-v3_turbo").
    func loadModel(_ variant: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        let config = WhisperKitConfig(
            model: variant,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            ),
            verbose: false
        )

        let kit = try await WhisperKit(config)

        lock.withLock {
            self.whisperKit = kit
        }
    }

    func unloadModel() async {
        lock.withLock {
            self.whisperKit = nil
        }
    }

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String] = []) async throws -> TranscriptionResult {
        guard let kit = lock.withLock({ whisperKit }) else {
            throw TranscriptionError.modelNotLoaded
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let lang = (language == nil || language == "auto") ? nil : language

        // Encode dictionary words as prompt tokens for better recognition
        var promptTokens: [Int]?
        if !promptWords.isEmpty, let tokenizer = kit.tokenizer {
            let promptText = promptWords.joined(separator: ", ")
            let tokens = tokenizer.encode(text: " " + promptText).filter {
                $0 < tokenizer.specialTokens.specialTokenBegin
            }
            if !tokens.isEmpty {
                promptTokens = tokens
                NSLog("[WhisperKit] 📖 Prompt: %d words → %d tokens (%@)", promptWords.count, tokens.count, String(promptText.prefix(80)))
            }
        }

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0,
            usePrefillPrompt: lang != nil || promptTokens != nil,
            usePrefillCache: lang != nil,
            skipSpecialTokens: true,
            wordTimestamps: false,
            promptTokens: promptTokens,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )

        let results = try await kit.transcribe(
            audioArray: audioSamples,
            decodeOptions: decodingOptions
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(audioSamples.count) / 16000.0

        // Combine all result segments, cleaning hallucinated tails
        let allTexts = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var cleaned: [String] = []
        for (i, t) in allTexts.enumerated() {
            let result = Self.cleanHallucinations(t)
            if result.isEmpty {
                NSLog("[WhisperKit]   [%d] ❌ dropped (hallucination): '%@'", i, String(t.prefix(200)))
            } else if result != t {
                NSLog("[WhisperKit]   [%d] ✂️ trimmed tail: '%@'", i, String(result.suffix(60)))
                cleaned.append(result)
            } else {
                cleaned.append(result)
            }
        }

        // Deduplicate consecutive repeated segments
        var deduped: [String] = []
        for segment in cleaned {
            let norm = segment.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = deduped.last,
               last.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == norm {
                NSLog("[WhisperKit] ❌ dropped duplicate segment: '%@'", String(segment.prefix(100)))
                continue
            }
            deduped.append(segment)
        }

        if allTexts.count != deduped.count {
            NSLog("[WhisperKit] Segments: %d total, %d after hallucination+dedup filter", allTexts.count, deduped.count)
        }

        let text = deduped.joined(separator: " ")

        let segments = results.map { result in
            TranscriptionResult.Segment(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                start: TimeInterval(result.segments.first?.start ?? 0),
                end: TimeInterval(result.segments.last?.end ?? Float(audioDuration))
            )
        }

        let detectedLanguage = results.first?.language

        return TranscriptionResult(
            text: text,
            language: detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            segments: segments
        )
    }

    // MARK: - Hallucination Filter

    /// Common Whisper hallucination patterns (repeated phrases, music cues, etc.)
    private static let hallucinationPatterns: [String] = [
        "продолжение следует", "подписывайтесь на канал", "ставьте лайк",
        "спасибо за просмотр", "спасибо за внимание", "до новых встреч",
        "субтитры", "субтитры сделал", "спасибо за субтитры",
        "редактор субтитров", "титры",
        "thanks for watching", "thank you for watching", "subscribe",
        "please like and subscribe", "subtitles by", "subtitles",
        "translated by", "subs by", "music", "♪",
    ]

    /// Clean hallucinations: if text IS a hallucination → return empty.
    /// If text ENDS with a hallucination phrase → trim it off, keep the real part.
    private static func cleanHallucinations(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.isEmpty { return "" }

        // Pure repeated characters (e.g. "ааааа", "........")
        let unique = Set(lower.filter { !$0.isWhitespace && !$0.isPunctuation })
        if unique.count <= 2 && lower.count > 3 { return "" }

        // Repeated phrase within segment (e.g. "Субтитры сделал X Субтитры сделал X")
        let words = trimmed.split(separator: " ")
        if words.count >= 6 {
            for len in stride(from: words.count / 2, through: 3, by: -1) {
                let chunk = words[0..<len].joined(separator: " ").lowercased()
                let rest = words[len...].joined(separator: " ").lowercased()
                if rest.hasPrefix(chunk) {
                    for p in hallucinationPatterns where chunk.contains(p) { return "" }
                    return words[0..<len].joined(separator: " ")
                }
            }
        }

        // If the ENTIRE text is a hallucination phrase → drop
        for pattern in hallucinationPatterns {
            if lower == pattern { return "" }
        }

        // If text ENDS with a hallucination phrase → trim the tail, keep the rest
        var result = trimmed
        for pattern in hallucinationPatterns {
            if let range = result.lowercased().range(of: pattern, options: .backwards) {
                // Only trim if the hallucination is in the last 30% of text
                let pos = result.distance(from: result.startIndex, to: range.lowerBound)
                if pos > result.count / 2 {
                    result = String(result[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return result
    }

}

// Shared transcription errors (used by WhisperKitEngine + CloudWhisperEngine)
enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "No model loaded. Download a model first."
        case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
        }
    }
}
