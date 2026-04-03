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
    func transcribe(audioSamples: [Float], language: String?, promptWords: [String]) async throws -> TranscriptionResult
}

extension TranscriptionEngine {
    var supportsStreaming: Bool { false }
    var supportsTranslation: Bool { false }

    func transcribe(audioSamples: [Float], language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioSamples: audioSamples, language: language, promptWords: [])
    }
}
