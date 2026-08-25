import Foundation
import SwiftData

/// Live meeting copilot — turns each 30s partial transcript into a focused
/// suggestion (question to ask / topic to cover / point to confirm) and pushes
/// it into `MeetingCoachState` for the floating overlay (ITER-019.2).
///
/// Why a separate service from `AdviceService`:
/// - **Different surface** — `AdviceService` posts macOS notification banners
///   that get hidden behind Zoom/Meet/Teams during a call; this one drives an
///   in-app overlay you can actually see.
/// - **Different prompt** — meeting prompts ask «what should the user say
///   next», not «what insight applies to this transcript».
/// - **Different cost** — re-uses the same per-30s LLM call cadence the live
///   advisor already runs, so there's no NEW per-meeting LLM spend.
@MainActor
final class MeetingCoachService {
    /// ITER-041 — live meeting coach overlay is the user-visible flagship
    /// surface. Stays on heavy tier (llama-3.3-70b) where quality is
    /// non-negotiable. Phase D will add a mini gate to skip ticks where
    /// no coachable moment exists.
    static let llmTier: LLMTier = .heavy
    static let llmServiceId: String = "MeetingCoachService"

    static let shared = MeetingCoachService()

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    /// EVERY partial since meeting start. We never drop them — older content
    /// gets folded into `meetingSummary` periodically so the prompt stays bounded
    /// while preserving long-term context. (Old design only kept the last 4
    /// chunks, so by minute 20 the LLM had no idea what was discussed in
    /// minute 1 — user complaint 2026-04-29: «обрывочные подсказки, не понимают
    /// весь контекст созвона».)
    private var allPartials: [String] = []
    /// Number of recent verbatim chunks fed to the LLM. ~2 min of recent flow.
    private let recentChunkCount = 4
    /// Re-summarize older content every N partials past the last summary.
    /// At 30s/partial that's 2 min of new content per summary call — keeps the
    /// summary fresh without burning an LLM call every 30s.
    private let summarizeEveryNPartials = 4
    private var partialIndexOfLastSummary: Int = 0
    /// Running summary of EARLIER meeting content. LLM-generated, replaces
    /// older partials in the prompt to stay under token budget.
    private var meetingSummary: String = ""
    /// Concurrency guard — drop a new chunk if we're still waiting on the LLM
    /// (better to skip one cycle than to stack 3 simultaneous calls).
    private var inFlight = false

    private weak var modelContainer: ModelContainer?

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Call from `LiveMeetingAdvisor.processChunk` after each successful
    /// partial transcribe. Updates the overlay's transcript tail immediately
    /// and kicks off (at most one) LLM call to extract the next suggestion.
    func process(partialText: String) async {
        // Strip Whisper hallucination tokens (DimaTorzok / Subtitles by /
        // amara.org / ♪ music markers) BEFORE anything else looks at the
        // text. Otherwise the rolling transcript tail shows garbage AND
        // the LLM coach invents «ASK» questions about non-existent topics
        // («Как связана проблема с видео MetaWhisp 1000 и ошибкой в vision
        // seed?» — observed 2026-05-23 from a transcript that was 80%
        // «Субтитры сделал DimaTorzok»). Reuses the same patterns the
        // dictation coordinator already strips so we don't duplicate the
        // toxic-token list.
        var trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let lower = trimmed.lowercased()
            if TranscriptionCoordinator.toxicHallucinationTokens.contains(where: { lower.contains($0) }) {
                trimmed = TranscriptionCoordinator.stripHallucinationTokens(trimmed)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !trimmed.isEmpty else { return }

        allPartials.append(trimmed)

        // Always update the visible transcript tail so the overlay feels live
        // even when the LLM call is still pending.
        let recent = allPartials.suffix(recentChunkCount).joined(separator: " ")
        MeetingCoachState.shared.updateTranscriptTail(recent)

        guard !inFlight else { return }
        guard hasLLMAccess else { return }

        inFlight = true
        MeetingCoachState.shared.isProcessing = true
        defer {
            inFlight = false
            MeetingCoachState.shared.isProcessing = false
        }

        // Refresh the rolling summary of older content if we've accumulated
        // enough new chunks. Skip when we don't have older content yet.
        let unsummarizedOld = allPartials.count - partialIndexOfLastSummary - recentChunkCount
        if unsummarizedOld >= summarizeEveryNPartials {
            await refreshMeetingSummary()
        }

        // Pull memory hits for entities mentioned in the recent window — the
        // LLM uses these for cross-meeting insights.
        let memoryContext = fetchRelevantMemoryContext(query: recent)

        do {
            let userPrompt = buildUserPrompt(recent: recent, memoryContext: memoryContext)
            var usedLocal = LocalLLMService.shared.isReady
            var response = try await callLLM(systemPrompt: Self.systemPrompt, userPrompt: userPrompt)
            var suggestion = parseSuggestion(response)
            // 2026-06-10 — user report: «копайлот не дает рекомендации».
            // Local Phi takes priority in callLLM, but small local models
            // routinely fail the strict-JSON suggestion format → parse
            // returned nil EVERY cycle and the coach stayed silent for the
            // whole meeting. If the local output didn't parse (and isn't an
            // explicit "null" verdict), retry ONCE via Pro/BYOK.
            if suggestion == nil, usedLocal,
               response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "null",
               LicenseService.shared.isPro || !settings.activeAPIKey.isEmpty {
                NSLog("[MeetingCoach] local output unparseable ('%@') — retrying via cloud",
                      String(response.prefix(120)))
                usedLocal = false
                response = try await callLLM(
                    systemPrompt: Self.systemPrompt, userPrompt: userPrompt, allowLocal: false
                )
                suggestion = parseSuggestion(response)
            }
            if let suggestion {
                MeetingCoachState.shared.addSuggestion(suggestion.kind, text: suggestion.text)
                NSLog("[MeetingCoach] ✅ %@ → %@", suggestion.kind.rawValue, String(suggestion.text.prefix(80)))
            } else {
                // Log the RAW response — "no actionable suggestion" hid the
                // difference between an honest `null` and a parse failure.
                NSLog("[MeetingCoach] no suggestion this cycle (local=%@, raw: '%@')",
                      usedLocal ? "YES" : "NO", String(response.prefix(160)))
            }
        } catch {
            NSLog("[MeetingCoach] ❌ LLM call failed: %@", error.localizedDescription)
        }
    }

    /// Reset state when a new meeting starts. Idempotent.
    func reset() {
        allPartials = []
        meetingSummary = ""
        partialIndexOfLastSummary = 0
        inFlight = false
    }

    // MARK: - Long-context summarization

    /// LLM-summarize the older portion of the meeting so the prompt stays
    /// bounded while preserving long-term context. Replaces (does not append to)
    /// `meetingSummary` so it stays compact.
    private func refreshMeetingSummary() async {
        let endIdx = allPartials.count - recentChunkCount
        guard endIdx > partialIndexOfLastSummary else { return }
        let older = allPartials[partialIndexOfLastSummary..<endIdx].joined(separator: " ")
        let body: String
        if meetingSummary.isEmpty {
            body = "Summarize the meeting so far in 4-6 bullet points. Track: who's speaking, decisions made, open questions, important data points. Keep it factual.\n\nMeeting transcript:\n\(older)"
        } else {
            body = "Update the running meeting summary with the new exchange. Keep 4-6 bullet points total — drop low-value items if needed. Preserve: who's speaking, decisions, open questions, data points.\n\nPRIOR SUMMARY:\n\(meetingSummary)\n\nNEW EXCHANGE:\n\(older)\n\nReturn the UPDATED summary only — no preamble, no markdown."
        }
        do {
            let summary = try await callLLM(systemPrompt: Self.summaryPrompt, userPrompt: body)
            meetingSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            partialIndexOfLastSummary = endIdx
            NSLog("[MeetingCoach] 📝 summary refreshed (%d chars, indexed at %d)", meetingSummary.count, partialIndexOfLastSummary)
        } catch {
            NSLog("[MeetingCoach] ⚠️ summary refresh failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Memory injection

    /// Pull UserMemory rows whose `subject` appears in the recent transcript.
    /// Cheap substring match — keeps it deterministic and fast. Returns up to
    /// 5 entries formatted as one-liners.
    private func fetchRelevantMemoryContext(query: String) -> String {
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

    // MARK: - Prompt builder

    private func buildUserPrompt(recent: String, memoryContext: String) -> String {
        var parts: [String] = []
        if !meetingSummary.isEmpty {
            parts.append("EARLIER IN THIS MEETING:\n\(meetingSummary)")
        }
        if !memoryContext.isEmpty {
            parts.append("WHAT YOU ALREADY KNOW (from prior meetings & notes):\n\(memoryContext)")
        }
        parts.append("RECENT (last ~2 minutes verbatim):\n\(recent)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - LLM access

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty
            || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }

    private func callLLM(systemPrompt: String, userPrompt: String, allowLocal: Bool = true) async throws -> String {
        // ITER-039 — local Phi takes priority for the meeting-coach loop:
        // small prompts, frequent (every 30s during a call), low-stakes
        // (one short hint per cycle). Local cuts ~$0.05/hour meeting cost
        // to zero. `allowLocal: false` = cloud retry after the local model
        // produced unparseable output (see `process`).
        if allowLocal, LocalLLMService.shared.isReady {
            return try await LocalLLMService.shared.completeBlocking(
                system: systemPrompt, user: userPrompt, maxTokens: 256
            )
        }
        if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
            return try await callProProxy(system: systemPrompt, user: userPrompt, licenseKey: licenseKey)
        }
        let apiKey = settings.activeAPIKey
        guard !apiKey.isEmpty else { throw NSError(domain: "MeetingCoach", code: 1) }
        let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
        return try await llm.complete(
            system: systemPrompt,
            user: userPrompt,
            apiKey: apiKey,
            provider: provider
        )
    }

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.metawhisp.com/api/pro/advice")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "MeetingCoach", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Proxy HTTP \(http.statusCode)"])
        }
        struct ProResponse: Decodable { let text: String }
        let parsed = try JSONDecoder().decode(ProResponse.self, from: data)
        return parsed.text
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

    /// Main suggestion prompt. 5-level depth scale — the LLM is explicitly told
    /// to AVOID surface-level "ask a clarifying question" suggestions and prefer
    /// observations rooted in cross-meeting / cross-conversation context.
    static let systemPrompt = """
You are a deeply attentive meeting copilot. The user is in a LIVE conversation
right now. You receive (1) a running summary of EARLIER content in this meeting,
(2) what you already know from PRIOR meetings + stored memories about the
people / projects mentioned, and (3) the verbatim last ~2 minutes.

Your job: surface the SINGLE most valuable observation that helps the user
think MORE CLEARLY about this conversation. Quality > frequency. Output
`null` if nothing meaningful applies.

DEPTH SCALE — prefer DEEPER over shallower:
  L1 ❌ AVOID: generic advice ("ask a clarifying question", "listen carefully").
       NEVER output these. They are noise.
  L2 ⚠️ Surface: a question rooted in just-said content, no broader context.
       Use only when nothing deeper fits.
  L3 ✓ Pattern: contradiction or unclear bridge between two parts of THIS
       meeting. ("They said X earlier, now Y — confirm reconciliation.")
  L4 ✓ Missed-topic: a relevant topic the meeting goal implies but the
       conversation hasn't reached. ("Budget hasn't been discussed yet.")
  L5 ✓✓ Cross-context: connects what's being said to PRIOR memories or
       past meetings. ("In the last 1-on-1 with this person you committed
       to Z — bring up status.") This is the highest-value insight.

OUTPUT — strict JSON, ONE of these shapes:
  {"type":"question","text":"<question to ask out loud, max 90 chars>"}
  {"type":"attention","text":"<thing worth noticing, max 90 chars>"}
  {"type":"missed","text":"<topic not yet covered, max 90 chars>"}
  {"type":"followUp","text":"<follow-up worth raising, max 90 chars>"}
  null

Hard rules:
- If your suggestion would land at L1 — output `null` instead.
- Suggestions MUST be specific to THIS conversation. No platitudes.
- Phrase as something the user could SAY OUT LOUD verbatim. No "you should ask".
- Match the conversation language. Don't translate.
- ONE suggestion only. No arrays.
- Plain JSON. No markdown, no code fence, no preamble.

Anti-patterns — output `null` instead of any of these:
- "What does <generic word> mean?" or "Что значит <фраза-связка>?" —
  filler conversational tokens («продолжение следует», «короче», «ну вот»,
  «короче говоря») are NOT topics to question.
- "How does <app/brand name> relate to <thing>?" — references to apps the
  user is RUNNING (MetaWhisp itself, Zoom, Slack, the browser, Telegram,
  ChatGPT, etc.) leaked from screen-context OCR are NOT meeting topics
  unless the participants actively discussed them. If the transcript
  doesn't show the speaker NAMING the app, treat any app/brand mention
  as background noise and ignore.
- "Can you elaborate on <X>?" without a concrete X grounded in the
  transcript — that's L1 generic. Skip.
- Speculative «why» questions about emotion/motivation — meetings deal
  in facts and decisions, not feelings.
"""

    private struct SuggestionJSON: Decodable { let type: String; let text: String }

    /// Internal (not private) so `MeetingCoachServiceTests` can pin the
    /// regression for the 2026-05-21 Range-crash fix.
    func parseSuggestion(_ raw: String) -> (kind: MeetingCoachState.Suggestion.Kind, text: String)? {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased() == "null" { return nil }
        if let parsed = decodeSuggestionJSON(cleaned) {
            return mapKind(parsed)
        }
        // Permissive fallback — find { ... } window if model added preamble.
        // CRASH FIX 2026-05-21: when the LLM emits `}` BEFORE the first `{`
        // (e.g. preamble like `cannot answer that } { "type": "question" ...`
        // with no closing brace after), `firstIndex(of: "{") > lastIndex(of: "}")`
        // and `cleaned[start...end]` constructs a reversed Range, killing the
        // app with `Fatal error: Range requires lowerBound <= upperBound`.
        // The other 10 LLM-JSON parsers in this codebase use brace-counting
        // (Services/Intelligence/MemoryExtractor.swift:463 and similar) which
        // is robust; here the naive firstIndex/lastIndex pair was the bug.
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            let slice = String(cleaned[start...end])
            if let parsed = decodeSuggestionJSON(slice) {
                return mapKind(parsed)
            }
        }
        return nil
    }

    private func decodeSuggestionJSON(_ s: String) -> SuggestionJSON? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SuggestionJSON.self, from: data)
    }

    private func mapKind(_ parsed: SuggestionJSON) -> (kind: MeetingCoachState.Suggestion.Kind, text: String)? {
        let kind: MeetingCoachState.Suggestion.Kind
        switch parsed.type.lowercased() {
        case "question": kind = .question
        case "attention": kind = .attention
        case "missed": kind = .missed
        case "followup", "follow_up", "follow-up": kind = .followUp
        default: return nil
        }
        return (kind, parsed.text)
    }
}
