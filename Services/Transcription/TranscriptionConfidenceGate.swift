import Foundation

/// Pure, precision-first confidence gate for transcription (Iteration B / TR-5).
///
/// Whisper's decoder has logprob / compression / no-speech thresholds, but a
/// failed decode retries at higher temperatures and — once the fallback budget is
/// spent — returns the last attempt **unconditionally**, even though it failed.
/// That escaped attempt is the "fluent hallucination" (invented sentences over
/// silence, looped phrases). This gate re-judges by those metrics.
///
/// Design constraints learned from review (all verified against source):
/// - On-device, WhisperKit assigns the SAME window-level metric to every segment
///   in a VAD window (SegmentSeeker) and hardcodes `noSpeechProb = 0`, so there is
///   no per-segment averaging cushion and the silence branch is inert locally.
/// - The owner layers apply this gate where recovery exists (dictation → clipboard,
///   meeting → drop+log), so the engines never blank text and never lose speech.
///
/// Hence: **precision-first** thresholds with headroom below Whisper's own values
/// so real-but-hard audio is not deleted, and the repetition branch is paired with
/// low confidence so legitimately repetitive speech ("раз, два, три", "да да да")
/// — which decodes with GOOD confidence — survives.
enum TranscriptionConfidenceGate {

    /// Confidence floor for a bare low-confidence drop. Headroom below Whisper's
    /// own −1.0 fallback trigger: it's a FINAL filter (not a retry trigger) with no
    /// averaging cushion on-device, so we only drop clearly-bad decodes.
    static let logProbFloor: Float = -1.5
    /// Looser confidence used only when PAIRED with high compression (repetition).
    static let repetitionLogProbCeil: Float = -0.5
    /// Compression above natural language — but only meaningful alongside low conf.
    static let compressionRatioThreshold: Float = 2.4
    /// No-speech cutoff for the silence branch (AND-guarded with low confidence).
    /// Only effective on the cloud path; WhisperKit reports 0 here (SDK TODO).
    static let noSpeechThreshold: Float = 0.5
    /// Confidence used inside the silence branch (kept at Whisper's −1.0 because the
    /// high no-speech AND-guard already makes it precise).
    static let silenceLogProbCeil: Float = -1.0

    struct Metrics: Equatable {
        let avgLogprob: Float
        let compressionRatio: Float
        let noSpeechProb: Float
    }

    /// A short human-readable reason to drop, or `nil` to keep. `nil` metrics
    /// (provider didn't supply stats) → keep.
    static func rejectionReason(_ metrics: Metrics?) -> String? {
        guard let m = metrics else { return nil }

        // Invented speech over silence: mostly no-speech AND low confidence.
        if m.noSpeechProb > noSpeechThreshold && m.avgLogprob < silenceLogProbCeil {
            return String(format: "silence (noSpeech=%.2f, logProb=%.2f)", m.noSpeechProb, m.avgLogprob)
        }
        // Pathological repetition: high compression PAIRED with low confidence, so
        // clean repetitive dictation (good logProb) is NOT dropped.
        if m.compressionRatio > compressionRatioThreshold && m.avgLogprob < repetitionLogProbCeil {
            return String(format: "repetition (compression=%.2f, logProb=%.2f)", m.compressionRatio, m.avgLogprob)
        }
        // Clearly low-confidence decode (with headroom below Whisper's −1.0).
        if m.avgLogprob < logProbFloor {
            return String(format: "low confidence (logProb=%.2f)", m.avgLogprob)
        }
        return nil
    }

    // MARK: - Building Metrics from result segments

    /// Metrics for a single segment, or `nil` if it carries no confidence data.
    /// A segment with metrics is judged on its own values (no cross-segment mixing).
    static func metrics(for segment: TranscriptionResult.Segment) -> Metrics? {
        guard let logprob = segment.avgLogprob else { return nil }
        return Metrics(
            avgLogprob: logprob,
            compressionRatio: segment.compressionRatio ?? 0,
            noSpeechProb: segment.noSpeechProb ?? 0
        )
    }

    /// Whole-clip aggregate for dictation's all-or-nothing decision. Builds one
    /// `Metrics` PER segment first, then means those — so the three axes stay
    /// aligned to the same segment (no per-array length-mismatch bug). Mean means a
    /// clip that is mostly real (one weak segment) is kept; only a clip bad on
    /// average is flagged. `nil` when no segment carries metrics.
    static func aggregateMetrics(_ segments: [TranscriptionResult.Segment]) -> Metrics? {
        let per = segments.compactMap { metrics(for: $0) }
        guard !per.isEmpty else { return nil }
        func mean(_ pick: (Metrics) -> Float) -> Float { per.map(pick).reduce(0, +) / Float(per.count) }
        return Metrics(
            avgLogprob: mean { $0.avgLogprob },
            compressionRatio: mean { $0.compressionRatio },
            noSpeechProb: mean { $0.noSpeechProb }
        )
    }
}
