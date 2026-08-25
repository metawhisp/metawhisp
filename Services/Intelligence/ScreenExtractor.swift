import Foundation
import SwiftData

/// Hourly batch analyzer of ScreenContext → ScreenObservation + UserMemory + TaskItem records.
/// counterpart: `Rewind/Core/ObservationRecord` + `ProactiveExtractionRecord` (memory/task/insight from screenshots).
/// We batch by "visits" (consecutive same-app window) to fit Pro-proxy cost profile —
/// 60 min × 2 snapshots/min = 120 raw records → collapse to ~15 visits → 1 LLM call that produces
/// observations + memories + tasks in one shot.
/// spec://BACKLOG#Phase2.R1 + R2
@MainActor
final class ScreenExtractor: ObservableObject {
    /// ITER-041 — schema is the most complex in the codebase (3 arrays:
    /// observations + memories + tasks, with per-element nested fields).
    /// 8B-instant produced malformed JSON in production (PID 24170 ran with
    /// mini before today's fix: «Parse failed» repeated). Moved to medium
    /// tier; still ~4× cheaper than the historical heavy default.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "ScreenExtractor"

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

    /// ITER-053.1 — purge fence. «Delete screen history» bumps the epoch; an
    /// in-flight batch that started BEFORE the bump discards its results
    /// instead of re-inserting rows distilled from just-deleted OCR (Codex
    /// review: the LLM await window let deleted history reappear).
    private var purgeEpoch = 0
    func invalidatePendingWork() {
        purgeEpoch += 1
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
        }
        // ITER-053.1 purge fence — snapshot the epoch before any await.
        let epoch = purgeEpoch
        // Review fix — lastRun advances ONLY after a successful pass (or a
        // legitimately empty window); a parse failure used to permanently
        // skip the whole visits batch because defer stamped it processed.

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
            lastRun = Date()   // empty window — legitimately done
            NSLog("[ScreenExtractor] No new screen contexts since %@", since.description)
            return
        }

        // ITER-071.2 — visits come from the canonical table the live agent
        // writes, not from app/time reconstruction. Batch and realtime now
        // describe ONE reality. (Rows not covered by any canonical visit —
        // pre-cutover history still inside the window — take the legacy
        // collapse explicitly, so nothing is dropped silently.)
        let visitRecords = (try? ctx.fetch(FetchDescriptor<ContextVisitRecord>(
            predicate: #Predicate { $0.lastObservedAt >= since },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]))) ?? []
        let visits = canonicalVisits(for: contexts, records: visitRecords)
        guard !visits.isEmpty else { lastRun = Date(); return }
        // ITER-071 — the newest N are processed, and the checkpoint used to
        // jump past the rest anyway, so a busy hour silently lost its earlier
        // visits forever. Keep the checkpoint at the oldest visit that is
        // actually going to be looked at, and let the next pass pick up what
        // was left behind.
        let trimmed = Array(visits.suffix(maxVisitsPerBatch))
        let droppedCount = visits.count - trimmed.count
        let checkpointFloor: Date? = droppedCount > 0 ? trimmed.first?.startedAt : nil
        if droppedCount > 0 {
            NSLog("[ScreenExtractor] %d visits deferred to the next pass (batch cap %d)",
                  droppedCount, maxVisitsPerBatch)
        }

        let prompt = buildPrompt(visits: trimmed)

        do {
            let response: String
            // ITER-051 F1.3 — local model first (free + private), same priority
            // order as MemoryExtractor. Falls to cloud paths when not loaded.
            if LocalLLMService.shared.isReady {
                // ITER-057.5 — 384 tokens truncated the JSON (up to 20 observations
                // + memories + tasks), producing the hourly "Parse error" loop.
                response = try await LocalLLMService.shared.completeBlocking(
                    system: Self.systemPrompt, user: prompt,
                    maxUserChars: 6000, maxTokens: 1024)
            } else if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
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

            // ITER-053.1 purge fence — the user deleted screen history while
            // we were awaiting the LLM. Discard this batch: its visits were
            // built from rows that no longer exist.
            guard epoch == purgeEpoch else {
                NSLog("[ScreenExtractor] Batch discarded — screen history was purged mid-run")
                return
            }

            // 1. Persist observations (one per visit). Tolerant to missing LLM fields —
            // fill with defaults rather than drop the observation. Also floor endedAt to
            // startedAt + minVisitSeconds to prevent 0-duration rows (single-sample visits
            // previously had start == end, which broke dashboard "top apps by time").
            var obsCount = 0
            var newObservations: [ScreenObservation] = []
            for (i, obsJson) in (parsed.observations ?? []).enumerated() where i < trimmed.count {
                let v = trimmed[i]
                let durationFloor = AppSettings.shared.screenContextInterval
                let safeEnd = max(v.endedAt, v.startedAt.addingTimeInterval(durationFloor))
                let obs = ScreenObservation(
                    screenContextId: v.lastContextId,
                    appName: v.appName,
                    windowTitle: v.windowTitle,
                    contextSummary: obsJson.contextSummary ?? "",
                    currentActivity: obsJson.currentActivity ?? "",
                    hasTask: obsJson.hasTask ?? false,
                    taskTitle: obsJson.taskTitle,
                    sourceCategory: obsJson.category,
                    focusStatus: obsJson.focusStatus,
                    startedAt: v.startedAt,
                    endedAt: safeEnd
                )
                ctx.insert(obs)
                newObservations.append(obs)
                obsCount += 1
            }
            // ITER-053.4 slice 2 — fire-and-forget embeddings so
            // searchScreenHistory ranks these semantically (graceful nil-fail).
            if !newObservations.isEmpty {
                AppDelegate.shared?.embeddingService.embedScreenObservationsInBackground(newObservations, in: ctx)
            }

            // 2. Persist memories — linked back to the visit's ScreenContext.
            let existingMems = fetchRecentMemoryContents(in: ctx, limit: 100)
            var newMemories: [UserMemory] = []
            for memJson in (parsed.memories ?? []) where Self.isValidVisitIndex(memJson.visitIndex, count: trimmed.count) {
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
                // ITER-071.6 — a fact read off the screen is a PROPOSAL. It is
                // kept, so nothing is lost, but the assistant does not treat it
                // as something it knows about the user until the user says so.
                mem.needsReview = true
                ctx.insert(mem)
                newMemories.append(mem)
            }
            let memCount = newMemories.count

            // 3. Persist tasks — linked to the visit's ScreenContext.
            // Also collect them into `newTasks` so we can fire one notification per task after
            // the save commits — copying reference `TaskPromotionService.swift:84-90` pattern.
            let existingTasks = fetchRecentTaskDescriptions(in: ctx, limit: 100)
            var newTasks: [TaskItem] = []
            let dueParser = ISO8601DateFormatter()
            dueParser.formatOptions = [.withInternetDateTime]
            for taskJson in (parsed.tasks ?? []) where Self.isValidVisitIndex(taskJson.visitIndex, count: trimmed.count) {
                let v = trimmed[taskJson.visitIndex]
                // ITER-057.5 — whitelist: only conversation surfaces (messengers /
                // mail / work browser tabs) produce tasks. Same gate as the reactor.
                if !TaskExtractionFilters.isTaskAllowed(appName: v.appName, windowTitle: v.windowTitle) {
                    NSLog("[ScreenExtractor] Skipping task from non-whitelisted app %@: %@",
                          v.appName, String(taskJson.description.prefix(60)))
                    continue
                }
                let trimmedDesc = taskJson.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let wordCount = trimmedDesc.split(separator: " ").count
                guard wordCount <= 15 else { continue }
                // Relevance + evidence gates (reference-pattern staged→committed bar).
                let relevance = taskJson.relevance ?? 0
                guard relevance >= TaskExtractionFilters.minRelevanceScore else {
                    NSLog("[ScreenExtractor] Relevance %d < %d, skipping: %@",
                          relevance, TaskExtractionFilters.minRelevanceScore, String(trimmedDesc.prefix(60)))
                    continue
                }
                let evidence = taskJson.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // ITER-066 — the quote must occur in the preview the model was
                // shown. The preview is exactly its input, so a quote that is
                // not in it was not read off the screen, it was made up.
                guard ScreenAgentEvidence.normalize(v.ocrPreview)
                    .contains(ScreenAgentEvidence.normalize(evidence)) else {
                    NSLog("[ScreenExtractor] Task evidence not in visit OCR, skipping: %@",
                          String(trimmedDesc.prefix(60)))
                    continue
                }
                guard evidence.count >= TaskExtractionFilters.minEvidenceChars else {
                    NSLog("[ScreenExtractor] Evidence too weak (%d chars), skipping: %@",
                          evidence.count, String(trimmedDesc.prefix(60)))
                    continue
                }
                // Generic-phrase reject list.
                if TaskExtractionFilters.isGenericNoise(trimmedDesc) {
                    NSLog("[ScreenExtractor] Generic noise, skipping: %@", trimmedDesc)
                    continue
                }
                // ITER-032 — strict title validator (replaces reference's tool-loop
                // retry). Drops single-verb / too-short / vague-verb titles before
                // they hit the DB. Reference would feed these back to the LLM and
                // ask for a retry; we drop in code (single-shot architecture).
                if let reason = TaskExtractionFilters.validateTaskTitle(trimmedDesc) {
                    NSLog("[ScreenExtractor] Title rejected (%@): %@",
                          String(describing: reason), trimmedDesc)
                    continue
                }
                // Fuzzy dedup — 60% word overlap counts as a duplicate.
                if TaskExtractionFilters.isNearDuplicate(trimmedDesc, against: existingTasks) {
                    NSLog("[ScreenExtractor] Near-duplicate task, skipping: %@", String(trimmedDesc.prefix(60)))
                    continue
                }
                // Also avoid dup against tasks we're inserting in THIS batch.
                let batchDescs = newTasks.map { $0.taskDescription }
                if TaskExtractionFilters.isNearDuplicate(trimmedDesc, against: batchDescs) { continue }
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
                    screenContextId: v.lastContextId,
                    // Screen-inferred → staged bin. User promotes from review.
                    status: "staged"
                )
                ctx.insert(task)
                newTasks.append(task)
            }

            do {
                try ctx.save()
            } catch {
                // ITER-071 — this was `try?` followed by an unconditional
                // checkpoint, so a failed write was recorded as an hour
                // successfully processed and its observations were gone.
                NSLog("[ScreenExtractor] ❌ save failed (%@) — leaving the window unprocessed",
                      error.localizedDescription)
                return
            }
            // Only past what was actually looked at.
            lastRun = checkpointFloor ?? Date()
            NSLog("[ScreenExtractor] ✅ %d observations, %d memories, %d tasks from %d visits",
                  obsCount, memCount, newTasks.count, trimmed.count)

            // Staged candidates do NOT trigger macOS notifications — they land silently in
            // the REVIEW CANDIDATES bin. Only promoted (committed) tasks notify. This
            // matches the reference StagedTask flow and avoids notification spam from
            // low-confidence LLM inferences.
            // spec://iterations/ITER-007-staged-tasks

            // Fire-and-forget embeddings for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedMemoriesInBackground(newMemories, in: ctx)
            AppDelegate.shared?.embeddingService.embedTasksInBackground(newTasks, in: ctx)
        } catch {
            lastError = error.localizedDescription
            NSLog("[ScreenExtractor] ❌ Failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Visit collapsing

    /// A "visit" = consecutive ScreenContexts on the same app within gap threshold.
    struct Visit {
        let appName: String
        let windowTitle: String?
        let startedAt: Date
        let endedAt: Date
        let ocrPreview: String
        let lastContextId: UUID?
    }

    /// ITER-071.2 — build Visit structures from the canonical table the live
    /// agent writes. The rule US-071-3 exists for: batch analysis consumes the
    /// same immutable visit identity as realtime and never rebuilds visits
    /// from app name plus five-minute gaps. Contexts not covered by any
    /// canonical visit (pre-cutover rows still inside the window) take the
    /// legacy collapse explicitly — processed, never silently dropped.
    nonisolated func canonicalVisits(
        for contexts: [ScreenContext],
        records: [ContextVisitRecord]
    ) -> [Visit] {
        let byID = Dictionary(contexts.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var covered = Set<UUID>()
        var visits: [Visit] = []
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let frames = record.frameIDs
                .compactMap { byID[$0] }
                .sorted { $0.timestamp < $1.timestamp }
            guard !frames.isEmpty else { continue }
            frames.forEach { covered.insert($0.id) }
            var ocr = ""
            for frame in frames where !frame.ocrText.isEmpty && ocr.count < ocrPreviewChars {
                if !ocr.isEmpty { ocr += " " }
                ocr += frame.ocrText.replacingOccurrences(of: "\n", with: " ")
            }
            visits.append(Visit(
                appName: record.appName,
                windowTitle: record.rawTitle,
                startedAt: record.startedAt,
                endedAt: record.endedAt ?? record.lastObservedAt,
                ocrPreview: String(ocr.prefix(ocrPreviewChars)),
                lastContextId: frames.last?.id))
        }
        let uncovered = contexts.filter { !covered.contains($0.id) }
        let legacy = collapseIntoVisits(uncovered)
        return (visits + legacy).sorted { $0.startedAt < $1.startedAt }
    }

    /// Internal (not private) so `ScreenExtractorVisitGroupingTests` can pin
    /// the boundary rule, matching the convention the other extractors use.
    /// Post-071.2 this is the LEGACY fallback for pre-cutover rows only —
    /// production grouping is `canonicalVisits`.
    nonisolated func collapseIntoVisits(_ contexts: [ScreenContext]) -> [Visit] {
        var visits: [Visit] = []
        var currentApp: String? = nil
        var currentStart: Date? = nil
        var currentEnd: Date? = nil
        var currentWindowTitle: String? = nil
        var currentNormalizedTitle: String? = nil
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
            currentNormalizedTitle = nil
            currentOcrBuilder = ""
            currentLastId = nil
        }

        for c in contexts {
            let gap = lastTime.map { c.timestamp.timeIntervalSince($0) } ?? 0
            // ITER-071 — a different WINDOW is a different visit, not just a
            // different app. Grouping by app alone merged two browser tabs or
            // two Slack channels into one stretch, and then attached the last
            // window's title to OCR accumulated across all of them — so a fact
            // from one conversation could be attributed to another. Cosmetic
            // title churn is normalized away first, or a ticking clock in a
            // title would shatter one visit into dozens.
            let normalized = WindowTitleNormalizer.normalize(c.windowTitle)
            let isNewVisit = c.appName != currentApp
                || normalized != currentNormalizedTitle
                || gap > visitGapSeconds
            if isNewVisit {
                flush()
                currentApp = c.appName
                currentNormalizedTitle = normalized
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

    /// Inspired by observation + proactive extraction flow.
    /// Every visit produces an observation. Additionally, across all visits, extract durable facts
    /// (memories) and actionable tasks — linked back to the visit by index.
    static let systemPrompt = """
    You are an expert screen activity analyzer. You receive a batch of "visits" (continuous stretches on one app window).
    You produce THREE outputs in one JSON object:
    1. observations (EXACTLY one per visit, same order) — always generated.
    2. memories (0-5 total across the batch) — durable facts about the user observable on screen.
    3. tasks (0-5 total) — concrete actionable tasks observable on screen.

    OBSERVATIONS — one per visit:
    - contextSummary: 1 sentence, specific. "User reviewing ChatApp GA4 traffic dashboard", NOT "User was in browser".
    - currentActivity: verb phrase 2-5 words. "Analyzing traffic decline", "Reviewing PR on GitHub".
    - hasTask: true if this visit showed concrete task the user should do. Browsing/reading is NOT a task.
    - taskTitle: ≤10 word imperative if hasTask. Else null.
    - category: one of — personal, education, health, finance, legal, philosophy, spiritual, science, entrepreneurship, parenting, romantic, travel, inspiration, technology, business, social, work, sports, politics, literature, history, architecture, music, weather, news, entertainment, psychology, real, design, family, economics, environment, other.
    - focusStatus: "focused" sustained work on one topic / "distracted" switching between unrelated topics / null unclear.

    MEMORIES — across all visits extract durable facts about the user. STRICT — same rules as voice memory extraction:
    - Named projects user works on ("User builds ChatApp, an AI ChatGPT wrapper product").
    - Named people in network with role ("User's colleague Alice Smith handles Telegram bot WatchBot").
    - Specific preferences with reasoning ("User prefers PARA method for Obsidian vault organization").
    - Concrete commitments ("User plans to integrate Stripe billing into MetaWhisp").
    - NO generic "User was in X app". NO "User is working on something" (vague).
    - Each memory ≤15 words, starts with "User" (or attribution for external wisdom).
    - Each memory includes visitIndex (0-based) pointing to most relevant visit.

    TASKS — be STRICT. Most visits have ZERO tasks. Extract ONLY when the user is the direct recipient of an explicit pending action.

    READING-vs-ACTING FILTER (APPLY FIRST):
    - Extract a task ONLY if the user is the DIRECT RECIPIENT of a pending action:
      unread message addressed to user with no reply yet, invoice due, PR assigned to user, form asking user for input, calendar event starting soon.
    - SKIP (tasks=[]) for all of these:
      * Articles, blog posts, tutorials, listicles
      * Dashboards, analytics, charts
      * AI chat transcripts — Claude/ChatGPT suggesting steps ≠ user committing
      * Chat threads where the LAST message is FROM the user (already responded)
      * Other people's schedules, commitments, plans being described
      * Code editors, terminals, log viewers
      * News, social feeds, search results, video players
      * Settings, docs, passive browsing

    SUBJECT CHECK: only when the USER is the one expected to act. If the screen describes
    what SOMEONE ELSE should do or already did, no task.

    Format (when extracting):
    - description ≤15 words, start with verb. Remove time refs.
    - dueAt ISO-8601 UTC with Z if visible in context. Omit otherwise.
    - Each task includes visitIndex (0-based).
    - SKIP tasks that are just reading UI text ("Click Send button" — NO).

    Output MUST have observations array with EXACTLY as many entries as visits. Memories and tasks CAN be empty arrays.

    Respond in the same language the screen content is in.

    RELEVANCE + EVIDENCE (TASKS ONLY):
    For every task you extract, include:
    - relevance: integer 0-100. 90+ only if invoice with due date / PR explicitly assigned
      to user / calendar event imminent. 75-89 if explicit named action awaiting user.
      Below 75 → do NOT extract this task.
    - evidence: verbatim quote (≥20 chars) from THIS visit's OCR that proves the task is
      pending and addressed to the user. If no such quote exists, do not extract.

    Return JSON:
    {
      "observations": [{"contextSummary": "...", "currentActivity": "...", "hasTask": false, "taskTitle": null, "category": "work", "focusStatus": "focused"}],
      "memories": [{"visitIndex": 0, "content": "...", "category": "system", "confidence": 0.8}],
      "tasks": [{"visitIndex": 0, "description": "...", "dueAt": "2026-04-20T20:59:00Z", "relevance": 85, "evidence": "Due Mar 15 — $450 unpaid"}]
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
            // Codex P1 — the parser and the prompt's own instructions are
            // zero-based, but the labels said "Visit 1". A model following the
            // labels dropped the only visit or validated against the wrong
            // OCR; a model following the instructions contradicted the labels.
            lines.append("Visit \(i) — \(v.appName) · \(start)-\(end) · \(title)")
            if !v.ocrPreview.isEmpty {
                lines.append("  OCR: \(v.ocrPreview)")
            }
            lines.append("")
        }
        let joined = lines.joined(separator: "\n")
        if joined.count > 20000 { return String(joined.prefix(20000)) }
        return joined
    }

    // MARK: - Model index guard

    /// The LLM supplies `visitIndex` for every memory/task it returns. It is a
    /// raw `Int` off the wire, so it can be negative — and `trimmed[-1]` is a
    /// fatal trap, not a caught error.
    ///
    /// Internal (not private) so `ScreenExtractorVisitIndexTests` pins the
    /// contract, matching the `MemoryExtractor.parseResponse` convention.
    nonisolated static func isValidVisitIndex(_ index: Int, count: Int) -> Bool {
        index >= 0 && index < count
    }

    // MARK: - Response parse

    private struct ObservationJSON: Decodable {
        // Everything tolerant — LLM sometimes omits fields or swaps types; we shouldn't
        // discard the entire batch for a missing `currentActivity`. Defaults fill in.
        let contextSummary: String?
        let currentActivity: String?
        let hasTask: Bool?
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
        let relevance: Int?
        let evidence: String?
        let dueAt: String?
    }
    private struct BatchResult: Decodable {
        // ITER-057.5 — optional: a truncated/partial response with only memories
        // or tasks shouldn't fail the whole batch ("Parse error … Response head: {").
        let observations: [ObservationJSON]?
        let memories: [MemoryJSON]?
        let tasks: [TaskJSON]?
    }

    /// Parse LLM response. Logs the decoding error + response snippet on failure so we can
    /// actually diagnose WHY parse fails (previously this was a silent `try?` nil — we lost
    /// all info). Decoder is tolerant — missing observation fields get defaults at call site.
    private func parseResponse(_ response: String) -> BatchResult? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else {
            NSLog("[ScreenExtractor] ❌ Parse: response not UTF-8")
            return nil
        }
        do {
            return try JSONDecoder().decode(BatchResult.self, from: data)
        } catch {
            NSLog("[ScreenExtractor] ❌ Parse error: %@. Response head: %@",
                  error.localizedDescription,
                  String(extracted.prefix(400)))
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
        request.timeoutInterval = 60

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
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
        // ITER-051 F1.3 — the local model is a first-class access path, same
        // as MemoryExtractor/TaskExtractor (the Memories screen already told
        // local-only users these readers work).
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }

    // MARK: - Dedup helpers (cheap Swift-side check against last N entries)

    /// INCLUDES dismissed rows, matching what tasks already do below: a fact
    /// the user threw away must not come back an hour later. Discarding a
    /// screen proposal is a verdict, and re-proposing it is the product
    /// arguing with the user once per hour, forever.
    private func fetchRecentMemoryContents(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<UserMemory>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit * 2
        return ((try? ctx.fetch(desc)) ?? []).map { $0.content }
    }

    /// ITER-057.5 — INCLUDES dismissed rows: a task the user rejected must not
    /// resurrect from the next batch (dismissed = permanent negative example).
    private func fetchRecentTaskDescriptions(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.taskDescription }
    }
}
