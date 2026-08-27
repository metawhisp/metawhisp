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

    // MARK: - Grouping, the hard cases

    /// The defect this file caught. Gemini returns words, not utterances, so
    /// breaking only on a speaker change joins two remarks by the same person
    /// twenty minutes apart into one utterance twenty minutes wide. The Me/Them
    /// decision compares channel energy ACROSS that window, and a window that
    /// wide averages the entire meeting and decides nothing.
    func testASilenceEndsTheUtteranceEvenWhenTheSpeakerDoesNotChange() {
        let words = [
            word("Before", "spk_1", "10.0s", "10.4s"),
            word("After", "spk_1", "1210.0s", "1210.4s"),
        ]
        let utterances = G.utterances(from: words)
        XCTAssertEqual(utterances.count, 2, "twenty minutes of silence is not one utterance")
        XCTAssertEqual(utterances.map(\.transcript), ["Before", "After"])
        for utterance in utterances {
            XCTAssertLessThan(utterance.end - utterance.start, 5,
                              "an utterance window must stay tight enough to measure")
        }
    }

    /// A natural pause inside a sentence must not split it — the point is turn
    /// boundaries, not breathing.
    func testAShortPauseKeepsOneUtteranceTogether() {
        let words = [
            word("One", "spk_1", "1.0s", "1.3s"),
            word("two", "spk_1", "2.0s", "2.3s"),
        ]
        XCTAssertEqual(G.utterances(from: words).map(\.transcript), ["One two"])
    }

    /// Timestamps that arrive out of order must not stretch a window backwards
    /// over somebody else's turn.
    func testAWordTimedBeforeItsRunStartsANewOne() {
        let words = [
            word("second", "spk_1", "20.0s", "20.4s"),
            word("first", "spk_1", "1.0s", "1.4s"),
        ]
        let utterances = G.utterances(from: words)
        XCTAssertEqual(utterances.count, 2)
        for utterance in utterances {
            XCTAssertLessThanOrEqual(utterance.start, utterance.end,
                                     "an utterance cannot end before it begins")
        }
    }

    /// Every window handed to the energy comparison has to be a real interval.
    /// A zero-or-negative one reads as silence and flips the speaker.
    func testEveryUtteranceWindowIsUsable() {
        let words = (0..<40).map { i in
            word("w\(i)", i % 3 == 0 ? "spk_1" : "spk_2",
                 "\(Double(i) * 3.0)s", "\(Double(i) * 3.0 + 0.4)s")
        }
        for utterance in G.utterances(from: words) {
            XCTAssertLessThanOrEqual(utterance.start, utterance.end)
            XCTAssertFalse(utterance.transcript.isEmpty)
        }
    }

    /// `spk_0` is a real label from the API and unknown speakers also land on
    /// zero. They merge — worth knowing, because it means an unlabelled word
    /// joins whoever the API called speaker zero rather than becoming a ghost
    /// third participant. Pinned so a future change to either side is a
    /// decision rather than a surprise.
    func testUnknownSpeakersShareTheBucketWithSpeakerZero() {
        XCTAssertEqual(G.speakerIndex("spk_0"), G.speakerIndex(nil))
    }

    /// A slice exactly the size of the cap is one request, not two — an
    /// off-by-one here sends a second request carrying nothing.
    func testAMeetingExactlyOneSliceLongIsNotSplit() {
        let exact = Int(G.maxSliceSeconds * G.sampleRate)
        XCTAssertEqual(G.sliceRanges(totalSamples: exact).count, 1)
        XCTAssertEqual(G.sliceRanges(totalSamples: exact + 1).count, 2)
    }

    /// A response whose steps carry no content at all must not crash the
    /// decode — the API is in public preview and its shape can move.
    func testAnEmptyResponseDecodesToNothing() throws {
        for json in ["{}", "{\"steps\":[]}", "{\"steps\":[{}]}",
                     "{\"steps\":[{\"content\":[]}]}"] {
            let response = try JSONDecoder().decode(G.Response.self, from: Data(json.utf8))
            XCTAssertTrue(G.words(from: response).isEmpty, "failed on \(json)")
        }
    }
}
