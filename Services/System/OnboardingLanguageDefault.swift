import Foundation

/// The transcription language a new install runs on.
///
/// Onboarding used to ship with `transcriptionLanguage` hard-coded to `"ru"`
/// and no screen that mentioned it, so anyone who did not speak Russian got
/// their first dictation back in the wrong language with no explanation.
/// Whisper identifies the language on its own, so the flow no longer asks —
/// installs run on `auto`.
///
/// For a while a launch-time pin kept installs from before that change on
/// `"ru"`. The defaults cannot tell such an install from one that finished
/// onboarding on an `auto` build and was updated before its second launch, and
/// the two mistakes are not equal: a Russian speaker wrongly on `auto` gets
/// detection, an English speaker wrongly on `"ru"` gets broken dictation. So
/// nothing writes `"ru"` for anyone; a stored value — chosen or pinned by an
/// older build — is left as it is (step-1 review, #3).
enum OnboardingLanguageDefault {

    /// What an install runs on until the user picks a language.
    static let freshInstallDefault = "auto"
}
