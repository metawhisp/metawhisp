import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let segments: [Segment]

    struct Segment: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        // Decode-confidence metrics, when the engine/provider supplies them
        // (WhisperKit per-window; cloud `verbose_json`). `nil` → unknown, so the
        // confidence gate keeps the segment (absence of evidence ≠ hallucination).
        // Defaults keep every existing `Segment(text:start:end:)` call site intact.
        var avgLogprob: Float? = nil
        var compressionRatio: Float? = nil
        var noSpeechProb: Float? = nil
    }
}
