import Foundation

/// Protocol for transcription backends.
/// Inspired by TranscriptionSuite's STTBackend and TypeWhisper's engine pattern.
protocol TranscriptionEngine: AnyObject, Sendable {
    var name: String { get }
    var supportsStreaming: Bool { get }
    var supportsTranslation: Bool { get }
    var isModelLoaded: Bool { get }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws
    func unloadModel() async
    /// - Parameter countUsage: ITER-054 — when `false`, the Pro proxy transcribes
    ///   the audio but does NOT charge the user's minute quota. Used for the
    ///   SECOND channel of a meeting's dual-stream pass (mic + system): the
    ///   meeting's real length is billed once via the mic channel; the system
    ///   channel rides free so a 1-hour meeting costs 60 min, not 120. Ignored
    ///   by local engines (no billing). Default `true` — dictations bill normally.
    func transcribe(audioSamples: [Float], language: String?, promptWords: [String], countUsage: Bool) async throws -> TranscriptionResult
}

extension TranscriptionEngine {
    var supportsStreaming: Bool { false }
    var supportsTranslation: Bool { false }

    /// Convenience — bills usage (countUsage: true). Existing call sites resolve
    /// here; only the meeting system-channel opts out via the 4-arg form.
    func transcribe(audioSamples: [Float], language: String?, promptWords: [String]) async throws -> TranscriptionResult {
        try await transcribe(audioSamples: audioSamples, language: language, promptWords: promptWords, countUsage: true)
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioSamples: audioSamples, language: language, promptWords: [], countUsage: true)
    }
}
