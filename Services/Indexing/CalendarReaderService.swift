import EventKit
import Foundation
import SwiftData

/// Reads user's calendar events via EventKit, creates TaskItems for upcoming events,
/// extracts memories for recurring patterns.
///
/// EventKit (Apple-native) covers iCloud/Google/Exchange, no browser dependency.
/// spec://BACKLOG#Phase3.E3
@MainActor
final class CalendarReaderService: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastSummary: String?
    @Published var lastRun: Date?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    private let store = EKEventStore()

    /// Look-back window for pattern analysis (memories).
    private let daysBack: Int = 30
    /// Look-forward window for task creation.
    private let daysForward: Int = 14
    /// Max events fed to LLM for memory extraction.
    private let maxEventsForLLM = 80
    /// Min confidence.
    private let minConfidence: Double = 0.7

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func startPeriodic(interval: TimeInterval) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.scanNow()
            }
        }
        NSLog("[Calendar] ✅ Periodic every %.0fs", interval)
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Request Calendar permission (macOS 14+ uses requestFullAccessToEvents).
    @discardableResult
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                return granted
            } catch {
                NSLog("[Calendar] Access request failed: %@", error.localizedDescription)
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Main scan: creates tasks from upcoming events + memories from patterns.
    func scanNow() async {
        guard !isRunning else { return }
        guard settings.calendarReaderEnabled else { return }
        guard hasLLMAccess else { return }
        guard let container = modelContainer else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        // 1. Access.
        let granted = await requestAccess()
        guard granted else {
            lastError = "Calendar access denied. Grant in System Settings → Privacy & Security → Calendars."
            NSLog("[Calendar] ❌ Access not granted")
            return
        }

        // 2. Fetch events in window.
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: daysForward, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let ctx = ModelContext(container)

        // 3. Create tasks for upcoming events that don't yet exist as TaskItem.
        var taskCount = 0
        let existingTaskSignatures = fetchRecentTaskSignatures(in: ctx, limit: 200)
        for ev in events where ev.startDate >= now {
            // Skip declined events.
            if ev.status == .canceled { continue }
            if let me = ev.attendees?.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined {
                continue
            }
            let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // Dedup signature: title lowercased + rounded hour of start.
            let hourKey = Int(ev.startDate.timeIntervalSince1970 / 3600)
            let sig = "\(title.lowercased())|\(hourKey)"
            if existingTaskSignatures.contains(sig) { continue }

            let taskDesc = shortenTaskDescription(title)
            let task = TaskItem(
                taskDescription: taskDesc,
                dueAt: ev.startDate,
                sourceTranscriptId: nil,
                sourceApp: "Calendar",
                conversationId: nil,
                screenContextId: nil
            )
            ctx.insert(task)
            taskCount += 1
        }

        // 4. Send last N events (both past + upcoming) to LLM for pattern memories.
        let recentEvents = events.suffix(maxEventsForLLM)
        var memoryCount = 0
        if !recentEvents.isEmpty {
            memoryCount = await extractMemoriesFromEvents(Array(recentEvents), in: ctx)
        }

        try? ctx.save()
        lastSummary = "Tasks: \(taskCount) new · Memories: \(memoryCount) · Scanned \(events.count) events"
        NSLog("[Calendar] ✅ %@", lastSummary ?? "")
    }

    // MARK: - Memory extraction via LLM

    private func extractMemoriesFromEvents(_ events: [EKEvent], in ctx: ModelContext) async -> Int {
        let existingContents = fetchRecentMemoryContents(in: ctx, limit: 150)
        let prompt = buildMemoryPrompt(events: events, existing: existingContents)

        do {
            let response: String
            if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                response = try await callProProxy(system: Self.memorySystemPrompt, user: prompt, licenseKey: licenseKey)
            } else {
                let apiKey = settings.activeAPIKey
                guard !apiKey.isEmpty else { return 0 }
                let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                response = try await llm.complete(
                    system: Self.memorySystemPrompt,
                    user: prompt,
                    apiKey: apiKey,
                    provider: provider
                )
            }

            let mems = parseMemories(response)
            var added = 0
            for m in mems where m.confidence >= minConfidence {
                let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if existingContents.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { continue }
                let rec = UserMemory(
                    content: trimmed,
                    category: m.category,
                    sourceApp: "Calendar",
                    confidence: m.confidence,
                    windowTitle: nil,
                    contextSummary: nil,
                    conversationId: nil,
                    screenContextId: nil,
                    sourceFile: "calendar"
                )
                ctx.insert(rec)
                added += 1
            }
            return added
        } catch {
            NSLog("[Calendar] ❌ Memory extraction: %@", error.localizedDescription)
            return 0
        }
    }

    // MARK: - Prompt

    /// Focuses on patterns, not one-off events (insight applies here too).
    static let memorySystemPrompt = """
    You are an expert memory curator. You receive a user's recent and upcoming calendar events.
    Extract durable facts about the user's life based on PATTERNS (not one-off meetings).

    strict rules:
    - Each memory ≤ 15 words, start with "User".
    - Two categories: "system" / "interesting" (external wisdom — very rare from calendar).
    - DEFAULT TO EMPTY. Max 5 memories.

    ACCEPT (pattern-based):
    - Recurring meetings with named people ("User has weekly 1-on-1 with Vlad on Tuesdays at 10am").
    - Regular routines ("User attends gym 3x per week"). Omit exact times if non-stable.
    - Named projects in recurring standups ("User runs MetaWhisp standup every Monday").
    - Named relationships from recurring events.
    - Domain activities ("User regularly travels between Moscow and Dubai").

    REJECT:
    - One-off events ("Meeting with John on April 22") — too volatile.
    - Generic meetings without names or recurrence.
    - Birthday reminders, Google Calendar imports without user context.
    - Anything applicable to any Mac user.

    Dedup against existing memories shown.

    Return JSON: {"memories": [{"content": "...", "category": "system|interesting", "confidence": 0.0-1.0}]}
    If nothing pattern-worthy: {"memories": []}

    CRITICAL: Respond with ONLY the JSON object. No prose, no markdown fences.
    """

    private func buildMemoryPrompt(events: [EKEvent], existing: [String]) -> String {
        var parts: [String] = []
        if !existing.isEmpty {
            parts.append("Existing memories (do NOT duplicate):")
            for m in existing.prefix(80) { parts.append("- \(m)") }
            parts.append("")
        }
        parts.append("Calendar events (recent + upcoming):")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for ev in events {
            let title = ev.title ?? "Untitled"
            let start = df.string(from: ev.startDate)
            let attendees: String = {
                let participants = ev.attendees ?? []
                let names = participants.compactMap { $0.name ?? $0.url.absoluteString }.prefix(5)
                return names.isEmpty ? "" : " · with \(names.joined(separator: ", "))"
            }()
            let location = (ev.location?.isEmpty == false) ? " · @\(ev.location ?? "")" : ""
            parts.append("[\(start)] \(title)\(attendees)\(location)")
        }
        let joined = parts.joined(separator: "\n")
        if joined.count > 20000 { return String(joined.prefix(20000)) }
        return joined
    }

    // MARK: - Helpers

    private func shortenTaskDescription(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")
        if words.count <= 15 { return trimmed }
        return words.prefix(15).joined(separator: " ")
    }

    private func fetchRecentTaskSignatures(in ctx: ModelContext, limit: Int) -> Set<String> {
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.sourceApp == "Calendar" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        let items = (try? ctx.fetch(desc)) ?? []
        var set = Set<String>()
        for t in items {
            guard let due = t.dueAt else { continue }
            let hourKey = Int(due.timeIntervalSince1970 / 3600)
            set.insert("\(t.taskDescription.lowercased())|\(hourKey)")
        }
        return set
    }

    private func fetchRecentMemoryContents(in ctx: ModelContext, limit: Int) -> [String] {
        var desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.content }
    }

    // MARK: - Parse

    private struct MemoryJSON: Decodable {
        let content: String
        let category: String
        let confidence: Double
    }
    private struct ResultJSON: Decodable {
        let memories: [MemoryJSON]
    }

    private func parseMemories(_ response: String) -> [MemoryJSON] {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return [] }
        guard let result = try? JSONDecoder().decode(ResultJSON.self, from: data) else { return [] }
        return result.memories.filter { m in
            m.content.split(separator: " ").count <= 15 && ["system", "interesting"].contains(m.category)
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
        request.timeoutInterval = 45

        let body: [String: Any] = ["system": system, "user": user]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("Calendar proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
