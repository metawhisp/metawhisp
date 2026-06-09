import Foundation

/// Pure readiness decision for onboarding's transcription-setup step.
///
/// Fixes the out-of-the-box bug where onboarding could finish with no working
/// engine (fake model "download", read-only API-key field) — the user then hit
/// Right ⌘ and got "No model loaded". A path counts as ready ONLY when a real
/// engine will actually transcribe.
enum OnboardingReadiness {

    /// Which transcription path the user picked on the setup page.
    enum Path: Equatable {
        case local   // on-device WhisperKit model
        case cloud   // bring-your-own-key, or the Pro proxy (both use the cloud engine)
    }

    /// Ready iff the chosen path can transcribe right now:
    /// - `.local` → the on-device model is loaded and ready (not just on disk);
    /// - `.cloud` → a validated API key is present, or Pro covers cloud.
    static func isReady(
        path: Path,
        localModelReady: Bool,
        cloudKeyValidated: Bool,
        isPro: Bool
    ) -> Bool {
        switch path {
        case .local: return localModelReady
        case .cloud: return cloudKeyValidated || isPro
        }
    }
}
