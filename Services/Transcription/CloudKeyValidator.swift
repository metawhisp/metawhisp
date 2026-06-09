import Foundation

/// Validates a BYOK cloud transcription key by probing the provider's `/models`
/// endpoint.
///
/// FREE-2: onboarding must confirm a key actually authenticates before counting
/// cloud as ready. A non-empty key can still be wrong and would only fail later,
/// mid-dictation, with a cryptic error.
enum CloudKeyValidator {

    /// Auth-check endpoint for a transcription provider id ("groq" / "openai").
    /// Pure → unit-tested.
    static func endpoint(provider: String) -> URL {
        switch provider {
        case "openai": return URL(string: "https://api.openai.com/v1/models")!
        default:       return URL(string: "https://api.groq.com/openai/v1/models")!
        }
    }

    /// `true` iff the key authenticates (HTTP 200) against the provider. Empty
    /// key, network error, timeout, or non-200 → `false` (never let an unproven
    /// key pass the onboarding gate).
    static func validate(key: String, provider: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: endpoint(provider: provider))
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
