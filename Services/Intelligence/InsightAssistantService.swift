import Foundation
import SwiftData

/// Orchestrates the proactive insight pipeline (ITER-027 v1, text-only).
///
/// Flow per `evaluate(...)` call:
///   1. Build the user-prompt via `InsightPrompts.buildUserPrompt` (current
///      app + window + OCR + activity summary + previous insights).
///   2. POST `system` + `user` to the Pro proxy at `/api/pro/advice` —
///      mirrors `AdviceService.callProProxy` (existing well-trodden path).
///   3. Parse the response via `InsightOutputParser.parse(jsonString:)`.
///   4. Drop anything below the confidence threshold (default 0.75 — tuned
///      down from reference 0.85 for v1; user can raise via Settings).
///   5. Drop duplicates via `InsightDedupChecker.isDuplicate(candidate:recent:)`.
///   6. Return the kept `ExtractedInsight` so the caller can surface it.
///
/// State held: in-memory `recentInsights` rolling window for dedup. The
/// caller (ProactiveContextService) seeds this from `InsightStorage` on
/// app launch (ITER-027.4) so dedup survives restart.
///
/// Karpathy: this v1 service is deliberately one concrete class, no
/// `ProactiveAssistant` protocol. We extract the protocol when assistant
/// #2 (Focus / Memory / Goals) ships — not before.
@MainActor
final class InsightAssistantService: ObservableObject {
    /// ITER-041 — proactive insight generation on medium tier
    /// (gpt-oss-20b). Phase C will add a mini `/api/pro/gate` step before
    /// this call; ~80% of contexts get filtered out then.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "InsightAssistantService"

    // MARK: - Tunables

    /// Lowest confidence we accept for a `provide_advice` outcome. Below
    /// this we treat the LLM's own self-doubt as a signal to stay silent.
    /// 2026-08-08 — raised to the reference default 0.85 («high threshold —
    /// only show when very confident»). The v1 experiment at 0.75 let
    /// screen-echo junk through («Rerun Failed Agents» while the user is
    /// LOOKING at the failed-agents list — user: «бесполезные подсказки»);
    /// paired with the confidence RUBRIC in the prompt, 0.85 keeps only the
    /// mistake-prevention / genuinely non-obvious classes.
    var minConfidence: Double = 0.85

    /// Cap on the in-memory dedup window. Longer than the prompt's 30-cap
    /// so we keep dedup memory across multiple ticks even when the prompt
    /// only sees the most-recent slice.
    private let dedupWindow: Int = 50

    // MARK: - State

    /// Rolling window of recently-surfaced insights for dedup. Newest first.
    /// Seeded by caller from `InsightStorage` on launch.
    private(set) var recentInsights: [ExtractedInsight] = []

    /// `true` while a request is in flight. Caller (ProactiveContextService)
    /// already gates on its own `isRunning`; this is a second-line guard
    /// in case some other path calls us re-entrantly.
    private(set) var isEvaluating: Bool = false

    // MARK: - Public API

    /// Single evaluation tick. Returns the insight to surface, or `nil`
    /// when there's nothing worth showing (LLM said `no_advice`, parse
    /// failed, confidence below threshold, or duplicate).
    func evaluate(
        appName: String,
        windowTitle: String?,
        ocr: String,
        activitySummary: String,
        licenseKey: String
    ) async -> ExtractedInsight? {
        guard !isEvaluating else { return nil }
        isEvaluating = true
        defer { isEvaluating = false }

        // ITER-041 Phase C — cheap relevance gate (mini tier). Default to
        // skip unless the gate scores >= 0.65. Fail-open on errors so a
        // gate outage doesn't silently drop real signals. Most contexts
        // are uneventful — this is the primary cost-reduction lever.
        let gateContext = """
        \(appName) — \(windowTitle ?? "")
        OCR: \(String(ocr.prefix(2000)))
        Activity: \(activitySummary)
        """
        let gate = await GateClient.call(
            context: gateContext,
            purpose: .proactive,
            recentTopics: recentInsights.prefix(5).map { $0.body },
            serviceId: Self.llmServiceId,
            licenseKey: licenseKey
        )
        guard gate.shouldFire else {
            NSLog("[Insight] gate-skipped score=%.2f — %@",
                  gate.score, String(gate.reasoning.prefix(80)))
            return nil
        }

        let userPrompt = InsightPrompts.buildUserPrompt(
            appName: appName,
            windowTitle: windowTitle,
            ocr: ocr,
            activitySummary: activitySummary,
            previousInsights: recentInsights.map { $0.body }
        )

        let raw: String
        do {
            raw = try await callProProxy(
                system: InsightPrompts.systemPrompt,
                user: userPrompt,
                licenseKey: licenseKey
            )
        } catch {
            NSLog("[Insight] proxy error (graceful): %@", error.localizedDescription)
            return nil
        }

        switch InsightOutputParser.parse(jsonString: raw) {
        case let .provideInsight(insight):
            // Confidence floor — the LLM's own confidence acts as a soft
            // gate. We trust the model when it self-rates ≥ 0.90; for
            // mid-range we still ship; below `minConfidence` we bin.
            guard insight.confidence >= minConfidence else {
                NSLog("[Insight] dropped — confidence %.2f below floor %.2f: %@",
                      insight.confidence, minConfidence,
                      String(insight.body.prefix(80)))
                return nil
            }
            // Dedup against the rolling window. Survives restart because the
            // caller seeds `recentInsights` from `InsightStorage` at launch.
            if InsightDedupChecker.isDuplicate(candidate: insight, recent: recentInsights) {
                NSLog("[Insight] dropped — duplicate of recent: %@",
                      String(insight.body.prefix(80)))
                return nil
            }
            // Record + return.
            rememberLocally(insight)
            NSLog("[Insight] ✅ surfacing: %@ (conf=%.2f)",
                  String(insight.body.prefix(100)), insight.confidence)
            return insight

        case let .noInsight(reason):
            NSLog("[Insight] no advice: %@", reason)
            return nil

        case .parseError:
            NSLog("[Insight] parse error (graceful) — body=%@",
                  String(raw.prefix(200)))
            return nil
        }
    }

    /// Caller (ProactiveContextService) seeds the rolling dedup window at
    /// launch from `InsightStorage`. Trusted input — we replace whatever
    /// was there.
    func seedDedup(from history: [ExtractedInsight]) {
        recentInsights = Array(history.prefix(dedupWindow))
    }

    // MARK: - Internal

    /// Append `insight` to the front of `recentInsights`, evict overflow.
    private func rememberLocally(_ insight: ExtractedInsight) {
        recentInsights.insert(insight, at: 0)
        if recentInsights.count > dedupWindow {
            recentInsights.removeLast(recentInsights.count - dedupWindow)
        }
    }

    /// Pro proxy call. Mirrors `AdviceService.callProProxy`:
    /// POST `https://api.metawhisp.com/api/pro/advice` with JSON body
    /// `{ system, user }`, Bearer auth, 30s timeout, returns `{ text }`.
    private func callProProxy(
        system: String,
        user: String,
        licenseKey: String
    ) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            NSLog("[Insight] proxy ❌ HTTP %d: %@", http.statusCode, String(bodyStr.prefix(200)))
            throw NSError(
                domain: "InsightAssistantService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "proxy HTTP \(http.statusCode)"]
            )
        }
        struct ProResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(ProResponse.self, from: data)
        return decoded.text
    }
}
