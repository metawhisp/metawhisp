import Foundation

/// Cloud transcription provider configuration.
enum CloudTranscriptionProvider: String, CaseIterable, Identifiable {
    case groq = "groq"
    case openai = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: "Groq"
        case .openai: "OpenAI"
        }
    }

    var subtitle: String {
        switch self {
        case .groq: "Whisper large-v3-turbo · free tier · fastest"
        case .openai: "Whisper-1 · $0.006/min · reliable"
        }
    }

    var endpoint: URL {
        switch self {
        case .groq: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        case .openai: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }
    }

    var model: String {
        switch self {
        case .groq: "whisper-large-v3-turbo"
        case .openai: "whisper-1"
        }
    }
}

/// Cloud-based Whisper transcription engine using OpenAI-compatible audio API.
final class CloudWhisperEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Cloud Whisper"
    let supportsStreaming = false
    let supportsTranslation = true

    var isModelLoaded: Bool { true }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        // No-op: cloud engine is always ready
    }

    func unloadModel() async {
        // No-op
    }

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String], countUsage: Bool) async throws -> TranscriptionResult {
        let settings = await MainActor.run { AppSettings.shared }
        let isPro = await MainActor.run { LicenseService.shared.isPro }
        let licenseKey = await MainActor.run { LicenseService.shared.licenseKey }

        // Pro users → server proxy (no API key needed)
        if isPro, let key = licenseKey {
            return try await transcribeViaProxy(audioSamples: audioSamples, language: language, promptWords: promptWords, licenseKey: key, countUsage: countUsage)
        }

        // Free users → direct API call with own key
        let providerName = await MainActor.run { settings.cloudTranscriptionProvider }
        let provider = CloudTranscriptionProvider(rawValue: providerName) ?? .groq

        let apiKey: String = await MainActor.run {
            switch provider {
            case .groq: return settings.groqKey
            case .openai: return settings.openaiKey
            }
        }

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        return try await transcribeDirect(audioSamples: audioSamples, language: language, promptWords: promptWords, provider: provider, apiKey: apiKey)
    }

    /// Build the Pro-proxy transcribe URL. Pure + static so the query contract
    /// (esp. `count_usage=false` for un-metered meeting channels) is unit-tested
    /// without touching the network. Built via `URLComponents`/`URLQueryItem`
    /// so a crafted prompt/language value can NOT inject `&count_usage=false`
    /// and turn a metered request unmetered (Codex review). `count_usage` is
    /// emitted ONLY when false — absence means "bill it", matching the worker.
    static func proxyTranscribeURLString(language: String?, promptWords: [String], countUsage: Bool) -> String {
        var comps = URLComponents(string: "https://api.metawhisp.com/api/pro/transcribe")!
        var items: [URLQueryItem] = []
        if let lang = language, lang != "auto" { items.append(URLQueryItem(name: "language", value: lang)) }
        if !promptWords.isEmpty { items.append(URLQueryItem(name: "prompt", value: promptWords.joined(separator: ", "))) }
        if !countUsage { items.append(URLQueryItem(name: "count_usage", value: "false")) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.string ?? "https://api.metawhisp.com/api/pro/transcribe"
    }

    /// Pro: send audio to our server proxy
    /// ITER-060.4 — which transport failures deserve a QUICK retry. Fast-fail
    /// resolver/connect blips (Tailscale MagicDNS hiccup → «hostname could not
    /// be found», 2026-08-08) resolve within a second — retrying masks them.
    ///
    /// ONLY pre-send failures are retryable (Codex 2026-08-08): with these the
    /// request never reached the server, so a retry cannot double-transcribe
    /// or double-bill. `networkConnectionLost` is excluded — it can fire AFTER
    /// the upload was accepted (server may have transcribed and billed while
    /// we lost the response), and these POSTs carry no idempotency key.
    /// timedOut already burned the full timeout (retry doubles the wait) and
    /// offline is not transient (fail fast so the Recovery save fires) — both
    /// excluded too.
    nonisolated static func isTransientTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// How long to give one transcribe request, scaled to the audio it carries.
    ///
    /// This was a flat 60 seconds regardless of payload. Dictation fits in that;
    /// meeting chunks do not. On 2026-08-24 six consecutive requests failed at
    /// exactly the 60-second mark — a 167.9s chunk, a 104.8s chunk and a 149.4s
    /// chunk, each attempted twice — and all three were dropped from the saved
    /// transcript. Successful chunks that morning topped out around 130s of
    /// audio, so the ceiling was landing mid-range, not at some extreme.
    ///
    /// Whether the 60 seconds was spent uploading or waiting for the server to
    /// finish is not something the client log can separate. A budget that grows
    /// with the audio covers both.
    ///
    /// The 60-second floor is deliberate: dictation is interactive, the user is
    /// waiting, and a fast honest failure into Recovery beats a long hang. The
    /// ceiling stops a dead server from holding a meeting finalize open forever.
    nonisolated static func requestTimeout(forAudioSeconds seconds: Double) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 600
        guard seconds.isFinite else { return seconds.isNaN ? floor : ceiling }
        guard seconds > 0 else { return floor }
        return min(ceiling, max(floor, 30 + seconds * 1.5))
    }

    /// URLSession data with a quick retry ladder for transient transport
    /// errors (400ms, 800ms). Dictation used to make ONE attempt — a single
    /// DNS blip failed the whole recording into Recovery.
    private func dataWithTransientRetry(for request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                guard attempt < 3, Self.isTransientTransportError(error) else { throw error }
                NSLog("[CloudWhisper] %@ transport blip (attempt %d/3): %@ — retrying", label, attempt, error.localizedDescription)
                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    private func transcribeViaProxy(audioSamples: [Float], language: String?, promptWords: [String], licenseKey: String, countUsage: Bool) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WAVEncoder.encode(samples: audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        NSLog("[CloudWhisper] PRO: Sending %.1fs audio to server proxy (meter=%@), WAV size: %d bytes",
              audioDuration, countUsage ? "yes" : "no", wavData.count)

        let urlStr = Self.proxyTranscribeURLString(language: language, promptWords: promptWords, countUsage: countUsage)

        var request = URLRequest(url: URL(string: urlStr)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = Self.requestTimeout(forAudioSeconds: audioDuration)

        let (data, response) = try await dataWithTransientRetry(for: request, label: "PRO")
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            NSLog("[CloudWhisper] PRO ❌ HTTP %d: %@", http.statusCode, String(body.prefix(300)))
            if let err = try? JSONDecoder().decode(ProErrorResponse.self, from: data) {
                throw TranscriptionError.transcriptionFailed(err.error)
            }
            throw TranscriptionError.transcriptionFailed("HTTP \(http.statusCode)")
        }

        let result = try JSONDecoder().decode(ProTranscribeResponse.self, from: data)
        NSLog("[CloudWhisper] PRO ✅ %d chars in %.1fs", result.text.count, processingTime)

        let segments = (result.segments ?? []).map {
            TranscriptionResult.Segment(text: $0.text, start: $0.start, end: $0.end,
                                        avgLogprob: $0.avgLogprob,
                                        compressionRatio: $0.compressionRatio,
                                        noSpeechProb: $0.noSpeechProb)
        }

        return TranscriptionResult(
            text: result.text,
            language: result.language ?? language,
            duration: audioDuration,
            processingTime: processingTime,
            segments: segments
        )
    }

    /// Free: direct API call with user's own key
    private func transcribeDirect(audioSamples: [Float], language: String?, promptWords: [String], provider: CloudTranscriptionProvider, apiKey: String) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WAVEncoder.encode(samples: audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        NSLog("[CloudWhisper] Sending %.1fs audio to %@ (%@), WAV size: %d bytes",
              audioDuration, provider.displayName, provider.model, wavData.count)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Same budget as the PRO path — a free-tier meeting chunks identically.
        request.timeoutInterval = Self.requestTimeout(forAudioSeconds: audioDuration)

        var body = Data()

        // model field
        body.appendFormField(named: "model", value: provider.model, boundary: boundary)

        // language field (optional)
        let lang = (language == nil || language == "auto") ? nil : language
        if let lang {
            body.appendFormField(named: "language", value: lang, boundary: boundary)
        }

        // prompt field (optional)
        if !promptWords.isEmpty {
            body.appendFormField(named: "prompt", value: promptWords.joined(separator: ", "), boundary: boundary)
        }

        // response_format
        body.appendFormField(named: "response_format", value: "verbose_json", boundary: boundary)

        // file field
        body.appendFileField(named: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData, boundary: boundary)

        // Closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Send request
        let (data, httpResponse) = try await dataWithTransientRetry(for: request, label: "BYOK")
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        if let http = httpResponse as? HTTPURLResponse {
            NSLog("[CloudWhisper] %@ HTTP %d (%.0fms)", provider.displayName, http.statusCode, processingTime * 1000)
            if http.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "(unreadable)"
                NSLog("[CloudWhisper] ❌ Error: %@", String(bodyStr.prefix(500)))
                if let err = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                    throw TranscriptionError.transcriptionFailed(err.error.message)
                }
                throw TranscriptionError.transcriptionFailed("HTTP \(http.statusCode)")
            }
        }

        // Parse response
        let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

        NSLog("[CloudWhisper] ✅ %@ returned %d chars in %.1fs (audio: %.1fs)",
              provider.displayName, text.count, processingTime, audioDuration)

        let segments = (response.segments ?? []).map {
            TranscriptionResult.Segment(text: $0.text, start: $0.start, end: $0.end,
                                        avgLogprob: $0.avgLogprob,
                                        compressionRatio: $0.compressionRatio,
                                        noSpeechProb: $0.noSpeechProb)
        }

        return TranscriptionResult(
            text: text,
            language: response.language ?? language,
            duration: audioDuration,
            processingTime: processingTime,
            segments: segments
        )
    }
}

// MARK: - Response types

private struct WhisperResponse: Decodable {
    let text: String
    let language: String?
    let segments: [WhisperSegment]?

    // B2: `verbose_json` carries per-segment confidence metrics. Optional because
    // not every provider/format guarantees them — absent → the gate keeps the
    // segment. Exposed on TranscriptionResult.Segment; the owner layer gates.
    struct WhisperSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
        let avgLogprob: Float?
        let compressionRatio: Float?
        let noSpeechProb: Float?

        enum CodingKeys: String, CodingKey {
            case text, start, end
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
            case noSpeechProb = "no_speech_prob"
        }
    }
}

private struct APIErrorResponse: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
}

private struct ProTranscribeResponse: Decodable {
    let text: String
    let language: String?
    let segments: [ProSegment]?

    // B2: the Pro proxy MAY forward Whisper's per-segment metrics. Optional — the
    // worker currently omits them, so absent → the gate keeps the segment.
    struct ProSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
        let avgLogprob: Float?
        let compressionRatio: Float?
        let noSpeechProb: Float?

        enum CodingKeys: String, CodingKey {
            case text, start, end
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
            case noSpeechProb = "no_speech_prob"
        }
    }
}

private struct ProErrorResponse: Decodable {
    let error: String
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendFormField(named name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFileField(named name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
