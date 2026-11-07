import Foundation

/// Where one task or memory extraction attempt goes, chosen once per attempt:
/// the prompt is sized for this route and sent to this route, never sized for
/// one and sent to another.
enum ExtractionRoute: Equatable {
    case local
    case pro(licenseKey: String)
    case byok

    /// Today's rule, unchanged: the loaded local model first, then the Pro
    /// proxy when the license is Pro and has a key, else the user's own key.
    static func current(localReady: Bool, isPro: Bool, licenseKey: String?) -> ExtractionRoute {
        if localReady { return .local }
        if isPro, let licenseKey { return .pro(licenseKey: licenseKey) }
        return .byok
    }

    /// For the log: never the license key.
    var name: String {
        switch self {
        case .local: "local"
        case .pro: "pro"
        case .byok: "byok"
        }
    }

    /// The prompt's ceiling. Cloud routes, in UTF-16 units: Pro takes the
    /// whole meeting — the proxy accepts 128,000 units from the two
    /// extractors — and a user's own key keeps today's 20,000, its provider's
    /// limits not being ours to know. The local route keeps its own budget of
    /// 6,000, counted in Characters as `LocalLLMService` counts it; it is not
    /// a UTF-16 ceiling.
    var unitLimit: Int {
        switch self {
        case .local: 6_000
        case .pro: LLMRequestBody.extractionMaxPromptChars
        case .byok: 20_000
        }
    }

    /// The request both extractors send to `POST /api/pro/advice`. A whole
    /// meeting is a larger prompt than the 30 s the proxy used to be given:
    /// the proxy's provider chain is asked to finish within 55 s, and the app
    /// waits 60.
    static func proAdviceRequest(system: String, user: String, licenseKey: String,
                                 tier: LLMTier, serviceId: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.metawhisp.com/api/pro/advice")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let body = LLMRequestBody.proAdviceBody(system: system, user: user, tier: tier,
                                                serviceId: serviceId, deadlineMs: 55_000)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
