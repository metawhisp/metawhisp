import Foundation

/// Optional meeting transcription on the user's own Gemini key.
///
/// Same bargain as the Deepgram option: real speaker labels from one pass, paid
/// for on the user's account, never touching our proxy or Pro quota. Any
/// failure falls through to the Whisper dual-stream path, so this can add
/// quality and cannot lose a meeting.
///
/// Two documented constraints shape the whole design (ai.google.dev, checked
/// 2026-08-27):
///
///   - Diarized audio is capped at **thirty minutes** per request. Of sixty-one
///     meetings recorded in the last thirty days, twenty-five ran longer — and
///     they carried seventy per cent of the minutes. A single-request
///     implementation would therefore have covered less than a third of the
///     audio it exists for, so the meeting is sent in slices.
///   - Speaker labels are per request: `spk_1` in one slice is not `spk_1` in
///     the next. That would normally make slicing unsafe. It is safe here only
///     because we never trusted those ids anyway — each speaker is resolved to
///     `Me`/`Them` by comparing microphone against system energy over their own
///     utterances, and that comparison is local to the slice.
final class GeminiMeetingTranscriber: @unchecked Sendable {

    /// The documented ceiling for diarized audio.
    static let diarizationLimitSeconds: Double = 30 * 60
    /// What we actually send. Under the ceiling on purpose: the limit is stated
    /// in minutes of audio and our duration is computed from sample counts, and
    /// arriving at exactly the boundary to argue about rounding is not worth a
    /// failed meeting.
    static let maxSliceSeconds: Double = 25 * 60
    static let sampleRate: Double = 16_000

    // MARK: - Response model (the subset we consume)

    /// One `word_info` annotation.
    struct WordInfo: Decodable, Equatable {
        let text: String
        let speaker: String?
        let startOffset: String?
        let endOffset: String?

        enum CodingKeys: String, CodingKey {
            case text
            case speaker
            case startOffset = "start_offset"
            case endOffset = "end_offset"
        }
    }

    struct Response: Decodable {
        struct Step: Decodable {
            struct Content: Decodable {
                let text: String?
                let annotations: [WordInfo]?
            }
            let content: [Content]?
        }
        let steps: [Step]?
    }

    enum GeminiError: LocalizedError {
        case http(Int, String)
        case uploadURLMissing
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Gemini HTTP \(code): \(body)"
            case .uploadURLMissing: return "Gemini upload did not return a session URL"
            case .emptyTranscript: return "Gemini returned no words"
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Sample ranges to send, each under the diarization ceiling.
    ///
    /// Cuts are hard rather than silence-aligned: a word straddling a cut is
    /// lost from one slice and picked up in the other at worst, whereas hunting
    /// for silence in a two-hour meeting is a second problem with its own
    /// failure modes. If that shows up in real transcripts it gets fixed with
    /// evidence, not pre-emptively.
    static func sliceRanges(totalSamples: Int) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        let per = Int(maxSliceSeconds * sampleRate)
        guard totalSamples > per else { return [0..<totalSamples] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < totalSamples {
            ranges.append(start..<min(totalSamples, start + per))
            start += per
        }
        return ranges
    }

    /// `"0.100s"` → `0.1`. A duration this API returns as a string, so a
    /// missing or malformed one has to be a miss rather than a silent zero:
    /// zero would place the word at the start of the meeting and drag the
    /// speaker mapping with it.
    static func parseOffset(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return Double(trimmed)
    }

    /// `"spk_1"` → `1`. Anything unparseable shares bucket zero, which is the
    /// honest answer: unknown speakers are one unknown speaker, not several.
    static func speakerIndex(_ label: String?) -> Int {
        guard let label else { return 0 }
        let digits = label.drop { !$0.isNumber }
        return Int(digits) ?? 0
    }

    /// The longest silence that still belongs inside one utterance.
    ///
    /// Deepgram hands back finished utterances; Gemini hands back words, so the
    /// grouping is ours to get right. Breaking only on a speaker change means
    /// two remarks by the same person twenty minutes apart become one utterance
    /// spanning twenty minutes — and the Me/Them decision is made by comparing
    /// channel energy ACROSS an utterance's window, so a window that wide
    /// averages the whole meeting and decides nothing.
    static let maxSilenceInsideUtterance: Double = 1.5

    /// Group consecutive words into utterances, breaking on a speaker change or
    /// on a silence longer than `maxSilenceInsideUtterance`.
    ///
    /// `offsetSeconds` moves a slice's timings back onto the meeting's own
    /// clock, which is what lets the energy comparison look at the right piece
    /// of audio for a slice that starts twenty-five minutes in.
    static func utterances(from words: [WordInfo],
                           offsetSeconds: Double = 0) -> [DeepgramMeetingTranscriber.DGUtterance] {
        var result: [DeepgramMeetingTranscriber.DGUtterance] = []
        var currentSpeaker: Int?
        var currentWords: [String] = []
        var start: Double = 0
        var end: Double = 0

        func flush() {
            guard let speaker = currentSpeaker, !currentWords.isEmpty else { return }
            result.append(.init(start: start + offsetSeconds,
                                end: end + offsetSeconds,
                                transcript: currentWords.joined(separator: " "),
                                speaker: speaker))
            currentWords = []
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let wordStart = parseOffset(word.startOffset) else { continue }
            let wordEnd = parseOffset(word.endOffset) ?? wordStart
            let speaker = speakerIndex(word.speaker)
            let silence = wordStart - end
            // A word timed BEFORE the run it would join is out of order, and
            // stretching the window backwards to swallow it would hand the
            // energy check audio from another turn. It starts a new one.
            let outOfOrder = !currentWords.isEmpty && wordStart < start
            if speaker != currentSpeaker
                || (!currentWords.isEmpty && silence > Self.maxSilenceInsideUtterance)
                || outOfOrder {
                flush()
                currentSpeaker = speaker
                start = wordStart
                end = wordStart
            }
            end = max(end, wordEnd)
            currentWords.append(text)
        }
        flush()
        return result
    }

    /// The transcription request. Verbatim mode with speaker diarization and
    /// word timestamps, which is the combination the thirty-minute cap applies
    /// to and the only one that produces speaker labels at all.
    static func requestBody(fileURI: String, mimeType: String = "audio/wav") -> [String: Any] {
        [
            "model": "gemini-3.5-transcribe",
            "input": [
                ["type": "audio", "uri": fileURI, "mime_type": mimeType]
            ],
            "generation_config": [
                "transcription_config": [
                    "mode": [
                        "type": "verbatim",
                        "diarization_mode": "speaker",
                        "timestamp_granularities": ["word"],
                    ]
                ]
            ],
        ]
    }

    static func interactionsURL() -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    }

    static func uploadStartURL() -> URL {
        URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
    }

    /// Pull every word annotation out of a response, in order.
    static func words(from response: Response) -> [WordInfo] {
        (response.steps ?? [])
            .flatMap { $0.content ?? [] }
            .flatMap { $0.annotations ?? [] }
    }

    // MARK: - Network

    /// One meeting, sliced under the diarization cap, rendered as the same
    /// «Me: …» / «Them: …» transcript the Whisper path produces — so recap,
    /// chat and extraction downstream see an identical format either way.
    func transcribe(mic: [Float], system: [Float], apiKey: String) async throws -> String {
        let total = max(mic.count, system.count)
        var allSegments: [StreamSegment] = []

        for range in Self.sliceRanges(totalSamples: total) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mw-gemini-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            _ = try DeepgramMeetingTranscriber.writeMixedWAV(
                mic: mic, system: system, to: tmp, range: range)

            let uri = try await upload(fileURL: tmp, apiKey: apiKey)
            let response = try await transcribeSlice(fileURI: uri, apiKey: apiKey)

            let offset = Double(range.lowerBound) / Self.sampleRate
            let utterances = Self.utterances(from: Self.words(from: response),
                                             offsetSeconds: offset)
            guard !utterances.isEmpty else { continue }

            // The mapping is computed per slice and against the FULL channel
            // buffers, because the utterance timings were just moved back onto
            // the meeting's clock.
            let mapping = DeepgramMeetingTranscriber.mapSpeakersToChannels(
                utterances: utterances,
                micEnergy: { DeepgramMeetingTranscriber.windowRMS(mic, startSec: $0, endSec: $1) },
                systemEnergy: { DeepgramMeetingTranscriber.windowRMS(system, startSec: $0, endSec: $1) })
            allSegments += DeepgramMeetingTranscriber.segments(
                utterances: utterances, mapping: mapping)
        }

        guard !allSegments.isEmpty else { throw GeminiError.emptyTranscript }
        NSLog("[Gemini] ✅ %d segments across %d slice(s)",
              allSegments.count, Self.sliceRanges(totalSamples: total).count)
        return DualStreamMerger.renderTranscript(allSegments)
    }

    /// Resumable upload: start to get a session URL, then send the bytes.
    /// Streamed from the file — a two-hour slice must never become a `Data`.
    private func upload(fileURL: URL, apiKey: String) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        var start = URLRequest(url: Self.uploadStartURL())
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(size)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": "meeting"]])

        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        guard let http = startResponse as? HTTPURLResponse else {
            throw GeminiError.uploadURLMissing
        }
        guard http.statusCode == 200 else {
            throw GeminiError.http(http.statusCode,
                                   String(data: startData, encoding: .utf8) ?? "")
        }
        guard let sessionURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let sessionURL = URL(string: sessionURLString) else {
            throw GeminiError.uploadURLMissing
        }

        var send = URLRequest(url: sessionURL)
        send.httpMethod = "POST"
        send.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        send.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        send.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        send.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: send, fromFile: fileURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GeminiError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct FileEnvelope: Decodable {
            struct File: Decodable { let uri: String }
            let file: File
        }
        return try JSONDecoder().decode(FileEnvelope.self, from: data).file.uri
    }

    private func transcribeSlice(fileURI: String, apiKey: String) async throws -> Response {
        var request = URLRequest(url: Self.interactionsURL())
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(fileURI: fileURI))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GeminiError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
