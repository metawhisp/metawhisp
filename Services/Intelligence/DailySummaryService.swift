import Foundation
import SwiftData
import UserNotifications

/// Generates the once-a-day recap (`DailySummary`). Runs:
/// - On a 5-minute in-process timer: when today's scheduled time has passed and no
///   row exists yet → generate + post a macOS notification.
/// - On explicit "GENERATE NOW" from Dashboard.
/// - On app launch (catch-up if the machine was asleep past the scheduled time).
///
/// Notification delivery uses the system `UNUserNotificationCenter`. The generation
/// itself is in-process because macOS doesn't wake non-daemon apps at a cron time;
/// MetaWhisp is a menu-bar app so it's running whenever the user is logged in.
///
/// spec://iterations/ITER-009-daily-summary
@MainActor
final class DailySummaryService: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastGenerationAt: Date?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Notification identifier — swapped out on each re-schedule so the old one cancels.
    private let notificationId = "com.metawhisp.daily-summary"

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Scheduling (5-min tick)

    /// Start the periodic check. Idempotent — cancels any prior timer first.
    func startScheduler() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            // Run one immediate check in case user launched past the scheduled time.
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 min
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
        NSLog("[DailySummary] ✅ Scheduler started")
    }

    func stopScheduler() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// One check cycle — fire if: enabled AND past scheduled time today AND no row yet.
    private func tick() async {
        guard settings.dailySummaryEnabled else { return }
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        guard now >= scheduledFireTime(for: today) else { return }
        if hasSummary(for: today) { return }
        await generate(for: today, postNotification: true)
    }

    /// `today` at HH:MM configured by the user.
    private func scheduledFireTime(for dayStart: Date) -> Date {
        let hour = max(0, min(23, settings.dailySummaryHour))
        let minute = max(0, min(59, settings.dailySummaryMinute))
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart) ?? dayStart
    }

    // MARK: - Manual trigger

    /// "GENERATE NOW" button. Generates for today even if already have a row (overwrites).
    func generateNow() async -> DailySummary? {
        await generateForDate(Date())
    }

    /// ITER-022 G_dashboard — Generate (or regenerate) for any date.
    /// Used by the new Daily Summary carousel: tap GENERATE on a past empty day
    /// retro-creates the summary from that day's data. Idempotent — deletes
    /// existing row for that date first.
    /// `date` can be any timestamp; we normalize to `startOfDay` internally.
    @discardableResult
    func generateForDate(_ date: Date) async -> DailySummary? {
        let dayStart = Calendar.current.startOfDay(for: date)
        // Future days have no data — silently skip (UI shows placeholder anyway).
        let today = Calendar.current.startOfDay(for: Date())
        guard dayStart <= today else { return nil }
        // Delete existing row for the date so the new one takes its place cleanly.
        if fetchSummary(for: dayStart) != nil, let container = modelContainer {
            let ctx = ModelContext(container)
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let rows = (try? ctx.fetch(FetchDescriptor<DailySummary>(
                predicate: #Predicate { $0.date >= dayStart && $0.date < nextDay }
            ))) ?? []
            for row in rows { ctx.delete(row) }
            try? ctx.save()
        }
        return await generate(for: dayStart, postNotification: false)
    }

    /// ITER-022 G_dashboard — Public read for the carousel.
    /// Returns the persisted summary for that date, or nil.
    func summary(for date: Date) -> DailySummary? {
        let dayStart = Calendar.current.startOfDay(for: date)
        return fetchSummary(for: dayStart)
    }

    // MARK: - Core generation

    @discardableResult
    private func generate(for dayStart: Date, postNotification: Bool) async -> DailySummary? {
        guard !isRunning else { return nil }
        guard hasLLMAccess else {
            NSLog("[DailySummary] No LLM access — skipping")
            return nil
        }
        guard let container = modelContainer else { return nil }

        isRunning = true
        defer {
            isRunning = false
            lastGenerationAt = Date()
        }

        let ctx = ModelContext(container)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? Date()

        // Collect the day's data.
        let conversations = fetchConversations(ctx: ctx, from: dayStart, to: dayEnd)
        let memoriesAdded = fetchMemoriesAdded(ctx: ctx, from: dayStart, to: dayEnd)
        let tasksCreated = fetchTasksCreated(ctx: ctx, from: dayStart, to: dayEnd)
        let tasksCompleted = fetchTasksCompleted(ctx: ctx, from: dayStart, to: dayEnd)
        let topApps = fetchTopApps(ctx: ctx, from: dayStart, to: dayEnd, limit: 5)
        // Active goals — feed into energy + headline agents so the recap can comment
        // on standing targets ("ahead on writing, behind on push-ups"). Pulled at
        // generation time; daily-reset runs inside `resetIfNewDay` per goal.
        let goalsForDay = fetchActiveGoals(ctx: ctx)

        let isEmptyDay = conversations.isEmpty && memoriesAdded.isEmpty
            && tasksCreated.isEmpty && tasksCompleted.isEmpty && topApps.isEmpty
            && goalsForDay.isEmpty
        if isEmptyDay {
            NSLog("[DailySummary] No activity captured for %@ — skipping generation", dayStart.description)
            return nil
        }

        guard LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey else {
            NSLog("[DailySummary] Non-Pro — skipping (cloud-only for v1)")
            return nil
        }

        // ── MULTI-AGENT (ITER-010-B) ────────────────────────────────────────────
        // Replaces the prior single combined LLM call with 4 specialists running
        // in parallel. Each one sees ONLY the data it cares about and a tight
        // prompt focused on a single section. Reference-pattern Proactive-
        // Assistants split — much higher signal per section, no cross-pollution
        // ("learned" never bleeds into "shipped" anymore).
        let convExcerpts = fetchConversationExcerpts(
            for: conversations.map { $0.id },
            charsPerConv: 600
        )

        async let learnedItems   = learnedAgent(memoriesAdded, conversations: conversations,
                                                 excerpts: convExcerpts, licenseKey: licenseKey)
        async let decidedItems   = decidedAgent(conversations, excerpts: convExcerpts,
                                                 tasksCreated: tasksCreated, licenseKey: licenseKey)
        async let shippedItems   = shippedAgent(tasksCompleted, conversations: conversations,
                                                 excerpts: convExcerpts, licenseKey: licenseKey)
        async let energyLine     = energyAgent(topApps: topApps,
                                                conversationCount: conversations.count,
                                                memoryCount: memoriesAdded.count,
                                                tasksDone: tasksCompleted.count,
                                                tasksNew: tasksCreated.count,
                                                goals: goalsForDay,
                                                licenseKey: licenseKey)

        let learned = await learnedItems
        let decided = await decidedItems
        let shipped = await shippedItems
        let energy  = await energyLine

        // Final headline synth — small follow-up LLM call that sees all section
        // outputs and writes 1 line theme. Doing this AFTER the agents means
        // the headline is grounded in real extracted content, not raw data.
        let headline = await headlineAgent(
            learned: learned, decided: decided, shipped: shipped, energy: energy,
            conversations: conversations, goals: goalsForDay, licenseKey: licenseKey
        )

        let topAppsJSON = (try? JSONEncoder().encode(topApps.map {
            DailySummary.TopApp(app: $0.app, minutes: $0.minutes)
        })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let summary = DailySummary(
            date: dayStart,
            title: headline,
            overview: energy,                  // legacy mirror — kept for compat
            keyEventsJSON: "[]",               // legacy field — unused in new shape
            conversationCount: conversations.count,
            tasksCompleted: tasksCompleted.count,
            tasksCreated: tasksCreated.count,
            memoriesAdded: memoriesAdded.count,
            topAppsJSON: topAppsJSON
        )
        summary.learnedJSON = DailySummary.encodeStringArray(learned)
        summary.decidedJSON = DailySummary.encodeStringArray(decided)
        summary.shippedJSON = DailySummary.encodeStringArray(shipped)
        summary.energy = energy
        ctx.insert(summary)
        try? ctx.save()

        NSLog("[DailySummary] ✅ Generated: %@ · L=%d D=%d S=%d", headline,
              learned.count, decided.count, shipped.count)

        if postNotification {
            postDeliveryNotification(title: headline, overview: energy)
        }
        return summary
    }

    // MARK: - Specialist agents (ITER-010-B)

    /// Generic agent runner — single-purpose LLM call returning [String] from JSON.
    private func runAgent(systemPrompt: String, userPrompt: String, licenseKey: String,
                          arrayKey: String) async -> [String] {
        do {
            let response = try await callProProxy(system: systemPrompt, user: userPrompt, licenseKey: licenseKey)
            return parseStringArray(response, key: arrayKey)
        } catch {
            NSLog("[DailySummary] Agent failed (%@): %@", arrayKey, error.localizedDescription)
            return []
        }
    }

    private func runStringAgent(systemPrompt: String, userPrompt: String, licenseKey: String,
                                key: String) async -> String {
        do {
            let response = try await callProProxy(system: systemPrompt, user: userPrompt, licenseKey: licenseKey)
            return parseString(response, key: key)
        } catch {
            NSLog("[DailySummary] Agent failed (%@): %@", key, error.localizedDescription)
            return ""
        }
    }

    private func learnedAgent(_ memories: [UserMemory], conversations: [Conversation],
                              excerpts: [UUID: String], licenseKey: String) async -> [String] {
        guard !memories.isEmpty || !conversations.isEmpty else { return [] }
        var parts: [String] = []
        parts.append("MEMORIES CAPTURED TODAY:")
        if memories.isEmpty {
            parts.append("(none)")
        } else {
            for m in memories.prefix(20) {
                let head = m.headline ?? ""
                let why = m.reasoning ?? ""
                parts.append("- \(head.isEmpty ? m.content : "[\(head)] \(m.content)")\(why.isEmpty ? "" : " — \(why)")")
            }
        }
        parts.append("")
        parts.append("CONVERSATION EXCERPTS (look for surprising / new realizations):")
        for c in conversations.prefix(10) {
            let title = c.title ?? "(untitled)"
            let excerpt = excerpts[c.id] ?? ""
            parts.append("- \(title): \(excerpt.prefix(400))")
        }
        return await runAgent(
            systemPrompt: Self.learnedSystemPrompt,
            userPrompt: parts.joined(separator: "\n"),
            licenseKey: licenseKey,
            arrayKey: "learned"
        )
    }

    private func decidedAgent(_ conversations: [Conversation], excerpts: [UUID: String],
                              tasksCreated: [TaskItem], licenseKey: String) async -> [String] {
        guard !conversations.isEmpty || !tasksCreated.isEmpty else { return [] }
        var parts: [String] = []
        parts.append("CONVERSATION OVERVIEWS + EXCERPTS (look for explicit decisions):")
        for c in conversations.prefix(15) {
            let title = c.title ?? "(untitled)"
            let ov = c.overview ?? ""
            let excerpt = excerpts[c.id] ?? ""
            parts.append("- \(title)")
            if !ov.isEmpty { parts.append("    overview: \(ov)") }
            if !excerpt.isEmpty { parts.append("    excerpt: \(excerpt.prefix(300))") }
        }
        parts.append("")
        parts.append("NEW TASKS CREATED (often signal a decision):")
        if tasksCreated.isEmpty {
            parts.append("(none)")
        } else {
            for t in tasksCreated.prefix(20) { parts.append("- \(t.taskDescription)") }
        }
        return await runAgent(
            systemPrompt: Self.decidedSystemPrompt,
            userPrompt: parts.joined(separator: "\n"),
            licenseKey: licenseKey,
            arrayKey: "decided"
        )
    }

    private func shippedAgent(_ tasksCompleted: [TaskItem], conversations: [Conversation],
                              excerpts: [UUID: String], licenseKey: String) async -> [String] {
        guard !tasksCompleted.isEmpty || !conversations.isEmpty else { return [] }
        var parts: [String] = []
        parts.append("TASKS COMPLETED TODAY:")
        if tasksCompleted.isEmpty {
            parts.append("(none)")
        } else {
            for t in tasksCompleted.prefix(20) { parts.append("- ✓ \(t.taskDescription)") }
        }
        parts.append("")
        parts.append("CONVERSATION EXCERPTS (look for 'shipped/done/sent/closed/merged' mentions):")
        for c in conversations.prefix(10) {
            let title = c.title ?? "(untitled)"
            let excerpt = excerpts[c.id] ?? ""
            parts.append("- \(title): \(excerpt.prefix(400))")
        }
        return await runAgent(
            systemPrompt: Self.shippedSystemPrompt,
            userPrompt: parts.joined(separator: "\n"),
            licenseKey: licenseKey,
            arrayKey: "shipped"
        )
    }

    private func energyAgent(topApps: [AppMinutes], conversationCount: Int,
                             memoryCount: Int, tasksDone: Int, tasksNew: Int,
                             goals: [GoalSnapshot], licenseKey: String) async -> String {
        var parts: [String] = []
        parts.append("DAY STATS:")
        parts.append("- conversations: \(conversationCount)")
        parts.append("- new memories: \(memoryCount)")
        parts.append("- tasks completed: \(tasksDone)")
        parts.append("- tasks created: \(tasksNew)")
        parts.append("")
        parts.append("TOP APPS BY TIME:")
        if topApps.isEmpty {
            parts.append("(no app activity)")
        } else {
            for a in topApps { parts.append("- \(a.app) · \(a.minutes)m") }
        }
        parts.append("")
        parts.append("ACTIVE GOALS (today's progress):")
        if goals.isEmpty {
            parts.append("(none tracked)")
        } else {
            for g in goals { parts.append("- [\(g.typeLabel)] \(g.title) — \(g.progressLabel)") }
        }
        return await runStringAgent(
            systemPrompt: Self.energySystemPrompt,
            userPrompt: parts.joined(separator: "\n"),
            licenseKey: licenseKey,
            key: "energy"
        )
    }

    private func headlineAgent(learned: [String], decided: [String], shipped: [String],
                               energy: String, conversations: [Conversation],
                               goals: [GoalSnapshot], licenseKey: String) async -> String {
        var parts: [String] = []
        parts.append("LEARNED:")
        for l in learned.prefix(5) { parts.append("- \(l)") }
        parts.append("")
        parts.append("DECIDED:")
        for d in decided.prefix(5) { parts.append("- \(d)") }
        parts.append("")
        parts.append("SHIPPED:")
        for s in shipped.prefix(5) { parts.append("- \(s)") }
        parts.append("")
        parts.append("ENERGY: \(energy)")
        parts.append("")
        parts.append("ACTIVE GOALS:")
        if goals.isEmpty {
            parts.append("(none)")
        } else {
            for g in goals { parts.append("- \(g.title) — \(g.progressLabel)") }
        }
        parts.append("")
        parts.append("CONVERSATION TITLES:")
        for c in conversations.prefix(10) {
            parts.append("- \(c.title ?? "(untitled)")")
        }
        let synth = await runStringAgent(
            systemPrompt: Self.headlineSystemPrompt,
            userPrompt: parts.joined(separator: "\n"),
            licenseKey: licenseKey,
            key: "headline"
        )
        // Fallback if LLM returns empty — derive from data
        if synth.isEmpty {
            if !shipped.isEmpty { return "Shipped \(shipped.count) items" }
            if !decided.isEmpty { return "\(decided.count) decisions taken" }
            if conversations.count > 0 { return "\(conversations.count) conversations · \(learned.count) learnings" }
            return "Quiet day"
        }
        return synth
    }

    // MARK: - JSON helpers for agent responses

    private func parseStringArray(_ response: String, key: String) -> [String] {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return [] }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = dict[key] as? [String] else {
            NSLog("[DailySummary] %@ parse failed: %@", key, String(extracted.prefix(120)))
            return []
        }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseString(_ response: String, key: String) -> String {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return "" }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let str = dict[key] as? String else {
            NSLog("[DailySummary] %@ parse failed: %@", key, String(extracted.prefix(120)))
            return ""
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - macOS notification (native UNUserNotificationCenter)

    private func postDeliveryNotification(title: String, overview: String) {
        let content = UNMutableNotificationContent()
        content.title = "Day recap ready"
        content.subtitle = title
        content.body = String(overview.prefix(180))
        content.sound = .default
        content.categoryIdentifier = "DAILY_SUMMARY"
        content.userInfo = ["target": "dashboard"]

        let request = UNNotificationRequest(
            identifier: "\(notificationId)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil // immediate delivery
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err {
                NSLog("[DailySummary] Notification post failed: %@", err.localizedDescription)
            }
        }
    }

    // MARK: - Data fetch helpers

    private func fetchConversations(ctx: ModelContext, from start: Date, to end: Date) -> [Conversation] {
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded && $0.startedAt >= start && $0.startedAt < end
            },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        desc.fetchLimit = 100
        return (try? ctx.fetch(desc)) ?? []
    }

    private func fetchMemoriesAdded(ctx: ModelContext, from start: Date, to end: Date) -> [UserMemory] {
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate {
                !$0.isDismissed && $0.createdAt >= start && $0.createdAt < end
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 50
        return (try? ctx.fetch(desc)) ?? []
    }

    private func fetchTasksCreated(ctx: ModelContext, from start: Date, to end: Date) -> [TaskItem] {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate {
                !$0.isDismissed && $0.createdAt >= start && $0.createdAt < end
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        desc.fetchLimit = 100
        // Exclude staged candidates from the recap — they're not real commitments yet.
        return (try? ctx.fetch(desc))?.filter { $0.status != "staged" && $0.status != "dismissed" } ?? []
    }

    private func fetchTasksCompleted(ctx: ModelContext, from start: Date, to end: Date) -> [TaskItem] {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> {
                $0.completed && $0.completedAt != nil &&
                $0.completedAt! >= start && $0.completedAt! < end
            },
            sortBy: [SortDescriptor(\.completedAt, order: .forward)]
        )
        desc.fetchLimit = 100
        return (try? ctx.fetch(desc)) ?? []
    }

    private struct AppMinutes {
        let app: String
        let minutes: Int
    }

    /// Frozen snapshot of a goal at recap-generation time. We don't pass `Goal`
    /// SwiftData objects across actor boundaries — `runAgent` would capture them
    /// inside a Sendable closure and trip Swift 6 isolation checks.
    struct GoalSnapshot {
        let title: String
        let typeLabel: String      // "daily" | "rating" | "numeric"
        let progressLabel: String  // verbatim Goal.progressLabel
        let progressFraction: Double
    }

    private func fetchActiveGoals(ctx: ModelContext) -> [GoalSnapshot] {
        var desc = FetchDescriptor<Goal>(
            predicate: #Predicate<Goal> { $0.isActive && !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 50
        let goals = (try? ctx.fetch(desc)) ?? []
        return goals.map { g in
            // Apply the daily reset before snapshotting so stale values don't surface.
            g.resetIfNewDay()
            let typeLabel: String
            switch g.goalType {
            case "boolean": typeLabel = "daily"
            case "scale":   typeLabel = "rating"
            case "numeric": typeLabel = "numeric"
            default:        typeLabel = g.goalType
            }
            return GoalSnapshot(
                title: g.title,
                typeLabel: typeLabel,
                progressLabel: g.progressLabel,
                progressFraction: g.progressFraction
            )
        }
    }

    private func fetchTopApps(ctx: ModelContext, from start: Date, to end: Date, limit: Int) -> [AppMinutes] {
        // ScreenObservation has startedAt/endedAt — sum minutes per app for the day window.
        var desc = FetchDescriptor<ScreenObservation>(
            predicate: #Predicate {
                $0.startedAt >= start && $0.startedAt < end
            }
        )
        desc.fetchLimit = 500
        let observations = (try? ctx.fetch(desc)) ?? []
        var byApp: [String: TimeInterval] = [:]
        for obs in observations {
            let dur = max(0, obs.endedAt.timeIntervalSince(obs.startedAt))
            byApp[obs.appName, default: 0] += dur
        }
        return byApp
            .map { AppMinutes(app: $0.key, minutes: Int($0.value / 60)) }
            .filter { $0.minutes >= 1 }
            .sorted { $0.minutes > $1.minutes }
            .prefix(limit)
            .map { $0 }
    }

    /// First-N-chars transcript excerpt per conversation — gives the recap LLM
    /// real names / projects to extract as highlight subjects.
    private func fetchConversationExcerpts(for ids: [UUID], charsPerConv: Int) -> [UUID: String] {
        guard let container = modelContainer, !ids.isEmpty else { return [:] }
        let ctx = ModelContext(container)
        // #Predicate can't mix Optional unwrap + array contains. Fetch items whose
        // conversationId != nil and filter in Swift — cheap, few hundred rows max.
        let desc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate<HistoryItem> { $0.conversationId != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let idSet = Set(ids)
        guard let items = try? ctx.fetch(desc) else { return [:] }
        var bufs: [UUID: String] = [:]
        for item in items {
            guard let cid = item.conversationId, idSet.contains(cid) else { continue }
            let existing = bufs[cid] ?? ""
            guard existing.count < charsPerConv else { continue }
            let room = charsPerConv - existing.count
            let add = String(item.displayText.prefix(room))
            bufs[cid] = existing + (existing.isEmpty ? "" : " ") + add
        }
        return bufs
    }

    private func fetchSummary(for dayStart: Date) -> DailySummary? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var desc = FetchDescriptor<DailySummary>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < next }
        )
        desc.fetchLimit = 1
        return (try? ctx.fetch(desc))?.first
    }

    private func hasSummary(for dayStart: Date) -> Bool {
        fetchSummary(for: dayStart) != nil
    }

    // MARK: - Specialist agent prompts (ITER-010-B)
    //
    // Each prompt is single-purpose. Splitting the previous monolithic prompt
    // into 5 specialists raised section quality dramatically: each agent sees
    // ONLY the data relevant to its section, can't bleed concepts across, and
    // gets a tight system prompt focused on one extraction task.
    //
    // Common rules (enforced by every prompt):
    // - Output is ONLY valid JSON with the named key — no prose, no markdown.
    // - Each item: ≤14 words, no trailing period, no leading bullet character.
    // - Subject-led: real names (people, projects, modules) — never "the team".
    // - Empty array is preferred over invented filler.
    // - Respond in the user's content language (mostly Russian / English mix).

    static let learnedSystemPrompt = """
    You extract LEARNED items for a personal daily recap.
    LEARNED = facts / insights the user UNDERSTOOD today that they didn't know
    before — surprises, debugging revelations, new info about people / projects /
    tools, problem statements that became clearer.

    Return ONLY this JSON:
    {"learned": ["item1", "item2", ...]}

    RULES:
    - 0 to 4 items. Empty array is BETTER than padding.
    - Each item ≤14 words, no trailing period.
    - Subject-led with a concrete name. NOT "the team", NOT "the project".
    - GOOD: "SwiftData fetches all rows without predicate"
            "LLM loses the question at end of long prompts"
            "Pasha — biweekly Q2 sync on Tuesdays"
            "Whisper hallucinates speaker labels on silent gaps"
    - BAD:  "Learned a lot about SwiftData"   ← vague
            "Discussed the architecture"      ← not a learning, just an activity
            "Productive learning day"         ← cliché
    - If the input contains no real new understanding → return {"learned": []}.

    CRITICAL: respond with ONLY the JSON object. No markdown, no preamble.
    """

    static let decidedSystemPrompt = """
    You extract DECIDED items for a personal daily recap.
    DECIDED = concrete choices / commitments / directions chosen today —
    explicit "let's do X", "switch to Y", "drop Z", new tasks that signal a
    decision was made.

    Return ONLY this JSON:
    {"decided": ["item1", "item2", ...]}

    RULES:
    - 0 to 4 items. Empty array is BETTER than padding.
    - Each item ≤14 words, no trailing period.
    - Action-led: start with the verb of the decision.
    - GOOD: "Restructure daily summary into 4 sections"
            "Drop narrative paragraphs from recap UI"
            "Switch staged-task bin for screen-extracted items"
            "Move TTS to Pro-proxy, sunset on-device voice"
    - BAD:  "Talked about the new architecture"   ← discussion ≠ decision
            "Several decisions were made"         ← meta, not a decision
            "Move forward with the plan"          ← vague, no subject
    - Distinguish DECISION from SHIPPED — decision = chose to do; shipped = done.
    - If no real decision surfaced → return {"decided": []}.

    CRITICAL: respond with ONLY the JSON object. No markdown, no preamble.
    """

    static let shippedSystemPrompt = """
    You extract SHIPPED items for a personal daily recap.
    SHIPPED = concrete artifacts the user FINISHED today — completed tasks,
    sent messages, merged commits, closed loops, generated output. Must be
    EVIDENCED in the input. Never invent.

    Return ONLY this JSON:
    {"shipped": ["item1", "item2", ...]}

    RULES:
    - 0 to 5 items. Empty array is BETTER than padding.
    - Each item ≤14 words, no trailing period.
    - Past-tense / artifact-noun phrasing.
    - GOOD: "Staged Tasks bin + promote/reject buttons"
            "OpenAI TTS endpoint + Pro proxy"
            "Reply to Mike about SEO report"
            "Liquid Glass tokens applied across Dashboard"
    - BAD:  "Worked on the Dashboard"        ← activity, not artifact
            "Made progress on multiple tasks" ← vague
            "Started the new feature"         ← started ≠ shipped
    - Source MUST be visible in the data: a completed task title, an explicit
      "done/sent/shipped/closed/merged" in a transcript, a meeting outcome.
    - If nothing was actually finished → return {"shipped": []}.

    CRITICAL: respond with ONLY the JSON object. No markdown, no preamble.
    """

    static let energySystemPrompt = """
    You write the ENERGY line for a personal daily recap.
    ENERGY = ONE qualitative observation about the day's tone / shape — based
    on app distribution, conversation density, fragmentation, and goal progress.
    NOT stats. NOT cliché ("Busy", "Productive", "Mixed" are BANNED).

    Return ONLY this JSON:
    {"energy": "one line ≤10 words"}

    RULES:
    - Exactly one short line. ≤10 words. No trailing period.
    - Tie the line to a real signal in the input (top app, ratio, count, goal).
    - When ACTIVE GOALS are present and clearly behind / ahead, weave that in
      ("Behind on writing goal", "Ahead on push-ups, low meeting load").
      A goal at 0/target near end of day = behind; a daily checkbox still
      "Pending" late in the day = also behind.
    - GOOD: "Deep-focus morning, scattered afternoon"
            "High output · low fragmentation"
            "Behind on writing, heavy meeting day"
            "Most time in Telegram — call & coordination day"
            "Quiet build day, all daily goals done"
    - BAD:  "Busy day"  "Productive day"  "Mixed energy"  ← banned clichés
            "5 conversations and 3 tasks"                  ← stats, not energy
    - If input is empty or near-empty → "Quiet day".

    CRITICAL: respond with ONLY the JSON object. No markdown, no preamble.
    """

    static let headlineSystemPrompt = """
    You write the HEADLINE for a personal daily recap.
    HEADLINE = the THEME running through the day, synthesized from the already-
    extracted Learned / Decided / Shipped / Energy sections plus the conversation
    titles and active goals. Not a count, not a single meeting title alone.

    Return ONLY this JSON:
    {"headline": "≤8 words"}

    RULES:
    - ≤8 words. No trailing period. No quotes around the headline.
    - State a real thread you can see across multiple inputs.
    - Goals are background, not the headline subject — only mention if a goal
      crossed a meaningful threshold (hit target, completed daily streak, etc.).
    - GOOD: "Dashboard polish + meeting transcripts surfacing"
            "Settings overhaul, MetaChat context fixes"
            "Shipping Liquid Glass across the app"
            "Recap rebuild + memory enrichment"
    - BAD:  "MetaWhisp · 5 conversations"   ← mechanical count
            "Productive day"                 ← cliché
            "Project Discussion"             ← single meeting title verbatim
    - If only one theme → state it. If two unrelated → join with " · " (max 2).
    - If input has nothing substantive → "Quiet day".

    CRITICAL: respond with ONLY the JSON object. No markdown, no preamble.
    """

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
        request.timeoutInterval = 30

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "DailySummary", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
