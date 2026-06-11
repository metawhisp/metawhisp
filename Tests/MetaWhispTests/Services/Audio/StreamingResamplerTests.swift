import XCTest
@testable import MetaWhisp

/// TR-9/TR-10 (ITER-046 D) — pins the streaming resampler:
/// - anti-aliasing: a tone above the output Nyquist must be strongly attenuated
///   (the old linear interpolation folded it into the speech band — that
///   implementation FAILS this test);
/// - continuity: chunked processing matches one-shot processing, and irregular
///   buffer sizes don't lose samples (the old per-buffer truncation drifted).
final class StreamingResamplerTests: XCTestCase {

    private let inRate = 48_000.0
    private let outRate = 16_000.0

    private func sine(_ freq: Double, rate: Double, count: Int) -> [Float] {
        (0..<count).map { Float(sin(2.0 * .pi * freq * Double($0) / rate)) }
    }

    private func rms(_ xs: ArraySlice<Float>) -> Float {
        guard !xs.isEmpty else { return 0 }
        return sqrt(xs.reduce(Float(0)) { $0 + $1 * $1 } / Float(xs.count))
    }

    // MARK: - TR-9: anti-aliasing

    func testInBandToneSurvives() {
        let r = StreamingResampler(outputRate: outRate)
        let input = sine(6_000, rate: inRate, count: 48_000)  // 1s, well below 8k Nyquist
        let out = r.resample(input, from: inRate)
        XCTAssertGreaterThan(out.count, 14_000)
        // Skip converter priming at the edges; a 6 kHz tone must keep its energy.
        let body = out.dropFirst(1_000).dropLast(1_000)
        XCTAssertGreaterThan(rms(body), 0.5, "in-band tone should survive resampling (RMS ~0.707)")
    }

    func testAboveNyquistToneIsAttenuated() {
        // 21 kHz is inaudible content above the 8 kHz output Nyquist. A proper
        // low-pass removes it; bare linear interpolation folds it to 5 kHz at
        // near-full amplitude (this is the TR-9 bug — that code fails here).
        let r = StreamingResampler(outputRate: outRate)
        let input = sine(21_000, rate: inRate, count: 48_000)
        let out = r.resample(input, from: inRate)
        XCTAssertGreaterThan(out.count, 14_000)
        let body = out.dropFirst(1_000).dropLast(1_000)
        XCTAssertLessThan(rms(body), 0.15, "above-Nyquist tone must be filtered out, not aliased in")
    }

    // MARK: - TR-10: cross-buffer continuity

    func testChunkedMatchesOneShot() {
        // Same continuous signal: one-shot vs irregular 997-sample chunks. The
        // stateful converter must produce (near-)identical output; a per-buffer
        // restart produces gross divergence at every boundary.
        let signal = sine(1_000, rate: inRate, count: 47_856)  // not divisible by 997 or 3

        let whole = StreamingResampler(outputRate: outRate).resample(signal, from: inRate)

        let chunked = StreamingResampler(outputRate: outRate)
        var out: [Float] = []
        var i = 0
        while i < signal.count {
            let end = min(i + 997, signal.count)
            out.append(contentsOf: chunked.resample(Array(signal[i..<end]), from: inRate))
            i = end
        }

        let n = min(whole.count, out.count)
        XCTAssertGreaterThan(n, 14_000)
        var diffSq: Float = 0
        for k in 0..<n { let d = whole[k] - out[k]; diffSq += d * d }
        let diffRMS = sqrt(diffSq / Float(n))
        XCTAssertLessThan(diffRMS, 0.05, "chunked output must match one-shot (stateful continuity)")
    }

    func testIrregularChunksDontLoseSamples() {
        // 60 irregular buffers; total output must be ~ totalIn/3 (allowing the
        // converter's bounded priming latency), not short by a sample per buffer.
        let r = StreamingResampler(outputRate: outRate)
        var totalIn = 0, totalOut = 0
        for k in 0..<60 {
            let n = 800 + (k * 137) % 700   // 800..1499, mostly not divisible by 3
            totalIn += n
            totalOut += r.resample(sine(440, rate: inRate, count: n), from: inRate).count
        }
        let ideal = totalIn / 3
        XCTAssertLessThanOrEqual(abs(totalOut - ideal), 256,
                                 "got \(totalOut) of ~\(ideal) — samples lost at buffer boundaries")
    }

    // MARK: - edges

    func testEmptyInput() {
        XCTAssertTrue(StreamingResampler(outputRate: outRate).resample([], from: inRate).isEmpty)
    }

    func testSameRatePassthrough() {
        let r = StreamingResampler(outputRate: outRate)
        let input = sine(440, rate: outRate, count: 1_600)
        XCTAssertEqual(r.resample(input, from: outRate), input)
    }
}
