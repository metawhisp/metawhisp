import XCTest
@testable import MetaWhisp

/// Pins the precision-first confidence gate (Iteration B / TR-5). The gate exists
/// to drop "fluent hallucinations" temperature fallback returns, WITHOUT deleting
/// real-but-hard speech — so thresholds have headroom below Whisper's own values
/// and repetition only counts when paired with low confidence.
final class TranscriptionConfidenceGateTests: XCTestCase {

    private typealias Gate = TranscriptionConfidenceGate

    private func seg(_ logprob: Float?, _ compression: Float? = 1.6, _ noSpeech: Float? = 0.05,
                     text: String = "x", start: TimeInterval = 0, end: TimeInterval = 1) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(text: text, start: start, end: end,
                                    avgLogprob: logprob, compressionRatio: compression, noSpeechProb: noSpeech)
    }

    // MARK: - keep real speech

    func testHealthyMetrics_kept() {
        XCTAssertNil(Gate.rejectionReason(Gate.Metrics(avgLogprob: -0.25, compressionRatio: 1.8, noSpeechProb: 0.05)))
    }

    func testNilMetrics_kept() {
        XCTAssertNil(Gate.rejectionReason(nil))
    }

    func testModeratelyLowConfidence_keptDueToHeadroom() {
        // −1.2 is below Whisper's −1.0 fallback trigger but ABOVE our −1.5 floor:
        // hard-but-real audio must survive (it would only be dropped if it were
        // also silence or repetition).
        XCTAssertNil(Gate.rejectionReason(Gate.Metrics(avgLogprob: -1.2, compressionRatio: 1.9, noSpeechProb: 0.1)))
    }

    func testCleanRepetitiveSpeech_kept() {
        // "раз, два, три, четыре" / "да да да" — high compression but GOOD
        // confidence. The old bare-compression filter wrongly deleted this; the
        // paired condition keeps it.
        XCTAssertNil(Gate.rejectionReason(Gate.Metrics(avgLogprob: -0.3, compressionRatio: 3.5, noSpeechProb: 0.1)))
    }

    func testHighNoSpeechButConfident_kept() {
        XCTAssertNil(Gate.rejectionReason(Gate.Metrics(avgLogprob: -0.4, compressionRatio: 1.6, noSpeechProb: 0.95)))
    }

    // MARK: - drop hallucinations

    func testClearlyLowConfidence_dropped() {
        XCTAssertEqual(Gate.rejectionReason(Gate.Metrics(avgLogprob: -1.8, compressionRatio: 1.9, noSpeechProb: 0.1))?.hasPrefix("low confidence"), true)
    }

    func testRepetitionWithLowConfidence_dropped() {
        // Looped hallucination: high compression AND low confidence.
        XCTAssertEqual(Gate.rejectionReason(Gate.Metrics(avgLogprob: -0.9, compressionRatio: 3.5, noSpeechProb: 0.1))?.hasPrefix("repetition"), true)
    }

    func testSilenceWithLowConfidence_dropped() {
        XCTAssertEqual(Gate.rejectionReason(Gate.Metrics(avgLogprob: -1.2, compressionRatio: 1.5, noSpeechProb: 0.9))?.hasPrefix("silence"), true)
    }

    // B4 spec case: no_speech_prob=0.9 / logprob=-2 must drop; healthy must pass.
    func testSpecB4_silenceCaseDropped() {
        XCTAssertNotNil(Gate.rejectionReason(Gate.Metrics(avgLogprob: -2.0, compressionRatio: 1.5, noSpeechProb: 0.9)))
    }

    // MARK: - metrics(for:) — per-segment, no metrics → nil

    func testMetricsForSegment_nilWhenNoData() {
        XCTAssertNil(Gate.metrics(for: TranscriptionResult.Segment(text: "x", start: 0, end: 1)))
    }

    func testMetricsForSegment_builtFromFields() {
        let m = Gate.metrics(for: seg(-1.8))
        XCTAssertEqual(m?.avgLogprob, -1.8)
        XCTAssertEqual(Gate.rejectionReason(m)?.hasPrefix("low confidence"), true)
    }

    // MARK: - aggregateMetrics — whole-clip dictation decision

    func testAggregate_emptyOrNoMetricsIsNil() {
        XCTAssertNil(Gate.aggregateMetrics([]))
        XCTAssertNil(Gate.aggregateMetrics([TranscriptionResult.Segment(text: "x", start: 0, end: 1)]))
    }

    func testAggregate_mostlyGoodClipKept() {
        // Three good segments + one terrible: mean stays above the floor → kept.
        let segs = [seg(-0.2), seg(-0.3), seg(-0.25), seg(-3.0)]  // mean ≈ -0.94 > -1.5
        XCTAssertNil(Gate.rejectionReason(Gate.aggregateMetrics(segs)))
    }

    func testAggregate_allBadClipDropped() {
        let segs = [seg(-1.8), seg(-2.1), seg(-1.9)]
        XCTAssertNotNil(Gate.rejectionReason(Gate.aggregateMetrics(segs)))
    }

    func testAggregate_alignedPerSegment() {
        // Each Metrics is built from ONE segment, so the silence AND-condition can
        // never fire across disjoint segments (regression guard for the per-array
        // compactMap misalignment bug).
        let segs = [seg(-0.2, 1.6, 0.95), seg(-2.0, 1.6, 0.05)]  // high-noSpeech and low-logprob are different segments
        let agg = Gate.aggregateMetrics(segs)
        // mean logProb = -1.1 (> -1.5 floor), mean noSpeech = 0.5 (not > 0.5) → kept,
        // NOT wrongly dropped as "silence".
        XCTAssertNil(Gate.rejectionReason(agg))
    }
}
