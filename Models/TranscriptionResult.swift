import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let segments: [Segment]
    /// Transcribed through the Pro proxy — MetaWhisp's server — not on this Mac nor on the user's own key: what a
    /// meeting books, chunk by chunk (`MeetingBooking`). Only the cloud engine's proxy path sets it.
    var viaProProxy = false

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
