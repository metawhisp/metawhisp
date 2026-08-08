import XCTest
@testable import MetaWhisp

/// ITER-060.4 — interior-silence suppression BEFORE the decoder, with a
/// piecewise time map. Codex design review (2026-08-08) flagged the hazard
/// this suite pins: cutting interior silence compresses decoder time, so
/// every utterance timestamp AFTER a cut must be mapped back to the original
/// timeline — otherwise Me/Them merge ordering and the echo-dedup window
/// ([-2,+4]s) silently break.
final class MeetingAudioSilenceCutterTests: XCTestCase {

    private typealias C = MeetingAudioSilenceCutter
    private let sr = 16000

    /// Loud speech-like burst (constant amplitude well above the threshold).
    private func speech(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.05, count: Int(seconds * Double(sr)))
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.0, count: Int(seconds * Double(sr)))
    }

    // MARK: - cutting behavior

    func test_longInteriorGapCut_paddingKept() {
        // 3s speech + 10s silence + 3s speech → the gap collapses to the two
        // 0.25s pads; total ≈ 3 + 0.5 + 3 seconds.
        let input = speech(3) + silence(10) + speech(3)
        let result = C.cut(samples: input)
        let outSec = Double(result.samples.count) / Double(sr)
        XCTAssertEqual(outSec, 6.5, accuracy: 0.3)
    }

    func test_shortPauseUntouched() {
        // 1.5s pause < 2s threshold — natural inter-sentence gap stays.
        let input = speech(2) + silence(1.5) + speech(2)
        let result = C.cut(samples: input)
        XCTAssertEqual(result.samples.count, input.count)
    }

    func test_cleanSpeechIdentity() {
        let input = speech(5)
        let result = C.cut(samples: input)
        XCTAssertEqual(result.samples.count, input.count)
        // Identity map: any timestamp maps to itself.
        XCTAssertEqual(result.map.toOriginalSeconds(2.5), 2.5, accuracy: 0.01)
    }

    func test_multipleGapsAllCut() {
        let input = speech(2) + silence(5) + speech(2) + silence(5) + speech(2)
        let result = C.cut(samples: input)
        let outSec = Double(result.samples.count) / Double(sr)
        XCTAssertEqual(outSec, 2 + 0.5 + 2 + 0.5 + 2, accuracy: 0.4)
    }

    func test_alreadyCutAudioIdempotent() {
        let input = speech(3) + silence(10) + speech(3)
        let once = C.cut(samples: input)
        let twice = C.cut(samples: once.samples)
        XCTAssertEqual(twice.samples.count, once.samples.count)
    }

    // MARK: - time map (the Codex-critical part)

    func test_timestampAfterCutMapsBackToOriginal() {
        // Utterance starting 1s into the SECOND speech block:
        // compressed ≈ 3 + 0.5 + 1 = 4.5s; original = 3 + 10 + 1 = 14s.
        let input = speech(3) + silence(10) + speech(3)
        let result = C.cut(samples: input)
        XCTAssertEqual(result.map.toOriginalSeconds(4.5), 14.0, accuracy: 0.4)
    }

    func test_timestampBeforeCutUnchanged() {
        let input = speech(3) + silence(10) + speech(3)
        let result = C.cut(samples: input)
        XCTAssertEqual(result.map.toOriginalSeconds(1.0), 1.0, accuracy: 0.15)
    }

    func test_timestampAfterTwoCutsAccumulatesBothGaps() {
        let input = speech(2) + silence(5) + speech(2) + silence(5) + speech(2)
        let result = C.cut(samples: input)
        // 1s into the THIRD block: compressed ≈ 2+0.5+2+0.5+1 = 6s;
        // original = 2+5+2+5+1 = 15s.
        XCTAssertEqual(result.map.toOriginalSeconds(6.0), 15.0, accuracy: 0.5)
    }

    func test_mapMonotonicAndClamped() {
        let input = speech(2) + silence(6) + speech(2)
        let result = C.cut(samples: input)
        let end = Double(result.samples.count) / Double(sr)
        var prev = -Double.infinity
        for i in 0...20 {
            let t = end * Double(i) / 20
            let orig = result.map.toOriginalSeconds(t)
            XCTAssertGreaterThanOrEqual(orig, prev)
            prev = orig
        }
        // Beyond-the-end query clamps to the original duration, never explodes.
        XCTAssertLessThanOrEqual(result.map.toOriginalSeconds(end + 100), 10.5)
    }

    // MARK: - edge cases

    func test_allSilenceCollapsesToNearNothing() {
        let result = C.cut(samples: silence(30))
        XCTAssertLessThan(result.samples.count, sr) // < 1s survives
    }

    func test_emptyInput() {
        let result = C.cut(samples: [])
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.map.toOriginalSeconds(0), 0, accuracy: 0.001)
    }

    func test_leadingAndTrailingSilenceCutToo() {
        // Edges are normally pre-trimmed upstream, but the cutter must not
        // депend on that (defensive): 8s lead silence collapses to the pad.
        let input = silence(8) + speech(2)
        let result = C.cut(samples: input)
        let outSec = Double(result.samples.count) / Double(sr)
        XCTAssertEqual(outSec, 2.25, accuracy: 0.3)
        // Speech start maps back near t=8 in the original.
        XCTAssertEqual(result.map.toOriginalSeconds(0.3), 7.8 + 0.3, accuracy: 0.4)
    }
}
