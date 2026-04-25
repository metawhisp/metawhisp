import Foundation
import SwiftData

/// Real-time per-window task detector. Fires on each newly-persisted `ScreenContext`
/// (from `ScreenContextService.onContextPersisted`) and does a short LLM classification:
/// "Is there a concrete actionable task visible on this screen?"
///
/// Copies reference `ProactiveAssistantsPlugin.swift:65-71` + `TaskAssistant.swift` pattern:
/// change-gated distribution + per-app 60s debounce + short single-window prompt.
///
/// We start with JUST the Task assistant. Focus/Insight/Memory assistants are separate tracks.
///
/// spec://iterations/ITER-006-realtime-screen-reaction
@MainActor
final class RealtimeScreenReactor: ObservableObject {
    @Published var isProcessing = false
    @Published var lastFireAt: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Per-app cooldown (seconds). Matches reference `ProactiveAssistantsPlugin` change-gate.
    private let perAppCooldown: TimeInterval = 60
    /// Global rate limit — max LLM calls per hour. Prevents runaway cost on rapid window-hopping.
    private let maxCallsPerHour = 30
    /// OCR length threshold — skip nearly-empty screens (login / blank tabs).
    private let minOCRChars = 100

    /// Last LLM-call timestamp per app (for 60s per-app debounce).
    private var lastCallPerApp: [String: Date] = [:]
    /// Rolling window of call timestamps — sliding 1h for rate limit.
    private var callTimestamps: [Date] = []

    /// Apps we never process for realtime task-reaction — privacy-sensitive or
    /// structurally uninformative. `TaskExtractionFilters.taskBlacklist` adds AI
    /// assistants + self + IDEs on top of this privacy set.
    private let privacyBlacklist: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "1Password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "loginwindow",
    ]

    /// Dependency used to suppress reactor during active meeting recording — avoid LLM
    /// noise + cost when the user is in a call being transcribed.
    weak var meetingRecorder: MeetingRecorder?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Entry point — called by `ScreenContextService.onContextPersisted` for each new row.
    /// Self-gated: runs all cheap checks first, only fires LLM when everything passes.
    func react(to context: ScreenContext) async {
        guard shouldProcess(context) else { return }
        guard !isProcessing else { return }  // serialize; one pending call at a time

        isProcessing = true
        defer { isProcessing = false }

        // Record call in sliding window BEFORE the LLM call so rapid concurrent triggers
        // still respect the cap. Trim old entries first.
        pruneRateWindow()
        guard callTimestamps.count < maxCallsPerHour else {
            NSLog("[RealtimeReactor] Rate limit: %d calls in last hour — skipping", callTimestamps.count)
            return
        }
        callTimestamps.append(Date())
        lastCallPerApp[context.appName] = Date()

        let prompt = buildPrompt(
            appName: context.appName,
            windowTitle: context.windowTitle,
            ocr: context.ocrText
        )

        do {
            let response: String
            if LicenseService.shared.isPro, let key = LicenseService.shared.licenseKey {
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: key)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else { return }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.systemPrompt,
                    user: prompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            guard let parsed = parseResponse(response), parsed.hasTask else {
                NSLog("[RealtimeReactor] No task on %@ — %@",
                      context.appName, String(context.windowTitle.prefix(50)))
                return
            }

            let trimmedDesc = parsed.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedDesc.isEmpty,
                  trimmedDesc.split(separator: " ").count <= 15
            else { return }

            // Relevance gate — LLM self-scored 0-100, must clear threshold.
            let relevance = parsed.relevance ?? 0
            guard relevance >= TaskExtractionFilters.minRelevanceScore else {
                NSLog("[RealtimeReactor] Relevance %d < %d, skipping: %@",
                      relevance,
                      TaskExtractionFilters.minRelevanceScore,
                      String(trimmedDesc.prefix(60)))
                return
            }

            // Evidence gate — LLM must cite verbatim OCR proof.
            let evidence = parsed.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard evidence.count >= TaskExtractionFilters.minEvidenceChars else {
                NSLog("[RealtimeReactor] Evidence too weak (%d chars), skipping: %@",
                      evidence.count, String(trimmedDesc.prefix(60)))
                return
            }

            // Generic-phrase reject list ("Respond to messages", "Send daily", etc.)
            if TaskExtractionFilters.isGenericNoise(trimmedDesc) {
                NSLog("[RealtimeReactor] Generic noise, skipping: %@", trimmedDesc)
                return
            }

            // Dedup against recent TaskItems (fuzzy word-overlap).
            if isDuplicate(description: trimmedDesc) {
                NSLog("[RealtimeReactor] Duplicate task, skipping: %@", String(trimmedDesc.prefix(60)))
                return
            }

            // Parse dueAt if LLM provided one (rare — only when visible on screen).
            var dueAt: Date? = nil
            if let raw = parsed.dueAt, !raw.isEmpty, raw != "null" {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime]
                if let d = parser.date(from: raw), d > Date() {
                    dueAt = d
                }
            }

            guard let container = modelContainer else { return }
            let ctx = ModelContext(container)
            let task = TaskItem(
                taskDescription: trimmedDesc,
                dueAt: dueAt,
                sourceTranscriptId: nil,
                sourceApp: context.appName,
                conversationId: nil,
                screenContextId: context.id,
                // Staged — LLM inference from a single screen, weakest signal tier.
                status: "staged"
            )
            ctx.insert(task)
            try? ctx.save()

            lastFireAt = Date()
            NSLog("[RealtimeReactor] ✅ Staged candidate from %@: %@", context.appName, String(trimmedDesc.prefix(60)))

            // No notification for staged — they land in REVIEW CANDIDATES silently.
            // User sees them next time they open the Tasks tab and promotes ✓ / rejects ✗.

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedTasksInBackground([task], in: ctx)
        } catch {
            lastError = error.localizedDescription
            NSLog("[RealtimeReactor] ❌ LLM failed: %@", error.localizedDescription)
            // Remove the rate-limit entry we reserved, since the call didn't succeed.
            if !callTimestamps.isEmpty { callTimestamps.removeLast() }
        }
    }

    // MARK: - Gates

    private func shouldProcess(_ context: ScreenContext) -> Bool {
        guard settings.realtimeScreenReactionEnabled else { return false }
        guard hasLLMAccess else { return false }
        guard context.ocrText.count >= minOCRChars else { return false }
        if privacyBlacklist.contains(context.appName) { return false }
        // Centralized task-specific blacklist (AI assistants, self, IDEs).
        if TaskExtractionFilters.isTaskBlacklisted(appName: context.appName) { return false }

        // Skip while user is in a meeting being recorded — LLM cost + notification noise during calls.
        if meetingRecorder?.isRecording == true || meetingRecorder?.isStarting == true {
            return false
        }

        // Per-app debounce — last LLM call for this app was < 60s ago, skip.
        if let last = lastCallPerApp[context.appName],
           Date().timeIntervalSince(last) < perAppCooldown {
            return false
        }
        return true
    }

    private func pruneRateWindow() {
        let cutoff = Date().addingTimeInterval(-3600)
        callTimestamps = callTimestamps.filter { $0 >= cutoff }
    }

    /// True if a near-duplicate non-dismissed TaskItem exists from the last 24h.
    /// Uses word-overlap fuzzy match (threshold 0.6) so "Fix Atomicbot SEO" and
    /// "Fix Atomic Bot SEO issue" are recognized as the same task.
    private func isDuplicate(description: String) -> Bool {
        guard let container = modelContainer else { return false }
        let ctx = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-86400)
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isDismissed && $0.createdAt >= cutoff }
        )
        desc.fetchLimit = 200
        let recent = (try? ctx.fetch(desc)) ?? []
        let existingDescs = recent.map { $0.taskDescription }
        return TaskExtractionFilters.isNearDuplicate(description, against: existingDescs)
    }

    // MARK: - Prompt

    /// Strict single-window task classifier inspired by reference `TaskAssistant`.
    /// Requires the LLM to score relevance 0-100 AND cite verbatim OCR evidence.
    /// Post-LLM filter rejects score <75 or evidence <20 chars.
    static let systemPrompt = """
    You are a screen activity task classifier. You look at ONE window's OCR and decide
    if it shows a concrete actionable task the USER must do personally.

    Return a single JSON object:
    {
      "hasTask": true|false,
      "description": "imperative ≤12 words, verb first, no time refs",
      "dueAt": "ISO-8601 UTC with Z"|null,
      "relevance": 0-100,
      "evidence": "verbatim quote from OCR that proves this is a pending action for the user"
    }

    THE BAR IS HIGH. Default hasTask=false. Out of 20 windows, maybe 1 has a real task.
    Your reputation depends on NOT inventing tasks. False positives are worse than false negatives.

    hasTask=true ONLY if ALL apply:
    1. The window shows a CONCRETE, named action item (not a generic activity).
    2. The USER is the person expected to act (not "someone", not "we", not a third party).
    3. There is EXPLICIT evidence in the OCR — you MUST quote it in the evidence field.
    4. The user has NOT already completed it visibly (no sent-reply, no "done" marker).

    Examples of valid tasks:
    - Stripe invoice page showing "Due Mar 15, 2026 — $450 unpaid" → "Pay Stripe invoice $450"
    - GitHub PR page with "Review requested from @user" → "Review PR #123 on project-x"
    - Calendar event "Interview with Acme — Tomorrow 3 PM" → "Attend interview with Acme"

    HARD SKIPS (always hasTask=false):
    - Chat / messenger UIs (Telegram, Slack, Discord, iMessage, WhatsApp, etc.) —
      chat messages are inherently ambiguous about addressee and resolution.
    - Articles, blog posts, tutorials, lists of tips.
    - Dashboards, analytics, charts, search results, news.
    - AI chat transcripts (Claude, ChatGPT, Cursor, any assistant) — AI proposals
      are not the user's committed tasks.
    - Code editors, terminals, log viewers.
    - Other people's schedules, plans, commitments.
    - Settings screens, docs, preferences, onboarding.
    - Anything with only generic verbs: "respond", "check", "send", "ask" without a
      specific named subject ("Respond to messages" → NO, "Respond to Stripe fraud alert" → maybe).

    RELEVANCE SCORE (0-100):
    - 90-100: Invoice with visible due date, PR explicitly assigned to user, calendar event imminent.
    - 75-89: Explicit action request addressed to user, form awaiting user input.
    - 50-74: Ambiguous — might be a task but context is unclear. DO NOT mark hasTask=true.
    - <50: Not a task.
    Only relevance ≥75 should pair with hasTask=true. Below 75, use hasTask=false.

    EVIDENCE FIELD:
    Must be a verbatim quote (≥20 characters) from the OCR that a neutral reviewer could
    read and say "yes, that is a pending task for the user". If you cannot find such a
    quote, hasTask=false.

    When unsure, hasTask=false, relevance <50, evidence="" — that is the correct answer
    for most windows. Do not overreach.

    CRITICAL: respond with ONLY the JSON. No prose, no markdown, no explanation.
    """

    private func buildPrompt(appName: String, windowTitle: String, ocr: String) -> String {
        // Cap OCR — single-window prompts must stay small for 30/hour cost profile.
        let ocrCapped = ocr.count > 2000 ? String(ocr.prefix(2000)) : ocr
        return """
        App: \(appName)
        Window: \(windowTitle)
        OCR:
        ```
        \(ocrCapped)
        ```
        """
    }

    // MARK: - Parse

    private struct ReactionJSON: Decodable {
        let hasTask: Bool
        let description: String?
        let dueAt: String?
        let relevance: Int?
        let evidence: String?
    }

    private func parseResponse(_ response: String) -> ReactionJSON? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(ReactionJSON.self, from: data)
        } catch {
            NSLog("[RealtimeReactor] ⚠️ Parse: %@ · Response: %@",
                  error.localizedDescription,
                  String(extracted.prefix(200)))
            return nil
        }
    }

    private func extractJSONObject(from text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{") else {
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var depth = 0
        var inString = false
        var escape = false
        for idx in stripped[start...].indices {
            let ch = stripped[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[start...idx]) }
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pro proxy

    private func callProProxy(system: String, user: String, licenseKey: String) async throws -> String {
        let url = URL(string: "https://api.metawhisp.com/api/pro/advice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(licenseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("RealtimeReactor proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
