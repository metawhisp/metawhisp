import Foundation

/// Meeting transcription using the user's Deepgram key. Mic and system audio
/// remain separate stereo channels, so attribution follows the audio source.
struct DeepgramMeetingTranscriber {

    // MARK: - Response model (the subset we consume)

    struct DGUtterance: Decodable, Equatable {
        let start: Double
        let end: Double
        let transcript: String
        let speaker: Int
    }

    /// Prerecorded utterances carry a scalar channel even without diarization.
    struct DGChannelUtterance: Decodable, Equatable {
        let start: Double
        let end: Double
        let transcript: String
        let channel: Int
        let speaker: Int?
    }

    struct DGResponse: Decodable {
        struct Metadata: Decodable {
            struct ModelInfo: Decodable {
                let name: String?
                let version: String?
            }
            let requestID: String?
            let duration: Double?
            let modelInfo: [String: ModelInfo]?

            enum CodingKeys: String, CodingKey {
                case requestID = "request_id"
                case duration
                case modelInfo = "model_info"
            }
        }
        struct Channel: Decodable {
            struct Alternative: Decodable {
                struct Word: Decodable {
                    let end: Double?
                }
                let transcript: String?
                let words: [Word]?
            }
            let alternatives: [Alternative]?
        }
        struct Results: Decodable {
            let utterances: [DGChannelUtterance]?
            let channels: [Channel]?
        }
        let metadata: Metadata?
        let results: Results?
    }

    enum DGError: LocalizedError {
        case http(Int, String)
        case emptyTranscript
        case recordingTooLarge

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Deepgram HTTP \(code): \(body)"
            case .emptyTranscript: return "Deepgram returned no utterances"
            case .recordingTooLarge: return "Recording is too large for a stereo WAV file"
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Honor the selected language; Auto uses multilingual recognition.
    /// The API key goes in the authorization header, never the URL.
    static func requestURL(language: String?) -> URL {
        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "multichannel", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: language ?? "multi"),
        ]
        return comps.url!
    }

    /// Map source channels, trim blanks, and merge on the recording clock.
    /// Mic precedes system when start times tie, regardless of response order.
    static func channelSegments(utterances: [DGChannelUtterance]) -> [StreamSegment] {
        func segments(channel: Int, speaker: Speaker) -> [StreamSegment] {
            utterances.filter { $0.channel == channel }.compactMap { utterance in
                let text = utterance.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return StreamSegment(text: text, startSec: utterance.start,
                                     endSec: utterance.end, speaker: speaker)
            }
        }
        return DualStreamMerger.mergeStreams(mic: segments(channel: 0, speaker: .me),
                                            system: segments(channel: 1, speaker: .them))
    }

    /// Shared cleanup precedes glossary correction; retain original dropped
    /// segments so the caller can write them to the recovery log.
    static func cleanChannelSegments(utterances: [DGChannelUtterance]) -> MeetingTranscriptSanitizer.SanitizeResult {
        let sanitized = MeetingTranscriptSanitizer.sanitize(channelSegments(utterances: utterances), policy: .preciseChannels)
        let corrected = sanitized.kept.map {
            StreamSegment(text: BrandGlossary.applyCorrections($0.text),
                          startSec: $0.startSec, endSec: $0.endSec, speaker: $0.speaker)
        }
        return MeetingTranscriptSanitizer.SanitizeResult(kept: corrected, dropped: sanitized.dropped)
    }

    static func renderChannelTranscript(_ result: MeetingTranscriptSanitizer.SanitizeResult) throws -> String {
        let transcript = DualStreamMerger.renderTranscript(result.kept)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DGError.emptyTranscript
        }
        return transcript
    }

    /// Counts and provider identifiers only. Both sent channels include the
    /// zero-padded tail; original source durations are labeled separately.
    static func diagnosticLine(response: DGResponse, micSampleCount: Int, systemSampleCount: Int,
                               cleanedSegments: [StreamSegment]) -> String {
        func seconds(_ value: Double?) -> String {
            guard let value else { return "unknown" }
            return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func identifier(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "unknown" }
            return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        }
        let metadata = response.metadata
        let models = (metadata?.modelInfo ?? [:]).sorted { $0.key < $1.key }.map {
            "\(identifier($0.key)):\(identifier($0.value.name))@\(identifier($0.value.version))"
        }
        let sentSeconds = Double(max(micSampleCount, systemSampleCount)) / 16_000
        let utterances = response.results?.utterances ?? []
        let channels = response.results?.channels ?? []
        var fields = [
            "[Deepgram] diag",
            "request_id=\(identifier(metadata?.requestID))",
            "models=[\(models.isEmpty ? "unknown" : models.joined(separator: ","))]",
            "sent_ch0_s=\(seconds(sentSeconds))", "sent_ch1_s=\(seconds(sentSeconds))",
            "source_ch0_s=\(seconds(Double(micSampleCount) / 16_000))",
            "source_ch1_s=\(seconds(Double(systemSampleCount) / 16_000))",
            "processed_s=\(seconds(metadata?.duration))",
        ]
        for channel in 0..<2 {
            let alternative = channels.indices.contains(channel) ? channels[channel].alternatives?.first : nil
            let utteranceChars = utterances.filter { $0.channel == channel }.reduce(0) { $0 + $1.transcript.count }
            let transcriptChars = (alternative?.transcript).map { String($0.count) } ?? "unknown"
            fields.append("ch\(channel){utterance_chars=\(utteranceChars),channel_transcript_chars=\(transcriptChars),last_word_end_s=\(seconds(alternative?.words?.last?.end))}")
        }
        let beforeChars = channelSegments(utterances: utterances).reduce(0) { $0 + $1.text.count }
        let afterChars = cleanedSegments.reduce(0) { $0 + $1.text.count }
        fields.append("total_chars_before_cleanup=\(beforeChars)")
        fields.append("total_chars_after_cleanup=\(afterChars)")
        return fields.joined(separator: " ")
    }

    /// Map each Deepgram speaker id to `Me`/`Them` by which channel carries
    /// more energy across that speaker's utterances. `micEnergy`/`systemEnergy`
    /// return the RMS of the respective RAW channel within a time window —
    /// injected as closures so the mapping is testable with synthetic audio.
    static func mapSpeakersToChannels(
        utterances: [DGUtterance],
        micEnergy: (_ startSec: Double, _ endSec: Double) -> Float,
        systemEnergy: (_ startSec: Double, _ endSec: Double) -> Float
    ) -> [Int: Speaker] {
        var micScore: [Int: Float] = [:]
        var sysScore: [Int: Float] = [:]
        for u in utterances {
            let weight = Float(max(0.1, u.end - u.start))
            micScore[u.speaker, default: 0] += micEnergy(u.start, u.end) * weight
            sysScore[u.speaker, default: 0] += systemEnergy(u.start, u.end) * weight
        }
        var mapping: [Int: Speaker] = [:]
        for spk in Set(utterances.map(\.speaker)) {
            mapping[spk] = (micScore[spk] ?? 0) >= (sysScore[spk] ?? 0) ? .me : .them
        }
        return mapping
    }

    /// Convert labeled utterances into the existing `StreamSegment` shape so
    /// the transcript renders through the SAME `DualStreamMerger.renderTranscript`
    /// («Me: …» / «Them: …») the Whisper path uses — downstream (recap, chat,
    /// extraction) sees an identical format either way.
    static func segments(
        utterances: [DGUtterance],
        mapping: [Int: Speaker]
    ) -> [StreamSegment] {
        utterances
            .filter { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                StreamSegment(
                    // Same brand-name corrections the Whisper meeting path
                    // applies per utterance (Codex review) — «бренды правим у
                    // всех ASR». Whisper-specific hallucination strippers are
                    // deliberately NOT applied: those artifacts are a Whisper
                    // failure mode, not Deepgram's.
                    text: BrandGlossary.applyCorrections(
                        $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines)),
                    startSec: $0.start,
                    endSec: $0.end,
                    speaker: mapping[$0.speaker] ?? .them
                )
            }
    }

    /// RMS of a channel window, sample-0-aligned with the Deepgram timeline
    /// (both channels and the mixed stream share the recorder's clock).
    static func windowRMS(_ samples: [Float], startSec: Double, endSec: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rawLo = Int(startSec * 16_000)
        let rawHi = Int(endSec * 16_000)
        // Codex review — a window ENTIRELY past this channel's end (channels can
        // differ in length; the utterance lives in the longer stream's tail)
        // must contribute ZERO energy, not the clamp-repeated last sample —
        // that flipped Me/Them for tail utterances.
        guard rawLo < samples.count, rawHi > 0, rawLo < rawHi else { return 0 }
        let lo = max(0, rawLo)
        let hi = min(samples.count, rawHi)
        guard lo < hi else { return 0 }
        var acc: Float = 0
        for i in lo..<hi { acc += samples[i] * samples[i] }
        return (acc / Float(hi - lo)).squareRoot()
    }

    // MARK: - WAV streaming (no full-meeting buffers in memory)

    /// Standard 44-byte RIFF header for 16 kHz mono 16-bit PCM.
    static func wavHeader(sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1); le16(1)                 // PCM, mono
        le32(16_000); le32(16_000 * 2)   // sample rate, byte rate
        le16(2); le16(16)                // block align, bits
        d.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        return d
    }

    /// Mix mic+system and stream the WAV to a temp FILE in slices — Codex
    /// review: materializing a full 2h mixed buffer + WAV Data spiked memory
    /// by ~700 MB on top of the retained channel buffers. Slice-wise mixing
    /// (same softClip math as `MeetingRecorder.mix`) keeps the overhead to
    /// ~2 MB regardless of meeting length; the upload then streams from disk.
    ///
    /// `range` writes one slice of the meeting rather than all of it. Gemini
    /// caps diarized audio at thirty minutes, so that path sends the meeting in
    /// pieces — and taking a slice by copying the arrays would put a hundred
    /// megabytes per channel back into memory, which is the exact spike this
    /// function exists to avoid. Absent, it writes the whole thing as before.
    static func writeMixedWAV(mic: [Float], system: [Float], to url: URL,
                              range: Range<Int>? = nil) throws -> Double {
        let bounds = range ?? 0..<max(mic.count, system.count)
        let offset = bounds.lowerBound
        let total = max(0, bounds.count)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: wavHeader(sampleCount: total))

        let slice = 1_048_576  // 1M samples ≈ 65s ≈ 2 MB of Int16 at a time
        var pcm = [Int16](repeating: 0, count: min(slice, total))
        var i = 0
        while i < total {
            let end = min(total, i + slice)
            let n = end - i
            for k in 0..<n {
                let j = offset + i + k
                let m: Float = j < mic.count ? mic[j] : 0
                let s: Float = j < system.count ? system[j] : 0
                let v = MeetingRecorder.softClip(m + s)
                pcm[k] = Int16(max(-1.0, min(1.0, v)) * 32767)
            }
            try pcm.withUnsafeBufferPointer { buf in
                try handle.write(contentsOf: Data(buffer: UnsafeBufferPointer(rebasing: buf[0..<n])))
            }
            i = end
        }
        return Double(total) / 16_000.0
    }

    /// Standard 44-byte RIFF header for 16 kHz stereo 16-bit PCM.
    static func stereoWAVHeader(frameCount: Int) throws -> Data {
        guard let frames = UInt64(exactly: frameCount) else { throw DGError.recordingTooLarge }
        let (dataBytes, dataOverflow) = frames.multipliedReportingOverflow(by: 4)
        let (riffBytes, riffOverflow) = dataBytes.addingReportingOverflow(36)
        guard !dataOverflow, !riffOverflow,
              dataBytes <= UInt64(UInt32.max), riffBytes <= UInt64(UInt32.max) else {
            throw DGError.recordingTooLarge
        }
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); le32(UInt32(riffBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); le32(16)
        le16(1); le16(2)
        le32(16_000); le32(64_000)
        le16(4); le16(16)
        data.append(contentsOf: "data".utf8); le32(UInt32(dataBytes))
        return data
    }

    /// Stream interleaved mic/system frames, padding the shorter source with
    /// zeroes. Only one PCM slice is allocated, independent of meeting length.
    static func writeStereoWAV(mic: [Float], system: [Float], to url: URL) throws -> Double {
        let total = max(mic.count, system.count)
        let header = try stereoWAVHeader(frameCount: total)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)

        let slice = 1_048_576
        var pcm = [Int16](repeating: 0, count: min(slice, total) * 2)
        func sample(_ value: Float) -> Int16 {
            Int16(max(-1.0, min(1.0, MeetingRecorder.softClip(value))) * 32767).littleEndian
        }
        var i = 0
        while i < total {
            let end = min(total, i + slice)
            let count = end - i
            for k in 0..<count {
                let j = i + k
                pcm[k * 2] = sample(j < mic.count ? mic[j] : 0)
                pcm[k * 2 + 1] = sample(j < system.count ? system[j] : 0)
            }
            try pcm.withUnsafeBufferPointer { buffer in
                try handle.write(contentsOf: Data(buffer: UnsafeBufferPointer(rebasing: buffer[0..<(count * 2)])))
            }
            i = end
        }
        return Double(total) / 16_000
    }

    // MARK: - Network

    /// One-pass transcription of a whole meeting. The WAV streams from a temp
    /// file (never a full in-memory body); generous timeout for long uploads.
    func transcribe(mic: [Float], system: [Float], apiKey: String, language: String?) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-meeting-\(UUID().uuidString).wav")
        let seconds = try Self.writeStereoWAV(mic: mic, system: system, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var req = URLRequest(url: Self.requestURL(language: language))
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
        NSLog("[Deepgram] Uploading %.0fs meeting (%.1f MB, streamed from disk) for multichannel transcription",
              seconds, Double(sizeBytes) / 1_048_576.0)
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: tmp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw DGError.http(code, body)
        }

        let decoded = try JSONDecoder().decode(DGResponse.self, from: data)
        let sanitized = Self.cleanChannelSegments(utterances: decoded.results?.utterances ?? [])
        NSLog("%@", Self.diagnosticLine(response: decoded, micSampleCount: mic.count,
                                       systemSampleCount: system.count, cleanedSegments: sanitized.kept))
        NSLog("[Deepgram] sanitize: %d kept, %d dropped - %d consecutive-duplicate, %d cross-channel-echo, %d foreign-language-fragment",
              sanitized.kept.count, sanitized.dropped.count,
              sanitized.dropped.filter { $0.reason == "consecutive-duplicate" }.count,
              sanitized.dropped.filter { $0.reason == "cross-channel-echo" }.count,
              sanitized.dropped.filter { $0.reason.hasPrefix("foreign-language-fragment") }.count)
        for drop in sanitized.dropped {
            SuspectTranscriptLog.append(drop.segment.text, reason: drop.reason,
                                        context: drop.segment.speaker == .me ? "Deepgram Me merged" : "Deepgram Them merged")
        }
        return try Self.renderChannelTranscript(sanitized)
    }
}
