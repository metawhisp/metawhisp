import Foundation

/// Asks Jev, TypeSafe's decision model, through the Pro server (ITER-076 1.2).
///
/// The app holds no OpenRouter key: `POST /api/pro/decisions` carries the
/// user's Pro license, the state and the questions, and the server asks Jev,
/// trying again itself when Jev or a key fails. Every call ends in one of five
/// outcomes — marked `notSent` when its request never left the Mac — and the
/// caller acts only on `.answered`, whose answers fit the questions asked and
/// hold nothing else. The engine logs numbers only: the state is the user's
/// page and words.
struct JevEngine: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Refusal: Sendable, Equatable {
        /// No Pro license, or the server did not accept it.
        case noPro
        /// Today's Jev allowance for this license is used up; it renews at the next UTC day.
        case dailyLimit(retryAfter: Duration?)
        /// The owner switched the agent off on the server (ITER-076 stage 9d,
        /// № 27): its 503 with `X-Agent-Switch: off`. No outage — nothing to
        /// wait out or report.
        case switchedOff
    }

    enum Outcome: Sendable, Equatable {
        case answered(JevResponse)
        /// Jev could not answer now: no network, or the server's 503. Worth asking again later.
        case unavailable(retryAfter: Duration?)
        /// The request or the answer broke the contract. Nothing may be done on it.
        case invalid
        /// Time ran out first: the caller's, or the server's (504). A caller that
        /// was cancelled also gets this; it checks its own cancellation before
        /// counting a timeout.
        case timedOut
        case refused(Refusal)
        /// Refused here, before the request left the Mac — no license, a
        /// body the server would refuse, or too late to send (ITER-076 stage
        /// 8a): what the call came to, and nothing spent on it.
        indirect case notSent(Outcome)
    }

    static let endpoint = URL(string: "https://api.metawhisp.com/api/pro/decisions")!
    /// The header the server's switch answers with, `off`, on the agent's
    /// routes (ITER-076 stage 9d, № 27).
    static let switchHeader = "X-Agent-Switch"
    /// The Pro server refuses a larger body (`JEV_MAX_BODY_BYTES` in the worker).
    static let maxBodyBytes = 131_072

    private let licenseKey: @Sendable () async -> String?
    private let send: Send
    private let log: @Sendable (String) -> Void

    init(licenseKey: @escaping @Sendable () async -> String? = {
             await MainActor.run { JevEngine.proKey(isPro: LicenseService.shared.isPro, key: LicenseService.shared.licenseKey) }
         },
         send: @escaping Send = { try await URLSession.shared.data(for: $0) },
         log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.licenseKey = licenseKey
        self.send = send
        self.log = log
    }

    /// The license to send: only a Pro user's, and never an empty one.
    static func proKey(isPro: Bool, key: String?) -> String? {
        guard isPro, let key, !key.isEmpty else { return nil }
        return key
    }

    /// Asks `questions` about `state`, and gives up at `limit`, counted from
    /// this call: reading the license and encoding the state count too.
    func ask(_ questions: JevQuestionSet, state: some Encodable & Sendable, within limit: Duration) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        var outcome = Outcome.notSent(.timedOut)
        if !Task.isCancelled {
            // The exchange never throws: every failure is already an outcome,
            // so `nil` from the deadline means late or cancelled, never an error.
            outcome = await Deadline.run(within: limit) { [self] () async -> Outcome in
                await self.exchange(questions, state: state, until: started + limit)
            } ?? .timedOut
        }
        let ms = Int((clock.now - started) / .milliseconds(1))
        log("[Jev] \(Self.logName(outcome, cancelled: Task.isCancelled)) questions=\(questions.count) ms=\(ms)")
        return outcome
    }

    /// The work `ask` runs under its deadline. Internal for tests: a test runs
    /// it as a task already stopped. Callers use `ask`: this has no deadline of
    /// its own, no Stop check before it and no log line.
    func exchange(_ questions: JevQuestionSet, state: some Encodable & Sendable,
                  until cutoff: ContinuousClock.Instant) async -> Outcome {
        // Begun after Stop: not even the license is read.
        guard !Task.isCancelled else { return .notSent(.timedOut) }
        guard let key = await licenseKey(), !key.isEmpty else { return .notSent(.refused(.noPro)) }
        let left = cutoff - ContinuousClock.now
        let body: Data
        do {
            let encoder = JSONEncoder()
            // Sorted: Foundation's encoder keeps no key order of its own
            // (checked 2026-09-27), and the same request should be the same
            // bytes.
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            body = try encoder.encode(Body(state: state, questions: questions,
                                           deadlineMs: Self.serverDeadlineMs(for: left)))
        } catch {
            return .notSent(.invalid)
        }
        // The server would refuse it: it is never sent.
        guard body.count <= Self.maxBodyBytes else { return .notSent(.invalid) }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = max(1, left / .seconds(1))
        // Late work never sends: nobody waits for it, and the page would be
        // uploaded for nothing.
        guard !Task.isCancelled, ContinuousClock.now < cutoff else { return .notSent(.timedOut) }
        do {
            let (data, response) = try await send(request)
            return Self.outcome(for: data, response: response, asked: questions)
        } catch {
            return .unavailable(retryAfter: nil)
        }
    }

    private struct Body<State: Encodable>: Encodable {
        let state: State
        let questions: JevQuestionSet
        let deadlineMs: Int

        enum CodingKeys: String, CodingKey {
            case state, questions
            case deadlineMs = "deadline_ms"
        }
    }

    /// The server is asked to answer before the app stops waiting, so a late
    /// Jev comes back as the server's own 504 rather than as silence. A limit
    /// counts as 120.75 s at most, so a long call still asks for the full
    /// 120 s the advice route takes (decisions takes 30 s; each clamps
    /// again), and as zero at least; converted whole, an unlimited or a
    /// hugely negative one would trap.
    static func serverDeadlineMs(for limit: Duration) -> Int {
        let ms = Int(min(max(limit, .zero), .milliseconds(120_750)) / .milliseconds(1))
        return ms > 1_500 ? ms - 750 : max(1, ms / 2)
    }

    static func outcome(for data: Data, response: URLResponse, asked: JevQuestionSet) -> Outcome {
        guard let http = response as? HTTPURLResponse else { return .unavailable(retryAfter: nil) }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 >= 0 ? Duration.seconds($0) : nil }
        switch http.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(JevResponse.self, from: data),
                  decoded.answers.problem(answering: asked) == nil else { return .invalid }
            return .answered(JevResponse(model: decoded.model, answers: decoded.answers.restricted(to: asked),
                                         usage: decoded.usage))
        case 401:
            return .refused(.noPro)
        case 429:
            return .refused(.dailyLimit(retryAfter: retryAfter))
        case 504:
            return .timedOut
        case 503 where http.value(forHTTPHeaderField: switchHeader) == "off":
            return .refused(.switchedOff)
        case 400..<500 where ![403, 404, 408].contains(http.statusCode):
            // A request refused as it was would fail the same way again.
            return .invalid
        default:
            return .unavailable(retryAfter: retryAfter)
        }
    }

    /// A cancelled call that came to nothing is logged as cancelled, not as a
    /// timeout; an answer that arrived first is logged as what it was.
    static func logName(_ outcome: Outcome, cancelled: Bool) -> String {
        if cancelled, outcome == .timedOut { return "cancelled" }
        return switch outcome {
        case .notSent(let refused): logName(refused, cancelled: cancelled)
        case .answered: "answered"
        case .unavailable: "unavailable"
        case .invalid: "invalid"
        case .timedOut: "timed_out"
        case .refused(.noPro): "refused_no_pro"
        case .refused(.dailyLimit): "refused_daily_limit"
        case .refused(.switchedOff): "refused_switched_off"
        }
    }
}
