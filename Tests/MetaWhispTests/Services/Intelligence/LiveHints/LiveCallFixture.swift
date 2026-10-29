import Foundation
@testable import MetaWhisp

/// The fake meeting the tracker tests run on: generated audio and a fake
/// transcriber.
///
/// The audio is generated, never recorded, so a test can say "speech at 0.05,
/// silence at 0" and mean it: every 50 ms frame carries exactly the RMS the
/// script asks for. The generator is seeded, so a run is reproducible and a
/// failure is a real failure.
enum LiveCallFixture {

    /// One piece of the fake call.
    struct Segment: Equatable {
        let seconds: Double
        let rms: Float

        /// Quiet air.
        static func silence(_ seconds: Double) -> Segment {
            Segment(seconds: seconds, rms: 0)
        }

        /// Something the detector must hear as speech.
        static func speech(_ seconds: Double, rms: Float = 0.05) -> Segment {
            Segment(seconds: seconds, rms: rms)
        }
    }

    /// The samples of the scripted call.
    static func audio(_ segments: [Segment], seed: UInt64 = 1) -> [Float] {
        var samples: [Float] = []
        var frameIndex: UInt64 = 0
        for segment in segments {
            let frameCount = Int((segment.seconds * Double(SpeechActivity.sampleRate))
                / Double(SpeechActivity.frameSamples))
            for _ in 0..<frameCount {
                samples.append(contentsOf: frame(rms: segment.rms, seed: seed &+ frameIndex))
                frameIndex += 1
            }
        }
        return samples
    }

    /// One frame of noise with exactly this RMS.
    static func frame(rms: Float, seed: UInt64) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var values = [Float](repeating: 0, count: SpeechActivity.frameSamples)
        var sumOfSquares: Float = 0
        for index in 0..<values.count {
            let value = Float(generator.nextUnit() * 2 - 1)
            values[index] = value
            sumOfSquares += value * value
        }
        let current = (sumOfSquares / Float(values.count)).squareRoot()
        guard current > 0 else { return values }
        let scale = rms / current
        for index in 0..<values.count {
            values[index] *= scale
        }
        return values
    }
}

/// A tiny deterministic generator — the tests must not depend on the system
/// random source, or the same test would fail on a different run.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `[0, 1)`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// A fake live transcriber: it records every request and answers from a
/// handler the test controls, so a result can arrive late or never.
final class FakeLiveTranscriber: LiveTranscriber, @unchecked Sendable {

    /// One request the tracker made.
    struct Call: Equatable {
        let range: LiveSampleRange
        let countUsage: Bool
    }

    /// Answers a request. The index is the call's number, starting at zero.
    typealias Responder = @Sendable (LiveSampleRange, Int) async -> String

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var responder: Responder?

    init(responder: Responder? = nil) {
        self.responder = responder
    }

    func setResponder(_ responder: @escaping Responder) {
        lock.withLock { self.responder = responder }
    }

    func transcribe(samples: [Float], range: LiveSampleRange, countUsage: Bool) async throws -> String {
        let index = lock.withLock { () -> Int in
            recorded.append(Call(range: range, countUsage: countUsage))
            return recorded.count - 1
        }
        let responder = lock.withLock { self.responder }
        guard let responder else { return "" }
        return await responder(range, index)
    }

    /// Every request, in order.
    var calls: [Call] {
        lock.withLock { recorded }
    }
}

/// A transcriber whose request hangs at a gate until the test lets it go, and
/// comes back empty afterwards.
///
/// The tracker waits for such a request when an utterance closes: the test
/// decides when the wait ends, and what happens to the utterance then.
final class GatedLiveTranscriber: LiveTranscriber, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [LiveSampleRange] = []
    /// The gate every request waits at.
    private let gate: RequestGate

    init(gate: RequestGate) {
        self.gate = gate
    }

    /// How many requests the tracker made.
    var callCount: Int { lock.withLock { recorded.count } }

    func transcribe(samples: [Float], range: LiveSampleRange, countUsage: Bool) async throws -> String {
        lock.withLock { recorded.append(range) }
        await gate.wait()
        // The request comes back with nothing: the candidate says no word.
        throw CancellationError()
    }
}

/// The fake recorder behind the audio source: the whole scripted call, cut by
/// the range a request asks for.
final class FakeLiveAudioSource: LiveAudioSource, @unchecked Sendable {
    private let samples: [Float]
    private let lock = NSLock()
    /// Every read, with the range it covered.
    private(set) var reads: [LiveSampleRange] = []

    init(samples: [Float]) {
        self.samples = samples
    }

    func samples(from: Int, count: Int) async -> [Float] {
        lock.withLock { reads.append(LiveSampleRange(from: from, to: from + count)) }
        guard from >= 0, count > 0, from + count <= samples.count else { return [] }
        return Array(samples[from ..< from + count])
    }
}
