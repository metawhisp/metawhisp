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

    /// Injected records, in the shape the evidence allowlist speaks.
    private func injectedRefs(from context: InsightContextPack)
        -> [InsightInvestigator.RetrievedRef] {
        context.bounded().allEntries.map { .init(id: $0.id, text: $0.text) }
    }

    /// What the last `evaluate` cost and did. Read by the caller straight after
    /// the call and written to the run's metrics row.
    ///
    /// A single field rather than a return value because the interesting case
    /// is the one that returns nothing: a run the gate skipped produces no
    /// `Evaluation`, and the skip is precisely the number worth having.
    private(set) var tally = ScreenAgentRunMetrics.Tally()

    // MARK: - Public API

    /// Single evaluation tick. Returns the insight to surface, or `nil`
    /// when there's nothing worth showing (LLM said `no_advice`, parse
    /// failed, confidence below threshold, or duplicate).
    /// ITER-069 — what evaluate() found, and where it found it. Retrieved
    /// records ride along so the caller can put them in the evidence allowlist:
    /// a claim grounded in the user's own stored requirement is grounded.
    struct Evaluation {
        let insight: ExtractedInsight
        let retrieved: [InsightInvestigator.RetrievedRef]
        /// Which rule sheet produced this. There are two routes and they use
        /// different texts; recording one identity for both made the journal's
        /// "which prompt edit changed the behaviour" query wrong (Codex).
        let promptVersion: String
    }

    func evaluate(
        appName: String,
        windowTitle: String?,
        ocr: String,
        activitySummary: String,
        licenseKey: String,
        history: [InsightInvestigator.Snapshot] = [],
        searchTasks: InsightInvestigator.StoreSearch? = nil,
        searchMemories: InsightInvestigator.StoreSearch? = nil,
        context: InsightContextPack = InsightContextPack()
    ) async -> Evaluation? {
        guard !isEvaluating else { return nil }
        isEvaluating = true
        defer { isEvaluating = false }
        // Reset per run. One evaluation at a time (the guard above), so a
        // single field is the whole bookkeeping — no queue, no identity to get
        // wrong.
        tally = ScreenAgentRunMetrics.Tally()
        let runStartedAt = Date()
        defer { tally.totalMilliseconds = Int(Date().timeIntervalSince(runStartedAt) * 1000) }

        // ITER-041 Phase C — cheap relevance gate (mini tier). Default to
        // skip unless the gate scores >= 0.65. Fail-open on errors so a
        // gate outage doesn't silently drop real signals. Most contexts
        // are uneventful — this is the primary cost-reduction lever.
        let gateContext = """
        \(appName) — \(windowTitle ?? "")
        OCR: \(String(ocr.prefix(2000)))
        Activity: \(activitySummary)
        """
        let gateStartedAt = Date()
        let gate = await GateClient.call(
            context: gateContext,
            purpose: .proactive,
            recentTopics: recentInsights.prefix(5).map { $0.body },
            serviceId: Self.llmServiceId,
            licenseKey: licenseKey
        )
        tally.gateMilliseconds = Int(Date().timeIntervalSince(gateStartedAt) * 1000)
        tally.gateScore = gate.score
        // Whether this gate earns its keep is a ratio nobody could compute:
        // the skip went to the log, and the log is not readable from every
        // place this app is worked on. It goes to the database now.
        tally.gateOutcome = gate.failedOpen ? .failedOpen : (gate.shouldFire ? .fired : .skipped)
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
            previousInsights: recentInsights.map { $0.body },
            context: context
        )

        // ITER-027.6 — INVESTIGATION path (the content fix for «бесполезные
        // подсказки»): with history available, the model must dig through the
        // last 2h of screen activity with tools before it may advise. The
        // single-pass legacy call below stays as the no-history fallback.
        if !history.isEmpty {
            let transport: InsightInvestigator.Transport = { [weak self] messages, tools in
                guard let self else { throw CancellationError() }
                self.tally.toolTurnCount += 1
                self.tally.textModelCallCount += 1
                return try await self.callProxyTools(
                    system: InsightPrompts.investigationSystemPrompt,
                    messages: messages, tools: tools, licenseKey: licenseKey
                )
            }
            switch await InsightInvestigator.run(snapshots: history, userPrompt: userPrompt,
                                                 transport: transport,
                                                 searchTasks: searchTasks,
                                                 searchMemories: searchMemories) {
            case let .advice(insight, retrieved):
                guard let accepted = acceptCandidate(insight) else { return nil }
                // A record placed in the prompt is as citable as one the model
                // fetched: without this the grounding check meets a claim about
                // a real open task, finds no matching evidence, and kills the
                // comment as ungrounded.
                let cited = injectedRefs(from: context) + retrieved
                return Evaluation(insight: accepted, retrieved: cited,
                                  promptVersion: ScreenAgentPrompts.insightInvestigation.version)
            case let .none(reason):
                NSLog("[Insight] investigation → no advice: %@", String(reason.prefix(120)))
                return nil
            }
        }

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
            // Non-investigator path retrieves nothing.
            return acceptCandidate(insight).map {
                Evaluation(insight: $0, retrieved: injectedRefs(from: context),
                           promptVersion: ScreenAgentPrompts.insight.version)
            }

        case let .noInsight(reason):
            NSLog("[Insight] no advice: %@", reason)
            return nil

        case .parseError:
            NSLog("[Insight] parse error (graceful) — body=%@",
                  String(raw.prefix(200)))
            return nil
        }
    }

    /// Shared acceptance gate for BOTH paths (investigation + legacy single
    /// pass): confidence floor → dedup window → remember + return.
    private func acceptCandidate(_ insight: ExtractedInsight) -> ExtractedInsight? {
        // Confidence floor — the LLM's own confidence acts as a soft gate.
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
        rememberLocally(insight)
        NSLog("[Insight] ✅ surfacing: %@ (conf=%.2f)",
              String(insight.body.prefix(100)), insight.confidence)
        return insight
    }

    /// Codex P0 — undo a session-dedup entry for an insight a downstream guard
    /// rejected. Remembering happened at return time, so without this a
    /// rejection also silenced every equivalent retry for the whole session.
    func retract(_ insight: ExtractedInsight) {
        recentInsights.removeAll { $0.body == insight.body }
    }

    /// ITER-027.6 — tool-calling round-trip against the same worker endpoint
    /// MetaChat uses. Returns ONE model turn for the investigation loop;
    /// keeps the RAW tool arguments so the loop can echo them back verbatim.
    private func callProxyTools(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        licenseKey: String
    ) async throws -> InsightInvestigator.ModelTurn {
        let url = URL(string: "https://api.metawhisp.com/api/pro/chat-with-tools")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        let body: [String: Any] = [
            "system": system,
            "messages": messages,
            "tools": tools,
            "tier": Self.llmTier.rawValue,
            "service_id": Self.llmServiceId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Insight", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "chat-with-tools HTTP \(http.statusCode)",
            ])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Insight", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "malformed chat-with-tools response",
            ])
        }
        let text = (obj["text"] as? String) ?? ""
        guard let first = (obj["tool_calls"] as? [[String: Any]])?.first,
              let function = first["function"] as? [String: Any],
              let name = function["name"] as? String, !name.isEmpty else {
            return InsightInvestigator.ModelTurn(text: text, toolName: nil)
        }
        let rawArgs = (function["arguments"] as? String) ?? "{}"
        var parsedArgs: [String: Any] = [:]
        if let argsData = rawArgs.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            parsedArgs = parsed
        }
        return InsightInvestigator.ModelTurn(
            text: text,
            toolName: name,
            toolArgs: parsedArgs,
            toolArgsRaw: rawArgs,
            toolCallId: (first["id"] as? String) ?? UUID().uuidString
        )
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
            NSLog("[Insight] proxy ❌ HTTP %d — %@", http.statusCode, LLMRequestBody.proxyReason(data))
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
