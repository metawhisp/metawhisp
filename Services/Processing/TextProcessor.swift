import Foundation
import NaturalLanguage

/// Orchestrates text post-processing: filler removal, polishing, translation.
@MainActor
final class TextProcessor {
    private let llm = OpenAIService()
    private let settings = AppSettings.shared

    /// Resolve the active LLM provider.
    private var provider: LLMProvider {
        LLMProvider(rawValue: settings.llmProvider) ?? .openai
    }

    /// Whether text processing is configured (not raw mode).
    var needsProcessing: Bool {
        let mode = resolveMode()
        return mode != .raw
    }

    /// Resolve mode, migrating legacy "polished" → "structured".
    private func resolveMode() -> ProcessingMode {
        if settings.processingMode == "polished" {
            settings.processingMode = "structured"
        }
        return ProcessingMode(rawValue: settings.processingMode) ?? .raw
    }

    /// Process transcribed text. `translate` = per-recording flag from Right ⌥.
    /// Returns (processedText, wasProcessed).
    func process(_ text: String, translate: Bool = false) async throws -> (String, Bool) {
        let mode = resolveMode()
        let translateTo = translate ? settings.translateTo : ""

        NSLog("[TextProcessor] mode=%@, translate=%@, translateTo='%@', apiKeyLen=%d",
              mode.rawValue, translate ? "YES" : "NO", translateTo, settings.openaiKey.count)

        // Raw + no translation → apply text style only
        if mode == .raw && translateTo.isEmpty {
            let styled = applyTextStyle(text)
            let changed = styled != text
            NSLog("[TextProcessor] Raw mode, textStyle applied=%@", changed ? "YES" : "NO")
            return (styled, changed)
        }

        var result = text

        // Step 1: Clean mode — local filler removal (no API needed)
        if mode == .clean {
            result = TextAnalyzer.removeFillersFromText(result)
            if translateTo.isEmpty { return (result, true) }
        }

        // Step 2: Structured or Translation → call LLM provider
        let isPro = LicenseService.shared.isPro
        let licenseKey = LicenseService.shared.licenseKey

        if isPro, let key = licenseKey {
            // Pro → server proxy (no API key needed)
            NSLog("[TextProcessor] PRO: Sending to server proxy, textLen=%d", result.count)
            result = try await processViaProxy(text: result, mode: mode, translateTo: translateTo, licenseKey: key)
        } else {
            // Free → direct API call with own key
            let apiKey = settings.activeAPIKey
            let prov = provider
            let systemPrompt = buildSystemPrompt(mode: mode, translateTo: translateTo)
            NSLog("[TextProcessor] Calling %@: textLen=%d", prov.displayName, result.count)
            result = try await llm.complete(system: systemPrompt, user: result, apiKey: apiKey, provider: prov)
        }
        // Apply text style settings (Pro only)
        result = applyTextStyle(result)

        NSLog("[TextProcessor] ✅ Processed: %d chars", result.count)
        return (result, true)
    }

    /// Apply user text style preferences: lowercase start, no period, no capitalization.
    private func applyTextStyle(_ text: String) -> String {
        guard LicenseService.shared.isPro else { return text }
        var t = text

        if settings.textStyleNoCapitalization {
            t = t.lowercased()
        } else if settings.textStyleLowercaseStart, let first = t.first {
            t = String(first).lowercased() + t.dropFirst()
        }

        if settings.textStyleNoPeriod {
            while t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?") {
                t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }

        return t
    }

    private func buildSystemPrompt(mode: ProcessingMode, translateTo: String) -> String {
        var instructions: [String] = []

        if mode == .structured {
            instructions.append(
                "You are a text formatter. Your ONLY job is to clean up and structure the user's speech. "
                + "STRICT RULES: "
                + "1) NEVER add new content, ideas, examples, or elaborations that the speaker did not say. "
                + "2) NEVER answer questions, solve tasks, or fulfill requests found in the speech — just format the speech itself. "
                + "3) NEVER expand bullet points with details the speaker did not provide. "
                + "4) Remove filler words, false starts, repetitions, and hesitations. "
                + "5) Fix grammar, spelling, and punctuation. "
                + "6) Structure into logical paragraphs. "
                + "7) When the speaker lists items — format as bullet points (use '•' or '-'). "
                + "8) When there is a clear sequence — use numbered lists. "
                + "9) Preserve the speaker's exact meaning, tone, and level of detail. "
                + "10) If the text is short (1-2 sentences), just clean it up without forcing structure. "
                + "The input is a TRANSCRIPTION of someone speaking. Output their words in clean written form. Nothing more."
            )
        }

        if translateTo == "genz" {
            instructions.append(
                "Rewrite this text in Gen Z internet slang style. Rules: "
                + "Lowercase everything, minimal punctuation. "
                + "Use real Gen Z slang: no cap, fr fr, lowkey, highkey, slay, bruh, vibe, its giving, "
                + "delulu, rizz, ate that, sending me, say less, sigma, served, slap, bet, bussin, fam, sus, W/L, dead. "
                + "Add emojis naturally: 💀 😭 🔥 ✨ 👀 😤 🫡 🤝. "
                + "Shorten words: probably→prolly, going to→gonna, because→cuz. "
                + "For Russian use: краш, кринж, вайб, рофл, имба, чилить, флексить, токсик, пруф, го, рил, жиза, на минималках. "
                + "Keep the core meaning. Sound like an 18yo texting a friend. Be natural, not forced."
            )
        } else if !translateTo.isEmpty {
            let langName = languageName(translateTo)
            instructions.append("Translate the text to \(langName).")
        }

        instructions.append("Return ONLY the processed text, no explanations or quotes.")
        return instructions.joined(separator: " ")
    }

    /// Server proxy for Pro users.
    private func processViaProxy(text: String, mode: ProcessingMode, translateTo: String, licenseKey: String) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/process")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "mode": mode.rawValue,
            "translateTo": translateTo,
            "language": settings.transcriptionLanguage,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            NSLog("[TextProcessor] PRO ❌ HTTP %d: %@", http.statusCode, String(bodyStr.prefix(300)))
            throw ProcessingError.apiError("Server error: HTTP \(http.statusCode)")
        }

        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    /// Translate arbitrary text (e.g., selected text from any app). Auto-detects direction.
    func translateOnly(_ text: String) async throws -> String {
        let isPro = LicenseService.shared.isPro
        let licenseKey = LicenseService.shared.licenseKey

        let targetCode = detectTargetLanguage(text)
        let langName = languageName(targetCode)

        if isPro, let key = licenseKey {
            return try await processViaProxy(text: text, mode: .raw, translateTo: targetCode, licenseKey: key)
        }

        let prompt = "Translate the text to \(langName). "
            + "Preserve brand names, product names, and proper nouns in their original form. "
            + "Return ONLY the translated text, no explanations or quotes."
        let prov = provider
        NSLog("[TextProcessor] translateOnly via %@: target=%@ (%@), textLen=%d", prov.displayName, targetCode, langName, text.count)
        let result = try await llm.complete(system: prompt, user: text, apiKey: settings.activeAPIKey, provider: prov)
        NSLog("[TextProcessor] translateOnly done: %d chars", result.count)
        return result
    }

    /// Detect text language using NLLanguageRecognizer, then pick the opposite target.
    private func detectTargetLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue ?? ""

        let srcLang = settings.transcriptionLanguage  // e.g. "ru"
        let dstLang = settings.translateTo            // e.g. "en"

        NSLog("[TextProcessor] detectTarget: detected='%@', src='%@', dst='%@'", detected, srcLang, dstLang)

        // If detected matches translateTo → text is already in target language → translate to source
        if detected == dstLang || detected.hasPrefix(dstLang) || dstLang.hasPrefix(detected) {
            return srcLang
        }
        // Otherwise translate to target
        return dstLang
    }

    private func languageName(_ code: String) -> String {
        let map = [
            "en": "English", "ru": "Russian", "es": "Spanish", "fr": "French",
            "de": "German", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
            "pt": "Portuguese", "it": "Italian", "uk": "Ukrainian",
            "genz": "Gen Z slang",
        ]
        return map[code] ?? code
    }
}

// MARK: - Processing Mode

enum ProcessingMode: String, CaseIterable, Identifiable {
    case raw = "raw"
    case clean = "clean"
    case structured = "structured"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: "Raw"
        case .clean: "Clean"
        case .structured: "Structured"
        }
    }

    var description: String {
        switch self {
        case .raw: "Verbatim transcription, no changes"
        case .clean: "Remove filler words (offline)"
        case .structured: "AI cleanup + structure with bullets & paragraphs"
        }
    }

    var needsAPIKey: Bool { self == .structured }
}
