import Foundation

/// Onboarding's notes about the transcription setup. Whether a path can
/// transcribe at all is `ModelPreparer.state` (C5).
enum OnboardingReadiness {

    /// TR-7 (ITER-046 C2): warning shown when the user picks the Tiny model with
    /// a non-English transcription language ("auto" included — the user may well
    /// speak Russian). Tiny's hallucination rate outside English is catastrophic;
    /// a new user choosing "FAST" would get garbage as their first experience.
    /// Informative, not blocking — the choice stays theirs.
    static func tinyModelWarning(modelId: String, transcriptionLanguage: String) -> String? {
        guard modelId == "tiny" else { return nil }
        guard !transcriptionLanguage.lowercased().hasPrefix("en") else { return nil }
        return "Tiny is English-only quality — other languages get heavy transcription errors. Large V3 Turbo is strongly recommended."
    }
}
