import Foundation
import SwiftData

/// Hourly batch analyzer of ScreenContext → ScreenObservation + UserMemory + TaskItem records.
/// Omi's counterpart: `Rewind/Core/ObservationRecord` + `ProactiveExtractionRecord` (memory/task/insight from screenshots).
/// We batch by "visits" (consecutive same-app window) to fit Pro-proxy cost profile —
/// 60 min × 2 snapshots/min = 120 raw records → collapse to ~15 visits → 1 LLM call that produces
/// observations + memories + tasks in one shot.
///
/// spec://BACKLOG#Phase2.R1 + R2
@MainActor
final class ScreenExtractor: ObservableObject {
    @Published var isRunning = false
    @Published var lastRun: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Minimum seconds between consecutive records to count as "same visit".
    private let visitGapSeconds: TimeInterval = 60 * 5  // 5 min
    /// Max visits per batch call (trims prompt size).
    private let maxVisitsPerBatch = 20
    /// Preview chars from OCR per visit in the prompt.
    private let ocrPreviewChars = 300

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func startPeriodic(interval: TimeInterval = 3600) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.extractBatch()
            }
        }
        NSLog("[ScreenExtractor] ✅ Periodic started (interval: %.0fs)", interval)
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Manual trigger — analyze whatever's new since lastRun (or last hour if nil).
    func extractNow() async {
        await extractBatch()
    }

    // MARK: - Batch logic

    private func extractBatch() async {
        guard !isRunning else { return }
        guard settings.screenExtractionEnabled else { return }
        guard hasLLMAccess else {
            NSLog("[ScreenExtractor] No LLM access — skipping")
            return
        }
        guard let container = modelContainer else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        let ctx = ModelContext(container)
        let since = lastRun ?? Date().addingTimeInterval(-3600)

        // Fetch ScreenContexts since last run, oldest first.
        var descriptor = FetchDescriptor<ScreenContext>(
            predicate: #Predicate { $0.timestamp >= since },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = 500
        let contexts = (try? ctx.fetch(descriptor)) ?? []
        guard !contexts.isEmpty else {
            NSLog("[ScreenExtractor] No new screen contexts since %@", since.description)
            return
        }

        // Group into visits.
        let visits = collapseIntoVisits(contexts)
        guard !visits.isEmpty else { return }
        let trimmed = Array(visits.suffix(maxVisitsPerBatch))

        let prompt = buildPrompt(visits: trimmed)

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                NSLog("[ScreenExtractor] Analyzing %d visits via Pro proxy", trimmed.count)
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
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

            guard let parsed = parseResponse(response) else {
                NSLog("[ScreenExtractor] ⚠️ Parse failed")
                return
            }

            // 1. Persist observations (one per visit).
            var obsCount = 0
            for (i, obsJson) in parsed.observations.enumerated() where i < trimmed.count {
                let v = trimmed[i]
                let obs = ScreenObservation(
                    screenContextId: v.lastContextId,
                    appName: v.appName,
                    windowTitle: v.windowTitle,
                    contextSummary: obsJson.contextSummary,
                    currentActivity: obsJson.currentActivity,
                    hasTask: obsJson.hasTask,
                    taskTitle: obsJson.taskTitle,
                    sourceCategory: obsJson.category,
                    focusStatus: obsJson.focusStatus,
                    startedAt: v.startedAt,
                    endedAt: v.endedAt
                )
                ctx.insert(obs)
                obsCount += 1
            }

            // 2. Persist memories — linked back to the visit's ScreenContext.
            let existingMems = fetchRecentMemoryContents(in: ctx, limit: 100)
            var memCount = 0
            for memJson in (parsed.memories ?? []) where memJson.visitIndex < trimmed.count {
                let v = trimmed[memJson.visitIndex]
                let wordCount = memJson.content.split(separator: " ").count
                guard wordCount <= 15 else { continue }
                guard ["system", "interesting"].contains(memJson.category) else { continue }
                // Dedup against existing memories (exact content match — LLM's own semantic dedup is in prompt).
                let trimmedContent = memJson.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if existingMems.contains(where: { $0.caseInsensitiveCompare(trimmedContent) == .orderedSame }) {
                    continue
                }
                let confidence = memJson.confidence ?? 0.7
                guard confidence >= 0.6 else { continue }
                let mem = UserMemory(
                    content: trimmedContent,
                    category: memJson.category,
                    sourceApp: v.appName,
                    confidence: confidence,
                    windowTitle: v.windowTitle,
                    contextSummary: nil,
                    conversationId: nil,
                    screenContextId: v.lastContextId
                )
                ctx.insert(mem)
                memCount += 1
            }

            // 3. Persist tasks — linked to the visit's ScreenContext.
            let existingTasks = fetchRecentTaskDescriptions(in: ctx, limit: 100)
            var taskCount = 0
            let dueParser = ISO8601DateFormatter()
            dueParser.formatOptions = [.withInternetDateTime]
            for taskJson in (parsed.tasks ?? []) where taskJson.visitIndex < trimmed.count {
                let v = trimmed[taskJson.visitIndex]
                let trimmedDesc = taskJson.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let wordCount = trimmedDesc.split(separator: " ").count
                guard wordCount <= 15 else { continue }
                if existingTasks.contains(where: { $0.caseInsensitiveCompare(trimmedDesc) == .orderedSame }) {
                    continue
                }
                var due: Date? = nil
                if let raw = taskJson.dueAt, !raw.isEmpty, raw != "null" {
                    due = dueParser.date(from: raw)
                    if let d = due, d < Date() { due = nil }
                }
                let task = TaskItem(
                    taskDescription: trimmedDesc,
                    dueAt: due,
                    sourceTranscriptId: nil,
                    sourceApp: v.appName,
                    conversationId: nil,
                    screenContextId: v.lastContextId
                )
                ctx.insert(task)
                taskCount += 1
            }

            try? ctx.save()
            NSLog("[ScreenExtractor] ✅ %d observations, %d memories, %d tasks from %d visits",
                  obsCount, memCount, taskCount, trimmed.count)
        } catch {
            lastError = error.localizedDescription
            NSLog("[ScreenExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Visit collapsing

    /// A "visit" = consecutive ScreenContexts on the same app within gap threshold.
    private struct Visit {
        let appName: String
        let windowTitle: String?
        let startedAt: Date
        let endedAt: Date
        let ocrPreview: String
        let lastContextId: UUID?
    }

    private func collapseIntoVisits(_ contexts: [ScreenContext]) -> [Visit] {
        var visits: [Visit] = []
        var currentApp: String? = nil
        var currentStart: Date? = nil
        var currentEnd: Date? = nil
        var currentWindowTitle: String? = nil
        var currentOcrBuilder = ""
        var currentLastId: UUID? = nil
        var lastTime: Date? = nil

        func flush() {
            if let app = currentApp, let start = currentStart, let end = currentEnd {
                let preview = String(currentOcrBuilder.prefix(ocrPreviewChars))
                visits.append(Visit(
                    appName: app,
                    windowTitle: currentWindowTitle,
                    startedAt: start,
                    endedAt: end,
                    ocrPreview: preview,
                    lastContextId: currentLastId
                ))
            }
            currentApp = nil
            currentStart = nil
            currentEnd = nil
            currentWindowTitle = nil
            currentOcrBuilder = ""
            currentLastId = nil
        }

        for c in contexts {
            let gap = lastTime.map { c.timestamp.timeIntervalSince($0) } ?? 0
            let isNewVisit = c.appName != currentApp || gap > visitGapSeconds
            if isNewVisit {
                flush()
                currentApp = c.appName
                currentStart = c.timestamp
            }
            currentEnd = c.timestamp
            currentWindowTitle = c.windowTitle
            currentLastId = c.id
            if !c.ocrText.isEmpty, currentOcrBuilder.count < ocrPreviewChars {
                if !currentOcrBuilder.isEmpty { currentOcrBuilder += " " }
                currentOcrBuilder += c.ocrText.replacingOccurrences(of: "\n", with: " ")
            }
            lastTime = c.timestamp
        }
        flush()
        return visits
    }

    // MARK: - Prompt

    /// Inspired by Omi's observation + proactive extraction flow.
    /// Every visit produces an observation. Additionally, across all visits, extract durable facts
    /// (memories) and actionable tasks — linked back to the visit by index.
    static let systemPrompt = """
    You are an expert screen activity analyzer. You receive a batch of "visits" (continuous stretches on one app window).
    You produce THREE outputs in one JSON object:
    1. observations (EXACTLY one per visit, same order) — always generated.
    2. memories (0-5 total across the batch) — durable facts about the user observable on screen.
    3. tasks (0-5 total) — concrete actionable tasks observable on screen.

    OBSERVATIONS — one per visit:
    - contextSummary: 1 sentence, specific. "User reviewing Overchat GA4 traffic dashboard", NOT "User was in browser".
    - currentActivity: verb phrase 2-5 words. "Analyzing traffic decline", "Reviewing PR on GitHub".
    - hasTask: true if this visit showed concrete task the user should do. Browsing/reading is NOT a task.
    - taskTitle: ≤10 word imperative if hasTask. Else null.
    - category: one of — personal, education, health, finance, legal, philosophy, spiritual, science, entrepreneurship, parenting, romantic, travel, inspiration, technology, business, social, work, sports, politics, literature, history, architecture, music, weather, news, entertainment, psychology, real, design, family, economics, environment, other.
    - focusStatus: "focused" sustained work on one topic / "distracted" switching between unrelated topics / null unclear.

    MEMORIES — across all visits extract durable facts about the user. STRICT — same rules as voice memory extraction:
    - Named projects user works on ("User builds Overchat, an AI ChatGPT wrapper product").
    - Named people in network with role ("User's colleague Ivan Skladchikov handles Telegram bot MeetRecorder").
    - Specific preferences with reasoning ("User prefers PARA method for Obsidian vault organization").
    - Concrete commitments ("User plans to integrate Omi open-source API into MetaWhisp").
    - NO generic "User was in X app". NO "User is working on something" (vague).
    - Each memory ≤15 words, starts with "User" (or attribution for external wisdom).
    - Each memory includes visitIndex (0-based) pointing to most relevant visit.

    TASKS — actionable items visible on screen:
    - Concrete deadline-bearing items, follow-ups, explicit reminders visible in UI.
    - description ≤15 words, start with verb. Remove time refs.
    - dueAt ISO-8601 UTC with Z if visible in context. Omit otherwise.
    - Each task includes visitIndex (0-based).
    - SKIP tasks that are just reading UI text ("Click Send button" — NO).

    Output MUST have observations array with EXACTLY as many entries as visits. Memories and tasks CAN be empty arrays.

    Respond in the same language the screen content is in.

    Return JSON:
    {
      "observations": [{"contextSummary": "...", "currentActivity": "...", "hasTask": false, "taskTitle": null, "category": "work", "focusStatus": "focused"}],
      "memories": [{"visitIndex": 0, "content": "...", "category": "system", "confidence": 0.8}],
      "tasks": [{"visitIndex": 0, "description": "...", "dueAt": "2026-04-20T20:59:00Z"}]
    }

    CRITICAL OUTPUT RULE: Respond with ONLY the JSON object. No translation. No explanation. No markdown fences.
    """

    private func buildPrompt(visits: [Visit]) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        for (i, v) in visits.enumerated() {
            let start = df.string(from: v.startedAt)
            let end = df.string(from: v.endedAt)
            let title = v.windowTitle ?? ""
            lines.append("Visit \(i + 1) — \(v.appName) · \(start)-\(end) · \(title)")
            if !v.ocrPreview.isEmpty {
                lines.append("  OCR: \(v.ocrPreview)")
            }
            lines.append("")
        }
        let joined = lines.joined(separator: "\n")
        if joined.count > 20000 { return String(joined.prefix(20000)) }
        return joined
    }

    // MARK: - Response parse

    private struct ObservationJSON: Decodable {
        let contextSummary: String
        let currentActivity: String
        let hasTask: Bool
        let taskTitle: String?
        let category: String?
        let focusStatus: String?
    }
    private struct MemoryJSON: Decodable {
        let visitIndex: Int
        let content: String
        let category: String
        let confidence: Double?
    }
    private struct TaskJSON: Decodable {
        let visitIndex: Int
        let description: String
        let dueAt: String?
    }
    private struct BatchResult: Decodable {
        let observations: [ObservationJSON]
        let memories: [MemoryJSON]?
        let tasks: [TaskJSON]?
    }

    private func parseResponse(_ response: String) -> BatchResult? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BatchResult.self, from: data)
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
        request.timeoutInterval = 60

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("ScreenExtractor proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }

    // MARK: - Dedup helpers (cheap Swift-side check against last N entries)

    private func fetchRecentMemoryContents(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.content }
    }

    private func fetchRecentTaskDescriptions(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.taskDescription }
    }
}
