import XCTest
@testable import MetaWhisp

/// ITER-054 — BYOK Deepgram diarization: pins the pure logic (speaker→channel
/// mapping, segment conversion, URL contract, response decoding). The network
/// call itself is smoke-tested manually with the founder's key.
final class DeepgramMeetingTranscriberTests: XCTestCase {

    typealias DG = DeepgramMeetingTranscriber
    private func utt(_ s: Double, _ e: Double, _ text: String, spk: Int) -> DG.DGUtterance {
        DG.DGUtterance(start: s, end: e, transcript: text, speaker: spk)
    }

    // MARK: - URL contract

    /// diarize+utterances are the whole point; the key must NEVER be in the URL.
    func test_requestURL_hasDiarizationAndNoKey() {
        let url = DG.requestURL().absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.deepgram.com/v1/listen?"))
        for param in ["model=nova-3", "diarize=true", "utterances=true", "language=multi"] {
            XCTAssertTrue(url.contains(param), "missing \(param) in \(url)")
        }
        XCTAssertFalse(url.lowercased().contains("token"))
        XCTAssertFalse(url.lowercased().contains("key"))
    }

    // MARK: - Speaker → channel mapping

    /// Speaker heard on the mic channel → Me; on the system channel → Them.
    func test_mapping_byChannelEnergy() {
        let utts = [utt(0, 2, "привет", spk: 0), utt(2, 4, "hello back", spk: 1)]
        let mapping = DG.mapSpeakersToChannels(
            utterances: utts,
            micEnergy: { s, _ in s < 2 ? 0.5 : 0.01 },     // mic loud during spk 0
            systemEnergy: { s, _ in s < 2 ? 0.01 : 0.5 }   // system loud during spk 1
        )
        XCTAssertEqual(mapping[0], .me)
        XCTAssertEqual(mapping[1], .them)
    }

    /// >2 speakers: every remote voice maps to Them (they all live on the
    /// system channel) — the transcript stays coherent instead of dropping them.
    func test_mapping_multipleRemoteSpeakers_allThem() {
        let utts = [utt(0, 1, "a", spk: 0), utt(1, 2, "b", spk: 1), utt(2, 3, "c", spk: 2)]
        let mapping = DG.mapSpeakersToChannels(
            utterances: utts,
            micEnergy: { s, _ in s < 1 ? 0.6 : 0.02 },
            systemEnergy: { s, _ in s < 1 ? 0.02 : 0.6 }
        )
        XCTAssertEqual(mapping[0], .me)
        XCTAssertEqual(mapping[1], .them)
        XCTAssertEqual(mapping[2], .them)
    }

    // MARK: - Segments + render (same downstream format as the Whisper path)

    func test_segments_renderAsMeThem() {
        let utts = [utt(0, 2, "как дела", spk: 0), utt(2, 4, "хорошо, спасибо", spk: 1),
                    utt(4, 6, "отлично", spk: 1)]
        let segs = DG.segments(utterances: utts, mapping: [0: .me, 1: .them])
        let text = DualStreamMerger.renderTranscript(segs)
        XCTAssertEqual(text, "Me: как дела\nThem: хорошо, спасибо отлично")
    }

    /// Whitespace-only utterances are dropped; unknown speaker ids default to
    /// Them (never crash, never attribute a stranger's words to the user).
    func test_segments_dropsEmpty_defaultsUnknownToThem() {
        let utts = [utt(0, 1, "  ", spk: 0), utt(1, 2, "text", spk: 7)]
        let segs = DG.segments(utterances: utts, mapping: [0: .me])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].speaker, .them)
    }

    // MARK: - windowRMS

    func test_windowRMS_boundsAndSignal() {
        var samples = [Float](repeating: 0, count: 16_000 * 4)
        for i in (16_000 * 2)..<(16_000 * 3) { samples[i] = 0.5 }  // loud 2s..3s
        XCTAssertEqual(DG.windowRMS(samples, startSec: 2, endSec: 3), 0.5, accuracy: 0.01)
        XCTAssertEqual(DG.windowRMS(samples, startSec: 0, endSec: 1), 0.0, accuracy: 0.001)
        // Codex review — a window ENTIRELY past this channel's end contributes
        // ZERO (not the clamp-repeated last sample: that flipped tail Me/Them
        // when mic/system buffers differ in length).
        for i in (16_000 * 3)..<samples.count { samples[i] = 0.9 }  // loud last sample region
        XCTAssertEqual(DG.windowRMS(samples, startSec: 100, endSec: 200), 0.0, accuracy: 0.0001)
        XCTAssertEqual(DG.windowRMS([], startSec: 0, endSec: 1), 0)
    }

    // MARK: - Streamed WAV writer (Codex review — no full-meeting buffers)

    /// Header fields + payload length + mixing semantics survive the slice-wise
    /// streaming path (2s mic + 3s system → 3s file, tail from the longer).
    func test_writeMixedWAV_streamed_headerAndMixing() throws {
        let mic = [Float](repeating: 0.25, count: 32_000)      // 2s
        let system = [Float](repeating: 0.25, count: 48_000)   // 3s
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let seconds = try DG.writeMixedWAV(mic: mic, system: system, to: tmp)
        XCTAssertEqual(seconds, 3.0, accuracy: 0.001)

        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(data.count, 44 + 48_000 * 2, "44-byte header + 16-bit samples")
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        // Sample rate little-endian at offset 24 = 16000.
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
        // Overlap region: 0.25+0.25=0.5 → Int16 ≈ 16383; tail (system only) ≈ 8191.
        let firstSample = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int(Int16(littleEndian: firstSample)), 16383, accuracy: 2)
        let tailOffset = 44 + 40_000 * 2  // 2.5s — inside system-only tail
        let tailSample = data[tailOffset..<(tailOffset + 2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int(Int16(littleEndian: tailSample)), 8191, accuracy: 2)
    }

    // MARK: - Response decoding (real Deepgram shape, trimmed)

    func test_decode_realResponseShape() throws {
        let json = """
        {"metadata":{"duration":4.2},"results":{"channels":[{"alternatives":[{"transcript":"..."}]}],
         "utterances":[{"start":0.08,"end":1.9,"confidence":0.98,"channel":0,
                        "transcript":"Привет, как дела?","words":[],"speaker":0,"id":"x"}]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DG.DGResponse.self, from: json)
        XCTAssertEqual(decoded.results?.utterances?.count, 1)
        XCTAssertEqual(decoded.results?.utterances?.first?.speaker, 0)
        XCTAssertEqual(decoded.results?.utterances?.first?.transcript, "Привет, как дела?")
    }
}
