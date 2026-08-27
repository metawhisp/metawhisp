import Foundation

/// Purpose tag for `/api/pro/gate` — drives the worker-side relevance
/// prompt and shows up in telemetry. Raw values are the wire protocol;
/// changing them is a backward-incompatible worker change.
enum GatePurpose: String, Codable, Equatable {
    case proactive
    case advice
    case reactor
    case meetingCoach = "meeting_coach"
}

/// Wire shape for `POST /api/pro/gate`.
struct GateRequest: Encodable {
    let context: String
    let purpose: String
    let recent_topics: [String]
    let service_id: String
}

/// Wire shape for the gate response.
struct GateResponse: Decodable, Equatable {
    let is_relevant: Bool
    let score: Double
    let reasoning: String
}

/// Cheap relevance gate (ITER-041 Phase C).
///
/// Two-stage flow: caller asks "is this context worth a heavy LLM call?"
/// → cheap mini-tier model returns `{is_relevant, score, reasoning}` →
/// caller fires the expensive generate only when `score >= threshold`.
///
/// Mirrors the omi `proactive_notification.RelevanceResult` pattern with
/// a default-false stance ("most contexts do NOT warrant action") — the
/// reference upstream that ITER-041 adapts. See spec for details.
///
/// Design notes:
///   - Threshold check is a PURE function (`shouldFire`) — unit-tested.
///   - HTTP wrapper FAIL-OPEN on error: returns true (proceed) so a gate
///     outage doesn't silently drop real signals.
///   - 10s timeout — the gate must be fast; if it hangs, fire heavy and
///     move on.
enum GateClient {
    /// Spec default — score below this skips the heavy call.
    static let defaultThreshold: Double = 0.65

    static let endpoint = URL(string: "https://api.metawhisp.com/api/pro/gate")!

    /// Pure: build request body. Tested in `GateClientTests`.
    static func buildRequest(
        context: String,
        purpose: GatePurpose,
        recentTopics: [String],
        serviceId: String
    ) -> GateRequest {
        return GateRequest(
            context: context,
            purpose: purpose.rawValue,
            recent_topics: recentTopics,
            service_id: serviceId
        )
    }

    /// Pure: threshold decision. NaN score → fail-open (fire). Tested.
    static func shouldFire(score: Double, threshold: Double) -> Bool {
        if score.isNaN { return true }
        return score >= threshold
    }

    /// HTTP wrapper. Returns the decision + score + reasoning, and whether the
    /// decision came from the gate or from it falling over. On any network /
    /// parse / non-200 error the answer is "fire" so nothing is silently
    /// dropped — but a gate that fails open all day and a gate that is passing
    /// everything look identical from the outside unless the difference is
    /// reported, so it is (Codex).
    static func call(
        context: String,
        purpose: GatePurpose,
        recentTopics: [String] = [],
        threshold: Double = defaultThreshold,
        serviceId: String,
        licenseKey: String
    ) async -> (shouldFire: Bool, score: Double, reasoning: String, failedOpen: Bool) {
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, 0, "empty context", false)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // gate must be FAST

        let body = buildRequest(
            context: context,
            purpose: purpose,
            recentTopics: recentTopics,
            serviceId: serviceId
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            NSLog("[Gate] body encode failed (fail-open): %@", error.localizedDescription)
            return (true, 1.0, "encode error, fail-open", true)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("[Gate] HTTP %d (fail-open) for purpose=%@", http.statusCode, purpose.rawValue)
                return (true, 1.0, "gate HTTP \(http.statusCode), fail-open", true)
            }
            let parsed = try JSONDecoder().decode(GateResponse.self, from: data)
            let fire = shouldFire(score: parsed.score, threshold: threshold)
            NSLog("[Gate] %@ score=%.2f → %@ (threshold=%.2f) — %@",
                  purpose.rawValue, parsed.score, fire ? "FIRE" : "SKIP", threshold,
                  String(parsed.reasoning.prefix(80)))
            return (fire, parsed.score, parsed.reasoning, false)
        } catch {
            NSLog("[Gate] error %@ (fail-open) for purpose=%@", error.localizedDescription, purpose.rawValue)
            return (true, 1.0, "gate error, fail-open", true)
        }
    }
}
