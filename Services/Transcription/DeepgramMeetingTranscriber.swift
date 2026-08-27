import Foundation

/// ITER-054 — BYOK Deepgram diarization for meetings (founder decision
/// 2026-07-15: «юзер пусть вставит свой ключ на любом из тарифов»).
///
/// When the user pastes their OWN Deepgram API key in Settings, meetings are
/// transcribed in ONE pass: mic + system are mixed to a single mono stream and
/// sent to Deepgram `nova-3` with native diarization (`diarize=true`), which
/// returns per-utterance speaker labels from that one stream. Deepgram's
/// numeric speakers are then mapped to `Me`/`Them` by comparing per-utterance
/// channel energy (mic vs system) — the raw channel buffers are the source of
/// truth for who is who. Cost lands on the USER's Deepgram account; the
/// request never touches our worker, so it works on any tier and books no
/// Pro-quota minutes.
///
/// Failure of any kind falls back to the existing Whisper dual-stream path in
/// `AppDelegate.transcribeMeetingDualStream` — this feature can only add
/// quality, never lose a meeting.
struct DeepgramMeetingTranscriber {

    // MARK: - Response model (the subset we consume)

    struct DGUtterance: Decodable, Equatable {
        let start: Double
        let end: Double
        let transcript: String
        let speaker: Int
    }

    struct DGResponse: Decodable {
        struct Results: Decodable {
            let utterances: [DGUtterance]?
        }
        let results: Results?
    }

    enum DGError: LocalizedError {
        case http(Int, String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Deepgram HTTP \(code): \(body)"
            case .emptyTranscript: return "Deepgram returned no utterances"
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Request URL. `nova-3` + `language=multi` (code-switching: covers the
    /// RU/EN mix our users actually speak; per-language routing can come
    /// later). The API key goes in the Authorization HEADER — never the URL.
    static func requestURL() -> URL {
        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: "multi"),
        ]
        return comps.url!
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

    // MARK: - Network

    /// One-pass transcription of a whole meeting. The WAV streams from a temp
    /// file (never a full in-memory body); generous timeout for long uploads.
    func transcribe(mic: [Float], system: [Float], apiKey: String) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-meeting-\(UUID().uuidString).wav")
        let seconds = try Self.writeMixedWAV(mic: mic, system: system, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var req = URLRequest(url: Self.requestURL())
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
        NSLog("[Deepgram] Uploading %.0fs meeting (%.1f MB, streamed from disk) for diarized transcription",
              seconds, Double(sizeBytes) / 1_048_576.0)
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: tmp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw DGError.http(code, body)
        }

        let decoded = try JSONDecoder().decode(DGResponse.self, from: data)
        guard let utterances = decoded.results?.utterances, !utterances.isEmpty else {
            throw DGError.emptyTranscript
        }

        let mapping = Self.mapSpeakersToChannels(
            utterances: utterances,
            micEnergy: { Self.windowRMS(mic, startSec: $0, endSec: $1) },
            systemEnergy: { Self.windowRMS(system, startSec: $0, endSec: $1) }
        )
        let segs = Self.segments(utterances: utterances, mapping: mapping)
        NSLog("[Deepgram] ✅ %d utterances, %d speakers → Me/Them via channel energy",
              utterances.count, Set(utterances.map(\.speaker)).count)
        return DualStreamMerger.renderTranscript(segs)
    }
}
