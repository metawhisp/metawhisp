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

    /// `mix` should sum and soft-clip overlapping samples to [-1, 1].
    func test_mix_softClipsLoudOverlapToOne() {
        let mic: [Float] = [0.8, -0.9]
        let system: [Float] = [0.8, -0.9]   // both summed → 1.6 / -1.8 → clip to ±1
        let result = MeetingRecorder.mix(mic: mic, system: system)
        XCTAssertEqual(result, [1.0, -1.0])
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
