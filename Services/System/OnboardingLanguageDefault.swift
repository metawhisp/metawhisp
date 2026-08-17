import Foundation

/// Decides who keeps the old transcription language when the default moves.
///
/// Onboarding used to ship with `transcriptionLanguage` hard-coded to `"ru"`
/// and no screen that mentioned it, so anyone who did not speak Russian got
/// their first dictation back in the wrong language with no explanation.
/// Whisper identifies the language on its own, so the flow no longer asks —
/// fresh installs simply run on `auto`.
///
/// `@AppStorage` only writes a key once something assigns it, so a long-time
/// user who never opened that setting has nothing stored and is running on the
/// code default. Moving that default would silently change their behaviour
/// too. This pins them to `"ru"` first; everyone with an explicit choice is
/// left strictly alone.
enum OnboardingLanguageDefault {

    /// What a brand-new install runs on.
    static let freshInstallDefault = "auto"

    /// The value to write into storage, or `nil` when nothing should be written.
    ///
    /// - Parameters:
    ///   - storedLanguage: the value already in `UserDefaults`, `nil` when the
    ///     key has never been assigned.
    ///   - hasCompletedOnboarding: true for someone who has used the app before.
    static func valueToPersist(
        storedLanguage: String?,
        hasCompletedOnboarding: Bool
    ) -> String? {
        // An explicit choice — including an empty string someone managed to
        // store — is theirs, not ours.
        guard storedLanguage == nil else { return nil }
        // Never onboarded: the new default applies on its own.
        guard hasCompletedOnboarding else { return nil }
        return "ru"
    }
}
