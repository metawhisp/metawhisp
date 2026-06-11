import XCTest
@testable import MetaWhisp

/// Proof-of-life test for the TDD infrastructure (spec://specs/TDD.md).
/// Targets pure-function logic that already exists in the codebase — no
/// new production code added just to host a test. If `swift test` exits
/// 0 with these green, the test target is wired correctly and we can
/// start writing real TDD-driven features against it.
@MainActor
final class SmokeTests: XCTestCase {

    // MARK: - MeetingRecorder.mix (Services/Audio/MeetingRecorder.swift)

    /// `mix` should return only the system audio when mic is empty.
    func test_mix_returnsSystemWhenMicEmpty() {
        let mic: [Float] = []
        let system: [Float] = [0.1, 0.2, 0.3]
        let result = MeetingRecorder.mix(mic: mic, system: system)
        XCTAssertEqual(result, system)
    }

    /// `mix` should return only the mic when system is empty.
    func test_mix_returnsMicWhenSystemEmpty() {
        let mic: [Float] = [0.1, 0.2, 0.3]
        let system: [Float] = []
        let result = MeetingRecorder.mix(mic: mic, system: system)
        XCTAssertEqual(result, mic)
    }

    /// TR-11: `mix` soft-clips loud overlaps SMOOTHLY — compressed below ±1,
    /// and distinct loud inputs stay distinguishable (a hard clip flat-tops
    /// both 1.6 and 1.8 to exactly 1.0 — that implementation fails here).
    func test_mix_softClipsLoudOverlapSmoothly() {
        let mic: [Float] = [0.8, -0.9]
        let system: [Float] = [0.8, -0.9]   // sums: 1.6 / -1.8
        let result = MeetingRecorder.mix(mic: mic, system: system)
        XCTAssertGreaterThan(result[0], 0.85)
        XCTAssertLessThan(result[0], 1.0)          // not flat-topped to 1.0
        XCTAssertLessThan(result[1], -0.85)
        XCTAssertGreaterThan(result[1], -1.0)
        XCTAssertNotEqual(abs(result[0]), abs(result[1]), "distinct loud sums must stay distinct")
    }

    // MARK: - TR-11: softClip unit contract

    func test_softClip_identityForNormalLevels() {
        // |x| ≤ 0.5 passes through bit-exact — no distortion on normal speech.
        for x: Float in [-0.5, -0.3, -0.01, 0, 0.2, 0.5] {
            XCTAssertEqual(MeetingRecorder.softClip(x), x)
        }
    }

    func test_softClip_strictlyInsideOneForRealDomain() {
        // Two [-1, 1] streams sum to at most ±2.0 — the whole real input domain
        // stays STRICTLY inside ±1 after the clip. (Beyond the domain, Float32
        // tanh saturates to exactly 1.0 around x≈10 — bounded and harmless.)
        XCTAssertLessThan(MeetingRecorder.softClip(2.0), 1.0)
        XCTAssertGreaterThan(MeetingRecorder.softClip(-2.0), -1.0)
        XCTAssertGreaterThan(MeetingRecorder.softClip(2.0), 0.99)   // but asymptotes close
    }

    func test_softClip_monotonicAndSymmetric() {
        var prev: Float = -2
        for i in stride(from: -3.0, through: 3.0, by: 0.1) {
            let y = MeetingRecorder.softClip(Float(i))
            XCTAssertGreaterThanOrEqual(y, prev)   // monotonic
            prev = y
        }
        XCTAssertEqual(MeetingRecorder.softClip(-1.7), -MeetingRecorder.softClip(1.7), accuracy: 1e-6)
    }

    func test_softClip_continuousAtKnee() {
        // No jump at the 0.5 knee.
        XCTAssertEqual(MeetingRecorder.softClip(0.5001), 0.5, accuracy: 0.001)
    }

    /// `mix` should keep the longer source's tail at full gain.
    func test_mix_keepsTailOfLongerSource() {
        let mic: [Float] = [0.1]
        let system: [Float] = [0.2, 0.3, 0.4]
        let result = MeetingRecorder.mix(mic: mic, system: system)
        // Overlap [0]: 0.1 + 0.2 = 0.3. Tail [1..2]: 0.3, 0.4 from system.
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(result[2], 0.4, accuracy: 0.0001)
    }

    // MARK: - TranscriptionCoordinator.containsExcessivePhraseRepetition
    // (Services/System/TranscriptionCoordinator.swift) — added 2026-04-28
    // to catch Whisper repetition-loop hallucinations. The test below pins
    // its current behaviour so future tweaks don't silently regress.

    /// Trigram repeated 3 times in one chunk → flagged.
    func test_repetition_trigramRepeatedThreeTimes_isHallucination() {
        let text = "ну и комьюнити ну и комьюнити ну и комьюнити финал"
        XCTAssertTrue(TranscriptionCoordinator.containsExcessivePhraseRepetition(text))
    }

    /// Single word repeated 5+ times consecutively → flagged.
    func test_repetition_consecutiveSingleWordRun_isHallucination() {
        let text = "yes yes yes yes yes thanks"
        XCTAssertTrue(TranscriptionCoordinator.containsExcessivePhraseRepetition(text))
    }

    /// Healthy speech with normal repetition → NOT flagged.
    func test_repetition_normalSpeech_isNotHallucination() {
        let text = "We discussed the deadline and Alex will deliver the backend by Friday."
        XCTAssertFalse(TranscriptionCoordinator.containsExcessivePhraseRepetition(text))
    }

    /// Short input below the analysis floor → NOT flagged (no signal).
    func test_repetition_tooShortInput_isNotHallucination() {
        XCTAssertFalse(TranscriptionCoordinator.containsExcessivePhraseRepetition("hi hi hi"))
    }
}
