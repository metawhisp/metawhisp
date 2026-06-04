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
    /// transcription; brand names in other languages are fixed post-hoc by
    /// `BrandGlossary.applyCorrections`.
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
}
