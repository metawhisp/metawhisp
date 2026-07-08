import Foundation

/// ITER-044 — pure, OS-independent support types for the Apple Foundation
/// Models backend. Deliberately free of any `import FoundationModels` symbol so
/// this file compiles and is unit-testable on ANY macOS (the FM framework only
/// exists on macOS 26+). The availability-gated inference code lives in
/// `LocalLLMService.swift` under `@available(macOS 26, *)`; it translates
/// Apple's real `SystemLanguageModel.Availability.UnavailableReason` into the
/// `FMUnavailableReason` mirror below and reuses `message(for:)` for the
/// user-facing copy.

/// Which inference backend `LocalLLMService` routes a request through. A plain
/// enum with no availability annotation — safe to store as a property on the
/// macOS-14-deployment `LocalLLMService` (I2: no FM symbol crosses the < 26
/// boundary).
enum LocalLLMBackend: Equatable {
    case mlx
    case foundationModels
}

/// OS-independent mirror of `SystemLanguageModel.Availability.UnavailableReason`
/// (macOS 26+). Kept separate so the reason → user-message mapping is testable
/// without a macOS 26 SDK/runtime.
enum FMUnavailableReason: Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

enum FoundationModelsSupport {

    /// Backend routing decision for a model card. Foundation Models specs run
    /// through Apple's on-device framework; everything else through MLX.
    static func backend(for spec: ModelSpec) -> LocalLLMBackend {
        spec.isFoundationModels ? .foundationModels : .mlx
    }

    /// User-facing explanation when Apple Foundation Models can't serve. Each
    /// reason maps to a distinct, actionable sentence (I3: the app falls back
    /// to cloud, but the user still learns WHY the local path is off).
    static func message(for reason: FMUnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, so Apple Foundation Models isn't available. Pick a downloadable model instead."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to use Apple Foundation Models."
        case .modelNotReady:
            return "Apple Foundation Models is still downloading in the background. Try again in a few minutes."
        }
    }
}
