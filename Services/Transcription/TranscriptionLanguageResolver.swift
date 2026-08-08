import Foundation

/// Pure, deterministic decisions for the transcription pipeline's language /
/// prompt handling. Extracted from `TranscriptionCoordinator.transcribe` and
/// `WhisperKitEngine.transcribe` so the Russian→English root-cause logic is
/// unit-testable, and fixed in one place for both the on-device and cloud engines.
enum TranscriptionLanguageResolver {

    /// Map the stored language setting to the value handed to the engine.
    /// `"auto"`, `""`, whitespace, or `nil` → `nil` (engine auto-detects);
    /// otherwise the trimmed language code.
    static func resolveLanguage(_ setting: String?) -> String? {
        guard let raw = setting?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "auto"
        else { return nil }
        return raw
    }

    /// Whether to inject the (English) brand glossary as a decoder prompt.
    ///
    /// The glossary is English-only, so feeding it as a Whisper/Groq
    /// `initial_prompt` biases language detection toward English — a root cause
    /// of Russian dictation coming out English. Only include it for English
    /// transcription.
    ///
    /// Trade-off (deliberate): on non-English audio the brand names get NO prompt
    /// bias, and post-hoc `BrandGlossary.applyCorrections` only repairs the
    /// *unambiguous* Cyrillic mangles it knows (currently just «Бриво»→Brevo);
    /// ambiguous ones (молчим→MailChimp, клод→Claude) are intentionally left
    /// alone. So a few brand names may stay mangled on RU audio — far cheaper than
    /// the whole transcript flipping to English, which injecting the glossary did.
    static func shouldIncludeBrandGlossary(language: String?) -> Bool {
        return (language ?? "").lowercased().hasPrefix("en")
    }

    /// WhisperKit `detectLanguage`. When no language is pinned, have WhisperKit
    /// DETECT the language of the audio instead of letting prefill default the
    /// decoder's language token to `<|en|>` (which transcribed Russian as
    /// English).
    ///
    /// IMPORTANT: per WhisperKit's own docs this MUST be paired with
    /// `usePrefillPrompt: true`. Turning prefill OFF (the earlier fix) instead
    /// left the decoder unseeded and returned EMPTY transcripts on some clips —
    /// keep prefill on, just flip detection on for auto.
    static func whisperDetectLanguage(language: String?) -> Bool {
        return language == nil
    }

    /// Post-processing translate target (`nil` = no translation). Only set when
    /// the per-recording translate flag (Right ⌥) is on AND a non-empty target
    /// is configured.
    static func resolveTranslateTarget(translateFlag: Bool, configuredTarget: String) -> String? {
        guard translateFlag else { return nil }
        let target = configuredTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    /// A prompt word is safe to inject regardless of language only if it contains
    /// a non-ASCII character (e.g. Cyrillic). Pure-ASCII/Latin tokens — English
    /// brand names like "Brevo"/"MailChimp" — are the ones that seed the decoder
    /// toward `<|en|>` and turn Russian speech into fluent English.
    ///
    /// Note: a *mixed* token (e.g. "Sтудия") passes on its single non-ASCII scalar
    /// even though it still carries Latin characters. That's acceptable: the
    /// dominant prompt source — the brand glossary — is 100% ASCII (so it's fully
    /// gated), and a mostly-Cyrillic token exerts only weak EN bias. The only mixed
    /// vector is user-defined correction-dictionary values, which is rare and minor.
    static func promptWordSafeForNonEnglish(_ word: String) -> Bool {
        return word.unicodeScalars.contains { $0.value > 0x007F }
    }

    /// Gate prompt words by the resolved language. English → keep all; any other
    /// language (or `auto`/nil) → keep only non-ASCII words, dropping the English
    /// brand tokens that cause the Russian→English regression. Applies uniformly
    /// to the brand glossary AND the correction-dictionary values (TR-3).
    static func filterPromptWords(_ words: [String], language: String?) -> [String] {
        if shouldIncludeBrandGlossary(language: language) { return words }
        return words.filter(promptWordSafeForNonEnglish)
    }

    /// The ONLY prompt words an engine may receive: the curated brand glossary,
    /// language-gated. The user's correction dictionary must NEVER be fed here —
    /// its values are output-side replacements applied by
    /// `CorrectionDictionary.apply` AFTER transcription. Handing them to the
    /// decoder as `initial_prompt` made Whisper echo the dictionary back
    /// verbatim as «recognized speech» on silent/noisy audio (prompt-echo bug,
    /// 2026-08-06: transcript = «линкбилдинг, Не наебывай, что и как, …»).
    static func enginePromptWords(language: String?) -> [String] {
        filterPromptWords(BrandGlossary.canonicalNames(), language: language)
    }

}
