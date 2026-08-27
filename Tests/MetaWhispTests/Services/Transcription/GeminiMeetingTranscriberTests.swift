import XCTest
@testable import MetaWhisp

/// Gemini caps diarized audio at thirty minutes. Twenty-five of the last
/// sixty-one meetings ran longer and carried seventy per cent of the minutes,
/// so slicing is not an optimisation here — without it the option covers less
/// than a third of the audio it exists for.
final class GeminiMeetingTranscriberTests: XCTestCase {

    private typealias G = GeminiMeetingTranscriber

    private func word(_ text: String, _ speaker: String?,
                      _ start: String?, _ end: String?) -> G.WordInfo {
        .init(text: text, speaker: speaker, startOffset: start, endOffset: end)
    }

    // MARK: - Slicing

    /// A meeting under the cap goes in one piece — slicing a ten-minute call
    /// would double the requests for nothing.
    func testAShortMeetingIsNotSliced() {
        let tenMinutes = Int(10 * 60 * G.sampleRate)
        XCTAssertEqual(G.sliceRanges(totalSamples: tenMinutes), [0..<tenMinutes])
    }

    /// The two-hour case, which is the longest meeting in the last month.
    func testEverySliceStaysUnderTheDocumentedCap() {
        let twoHours = Int(120 * 60 * G.sampleRate)
        let ranges = G.sliceRanges(totalSamples: twoHours)
        XCTAssertGreaterThan(ranges.count, 1)
        for range in ranges {
            let seconds = Double(range.count) / G.sampleRate
            XCTAssertLessThanOrEqual(seconds, G.diarizationLimitSeconds,
                                     "a slice over the cap is a rejected request")
        }
    }

    /// Slices must tile the meeting exactly: a gap silently drops minutes of
    /// conversation, an overlap says everything twice.
    func testSlicesCoverTheMeetingWithoutGapOrOverlap() {
        let total = Int(97 * 60 * G.sampleRate) + 12_345
        let ranges = G.sliceRanges(totalSamples: total)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, total)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound)
        }
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, total)
    }

    func testAnEmptyRecordingProducesNoSlices() {
        XCTAssertTrue(G.sliceRanges(totalSamples: 0).isEmpty)
    }

    // MARK: - Parsing

    func testOffsetsArriveAsStringsWithATrailingS() {
        XCTAssertEqual(G.parseOffset("0.100s"), 0.1)
        XCTAssertEqual(G.parseOffset("12"), 12)
    }

    /// A missing timestamp must not become zero: zero places the word at the
    /// start of the meeting and takes the speaker mapping with it.
    func testAMissingOffsetIsAMissNotAZero() {
        XCTAssertNil(G.parseOffset(nil))
        XCTAssertNil(G.parseOffset("later"))
    }

    func testSpeakerLabelsAreParsedAndUnknownOnesShareOneBucket() {
        XCTAssertEqual(G.speakerIndex("spk_1"), 1)
        XCTAssertEqual(G.speakerIndex("spk_12"), 12)
        XCTAssertEqual(G.speakerIndex(nil), 0)
        XCTAssertEqual(G.speakerIndex("unknown"), 0)
    }

    // MARK: - Grouping

    /// Words become utterances, and an utterance ends where the speaker changes.
    func testWordsGroupIntoUtterancesAtEverySpeakerChange() {
        let words = [
            word("Hello", "spk_1", "0.0s", "0.4s"),
            word("there", "spk_1", "0.4s", "0.8s"),
            word("Hi", "spk_2", "1.0s", "1.3s"),
            word("back", "spk_1", "2.0s", "2.4s"),
        ]
        let utterances = G.utterances(from: words)
        XCTAssertEqual(utterances.map(\.transcript), ["Hello there", "Hi", "back"])
        XCTAssertEqual(utterances.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(utterances.first?.start, 0.0)
    }

    /// A slice starting twenty-five minutes in reports its words on the
    /// meeting's clock, or the energy comparison looks at the wrong audio and
    /// hands every line to the wrong speaker.
    func testASliceReportsOnTheMeetingsClockNotItsOwn() throws {
        let offset = G.maxSliceSeconds
        let utterances = G.utterances(
            from: [word("Later", "spk_1", "0.0s", "0.5s")], offsetSeconds: offset)
        let first = try XCTUnwrap(utterances.first)
        XCTAssertEqual(first.start, offset, accuracy: 0.001)
        XCTAssertEqual(first.end, offset + 0.5, accuracy: 0.001)
    }

    /// Words with no usable timestamp are dropped rather than placed at zero.
    func testUntimedWordsAreDropped() {
        let utterances = G.utterances(from: [
            word("solid", "spk_1", "1.0s", "1.4s"),
            word("floating", "spk_1", nil, nil),
        ])
        XCTAssertEqual(utterances.map(\.transcript), ["solid"])
    }

    func testNoWordsMeansNoUtterances() {
        XCTAssertTrue(G.utterances(from: []).isEmpty)
        XCTAssertTrue(G.utterances(from: [word("   ", "spk_1", "0s", "1s")]).isEmpty)
    }

    // MARK: - Request

    /// Speaker labels only exist in this exact combination; dropping any part
    /// of it silently returns a transcript with nobody attached to it.
    func testTheRequestAsksForDiarizationAndWordTimestamps() throws {
        let body = G.requestBody(fileURI: "files/abc")
        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        let config = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let transcription = try XCTUnwrap(config["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(transcription["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["uri"] as? String, "files/abc")
        XCTAssertEqual(input.first?["type"] as? String, "audio")
    }

    /// The key rides in a header. A key in a URL ends up in logs, proxies and
    /// crash reports.
    func testTheEndpointsCarryNoCredential() {
        XCTAssertFalse(G.interactionsURL().absoluteString.contains("key"))
        XCTAssertFalse(G.uploadStartURL().absoluteString.contains("key"))
    }

    // MARK: - Response

    func testWordsAreReadOutOfTheDocumentedResponseShape() throws {
        let json = """
        {"id":"interactions/x","status":"completed","steps":[{"id":"s","type":"model_output",
        "content":[{"type":"text","text":"Hello world","annotations":[
        {"type":"word_info","text":"Hello","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.450s"},
        {"type":"word_info","text":"world","speaker":"spk_2","start_offset":"0.500s","end_offset":"0.900s"}]}]}]}
        """
        let response = try JSONDecoder().decode(
            G.Response.self, from: Data(json.utf8))
        let words = G.words(from: response)
        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words.map(\.speaker), ["spk_1", "spk_2"])
        XCTAssertEqual(G.utterances(from: words).count, 2)
    }

    /// A response with no annotations is a transcript with no speakers, which
    /// is not what this path is for — it must fail so the caller falls back.
    func testAResponseWithoutAnnotationsYieldsNothingToFallBackFrom() throws {
        let json = """
        {"steps":[{"content":[{"type":"text","text":"Hello world"}]}]}
        """
        let response = try JSONDecoder().decode(G.Response.self, from: Data(json.utf8))
        XCTAssertTrue(G.words(from: response).isEmpty)
    }
}
