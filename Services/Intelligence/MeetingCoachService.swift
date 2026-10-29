import Foundation
import SwiftData

/// The in-call answers' service (ITER-076).
///
/// The class keeps its name and its `llmTier`/`llmServiceId` constants, so the
/// tier tests stay green, and it keeps the two things the in-call answers
/// need from the old coach: the summary prompt the rolling memo is written
/// with, and the memories of the people and projects that were mentioned.
///
/// The old coach pipeline — the thirty-second tick, the rolling summary of
/// the partials, the strict-JSON suggestion and its four kinds — is gone
/// (§3.10). The answers themselves live in `MeetingAnswerService`.
@MainActor
final class MeetingCoachService {
    /// The tier the in-call answers run on: the live overlay is the
    /// user-visible flagship surface, and quality there is non-negotiable.
    static let llmTier: LLMTier = .heavy
    static let llmServiceId: String = "MeetingCoachService"

    static let shared = MeetingCoachService()

    private weak var modelContainer: ModelContainer?

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Memory injection

    /// Pull UserMemory rows whose `subject` appears in the recent transcript.
    /// Cheap substring match — keeps it deterministic and fast. Returns up to
    /// 5 entries formatted as one-liners.
    ///
    /// Internal, not private: the in-call answers reuse it for the memories
    /// they show the model.
    func fetchRelevantMemoryContext(query: String) -> String {
        guard let container = modelContainer else { return "" }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<UserMemory>(predicate: #Predicate { !$0.isDismissed && !$0.needsReview })
        desc.fetchLimit = 500
        let all = (try? ctx.fetch(desc)) ?? []
        let lower = query.lowercased()
        var hits: [String] = []
        for mem in all {
            let subject = (mem.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard subject.count >= 3,
                  lower.contains(subject.lowercased())
            else { continue }
            let kind = mem.kind?.uppercased() ?? "FACT"
            let body = mem.characterization?.isEmpty == false ? mem.characterization! : mem.content
            hits.append("- \(kind) · \(subject) — \(body)")
            if hits.count >= 5 { break }
        }
        return hits.joined(separator: "\n")
    }

    // MARK: - The answer route

    /// The Pro call of the in-call answers.
    ///
    /// It keeps the status, the `Retry-After` and the text, and it takes the
    /// deadline the server honours.
    func proAnswer(system: String,
                   user: String,
                   deadlineMs: Int) async throws -> (status: Int, retryAfter: TimeInterval?, text: String?) {
        try await ProAdviceClient.live.call(system: system, user: user, deadlineMs: deadlineMs)
    }

    // MARK: - Prompt

    /// Compact summarizer prompt — used to fold older meeting content into a
    /// rolling 4-6 bullet summary. Plain text output, no JSON, no commentary.
    static let summaryPrompt = """
You are a meeting transcriptionist. Your job: maintain a tight running summary
of a live meeting in 4-6 bullet points. Track decisions, open questions, key
data points, and who said what. Drop low-value items as new content arrives.

Output ONLY the bullets — no preamble, no markdown headers, no explanation.
Match the conversation language.
"""
}

/// The Pro advice call, with the transport injected.
///
/// The transport is what the tests replace: the request the client builds and
/// the status it answers with are then the test's to read. The live transport
/// is the URL session.
@MainActor
final class ProAdviceClient {

    /// What the transport returns: the body and the answer of the server.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Where the prompt goes.
    static let endpoint = URL(string: "https://api.metawhisp.com/api/pro/advice")!

    private let transport: Transport
    private let lineTransport: MeetingAnswerLineTransport
    private let licenseKey: @MainActor () -> String?

    init(licenseKey: @escaping @MainActor () -> String?, transport: @escaping Transport,
         lineTransport: MeetingAnswerLineTransport? = nil) {
        self.licenseKey = licenseKey
        self.transport = transport
        self.lineTransport = lineTransport ?? { request in
            let (data, response) = try await transport(request)
            return MeetingAnswerStreamTransport.buffered(data, response: response)
        }
    }

    /// The live client: the URL session and the key of the signed-in session.
    static let live = ProAdviceClient(
        licenseKey: { LicenseService.shared.licenseKey },
        transport: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "ProAdvice", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "not an HTTP answer"])
            }
            return (data, http)
        },
        lineTransport: { request in try await MeetingAnswerStreamTransport.live(request) }
    )

    /// Whether there is a session to call with.
    var hasLicenseKey: Bool {
        !(licenseKey() ?? "").isEmpty
    }

    /// Posts the prompt and answers the status, the `Retry-After` and the text.
    func call(system: String,
              user: String,
              deadlineMs: Int) async throws -> (status: Int, retryAfter: TimeInterval?, text: String?) {
        guard let licenseKey = licenseKey(), !licenseKey.isEmpty else {
            // The session ended: the caller shows the sign-in line.
            return (401, nil, nil)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: MeetingCoachService.llmTier,
            serviceId: MeetingCoachService.llmServiceId,
            deadlineMs: deadlineMs
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(request)
        let retryAfter = Self.retryAfterSeconds(response)
        guard response.statusCode == 200 else {
            return (response.statusCode, retryAfter, nil)
        }
        struct ProResponse: Decodable { let text: String }
        let parsed = try? JSONDecoder().decode(ProResponse.self, from: data)
        return (200, retryAfter, parsed?.text)
    }

    /// Only card requests opt into the server's incremental response.
    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        MeetingAnswerStreamTransport.make(stopToken: stopToken, handle: handle) { [self] continuation in
            guard let key = licenseKey(), !key.isEmpty else {
                return MeetingAnswerReply(status: 401, retryAfter: nil, text: nil)
            }
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25
            var body = LLMRequestBody.proAdviceBody(system: system, user: user,
                                                   tier: MeetingCoachService.llmTier,
                                                   serviceId: MeetingCoachService.llmServiceId,
                                                   deadlineMs: deadlineMs)
            body["stream"] = true
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await MeetingAnswerStreamTransport.read(request: request, transport: lineTransport, format: .pro,
                                                               stopToken: stopToken, handle: handle, continuation: continuation)
        }
    }

    /// The `Retry-After` of the answer, in seconds.
    ///
    /// The header holds seconds or a date; both are read, so a rate limit
    /// always says how long to wait.
    nonisolated static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSinceNow
    }
}
