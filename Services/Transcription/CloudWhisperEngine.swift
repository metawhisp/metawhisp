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

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String] = []) async throws -> TranscriptionResult {
        let settings = await MainActor.run { AppSettings.shared }
        let isPro = await MainActor.run { LicenseService.shared.isPro }
        let licenseKey = await MainActor.run { LicenseService.shared.licenseKey }

        // Pro users → server proxy (no API key needed)
        if isPro, let key = licenseKey {
            return try await transcribeViaProxy(audioSamples: audioSamples, language: language, promptWords: promptWords, licenseKey: key)
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
            throw TranscriptionError.modelNotLoaded
        }

        return try await transcribeDirect(audioSamples: audioSamples, language: language, promptWords: promptWords, provider: provider, apiKey: apiKey)
    }

    /// Pro: send audio to our server proxy
    private func transcribeViaProxy(audioSamples: [Float], language: String?, promptWords: [String], licenseKey: String) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WAVEncoder.encode(samples: audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        NSLog("[CloudWhisper] PRO: Sending %.1fs audio to server proxy, WAV size: %d bytes", audioDuration, wavData.count)

        var urlStr = "https://api.metawhisp.com/api/pro/transcribe"
        var queryItems: [String] = []
        if let lang = language, lang != "auto" { queryItems.append("language=\(lang)") }
        if !promptWords.isEmpty { queryItems.append("prompt=\(promptWords.joined(separator: ", ").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") }
        if !queryItems.isEmpty { urlStr += "?" + queryItems.joined(separator: "&") }

        var request = URLRequest(url: URL(string: urlStr)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
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
            TranscriptionResult.Segment(text: $0.text, start: $0.start, end: $0.end)
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
        request.timeoutInterval = 60

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
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
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
            TranscriptionResult.Segment(text: $0.text, start: $0.start, end: $0.end)
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

    struct WhisperSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
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

    struct ProSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
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
