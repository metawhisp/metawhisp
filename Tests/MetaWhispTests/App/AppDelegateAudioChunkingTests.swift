import XCTest
@testable import MetaWhisp

/// Retroactive TDD coverage (2026-04-29) for the chunk-cutting + VAD-trim
/// helpers added in Phase A. Pure functions of `[Float]` audio samples — no
/// I/O, no actors, no SwiftUI. Should have been written BEFORE the production
/// code per `specs/TDD.md`; I shipped GREEN first and back-filled RED here.
/// Going forward: tests first.
@MainActor
final class AppDelegateAudioChunkingTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesize a buffer of `count` samples filled with `level`. Used to
    /// simulate uniform speech-level or silence regions.
    private func samples(count: Int, level: Float) -> [Float] {
        return Array(repeating: level, count: count)
    }

    /// Synthesize a "speech … silence … speech" buffer at 16kHz: `speechSec`
    /// of speech, `silenceSec` of silence in the middle, `speechSec` again.
    /// Used to test that `splitOnSilenceBoundaries` lands the cut in silence.
    private func speechSilenceSpeech(speechSec: Int, silenceSec: Int) -> [Float] {
        let sampleRate = 16000
        var out: [Float] = []
        out += samples(count: speechSec * sampleRate, level: 0.1)
        out += samples(count: silenceSec * sampleRate, level: 0.0001)
        out += samples(count: speechSec * sampleRate, level: 0.1)
        return out
    }

    // MARK: - splitOnSilenceBoundaries

    func test_split_returnsSingleChunkWhenShorterThanTarget() {
        let buf = samples(count: 16000 * 60, level: 0.1)  // 60 sec
        let chunks = AppDelegate.splitOnSilenceBoundaries(samples: buf, targetChunkSec: 300, searchWindowSec: 15)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, buf.count)
    }

    func test_split_cutsAtSilenceWithinSearchWindow() {
        // 295 sec speech + 5 sec silence + 295 sec speech = 595 sec total.
        // Target chunk 300 sec, search window 15 sec → cut should land in
        // the silence region (between sec 295 and 300).
        let buf = speechSilenceSpeech(speechSec: 295, silenceSec: 5)
        let chunks = AppDelegate.splitOnSilenceBoundaries(samples: buf, targetChunkSec: 300, searchWindowSec: 15)
        XCTAssertEqual(chunks.count, 2)
        // First chunk should end somewhere INSIDE the silence band — i.e.
        // its length is between 295 sec and 300 sec.
        let firstSec = Double(chunks[0].count) / 16000.0
        XCTAssertGreaterThanOrEqual(firstSec, 295.0)
        XCTAssertLessThanOrEqual(firstSec, 300.5)
    }

    func test_split_emptyInputReturnsSingleEmptyChunk() {
        let chunks = AppDelegate.splitOnSilenceBoundaries(samples: [], targetChunkSec: 300, searchWindowSec: 15)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 0)
    }

    func test_split_concatenationPreservesAllSamples() {
        let buf = speechSilenceSpeech(speechSec: 295, silenceSec: 5)
        let chunks = AppDelegate.splitOnSilenceBoundaries(samples: buf, targetChunkSec: 300, searchWindowSec: 15)
        let total = chunks.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, buf.count)
    }

    // MARK: - trimSilenceEdges

    func test_trim_stripsLeadingSilence() {
        let sampleRate = 16000
        let leadingSilence = samples(count: sampleRate * 2, level: 0.0001)  // 2s silence
        let speech = samples(count: sampleRate * 3, level: 0.1)              // 3s speech
        let buf = leadingSilence + speech
        let trimmed = AppDelegate.trimSilenceEdges(samples: buf)
        // Trimmed should drop most of the silence; allow some margin (window-aligned).
        XCTAssertLessThan(trimmed.count, buf.count - sampleRate)  // dropped at least 1s
        XCTAssertGreaterThan(trimmed.count, sampleRate * 2)        // kept the speech
    }

    func test_trim_stripsTrailingSilence() {
        let sampleRate = 16000
        let speech = samples(count: sampleRate * 3, level: 0.1)
        let trailingSilence = samples(count: sampleRate * 2, level: 0.0001)
        let buf = speech + trailingSilence
        let trimmed = AppDelegate.trimSilenceEdges(samples: buf)
        XCTAssertLessThan(trimmed.count, buf.count - sampleRate)
        XCTAssertGreaterThan(trimmed.count, sampleRate * 2)
    }

    func test_trim_returnsSameWhenAllSpeech() {
        let buf = samples(count: 16000 * 3, level: 0.1)
        let trimmed = AppDelegate.trimSilenceEdges(samples: buf)
        XCTAssertEqual(trimmed.count, buf.count)
    }

    func test_trim_handlesShortInputWithoutCrash() {
        // Buffer shorter than 2× window — function should return as-is.
        let buf = samples(count: 1000, level: 0.0001)
        let trimmed = AppDelegate.trimSilenceEdges(samples: buf)
        XCTAssertEqual(trimmed.count, buf.count)
    }
}
