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

    // MARK: - ITER-018 — Conversation ↔ EKEvent linker

    /// Link a single Conversation to the best-matching EKEvent in its time
    /// neighborhood. No-op if calendar permission was never granted, or if
    /// the conversation has no startedAt, or if no candidate scores above
    /// threshold (0.5).
    ///
    /// Score = 0.6 × time-overlap-fraction + 0.4 × title-similarity (Jaccard
    /// over lowercase tokens of length ≥ 3). Title weight is the secondary
    /// signal because meeting titles drift between auto-generated structured
    /// titles and the calendar event's actual subject.
    ///
    /// spec://iterations/ITER-018-calendar-cross-ref
    func linkConversation(_ convId: UUID) async {
        guard settings.calendarReaderEnabled else { return }
        guard let container = modelContainer else { return }
        // Cheap pre-check: if access was never granted, EKEventStore returns
        // empty results — no point even fetching.
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .authorized else { return }
        }

        let ctx = ModelContext(container)
        var convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
        convDesc.fetchLimit = 1
        guard let conv = (try? ctx.fetch(convDesc))?.first else { return }
        // Skip if already linked (idempotent — backfill won't re-clobber a known link).
        guard conv.calendarEventId == nil else { return }

        let convStart = conv.startedAt
        // Determine reasonable convEnd: last HistoryItem.createdAt for this conv,
        // or finishedAt if set, or convStart + 30 min as fallback.
        let convEnd: Date = {
            if let f = conv.finishedAt { return f }
            // Fetch latest HistoryItem.
            var hd = FetchDescriptor<HistoryItem>(
                predicate: #Predicate { $0.conversationId == convId },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            hd.fetchLimit = 1
            if let last = (try? ctx.fetch(hd))?.first {
                return last.createdAt
            }
            return convStart.addingTimeInterval(30 * 60)
        }()
        // Padding window — we look 5 min before/after the conv span so that an
        // event scheduled slightly before user actually started recording still matches.
        let windowStart = convStart.addingTimeInterval(-5 * 60)
        let windowEnd   = convEnd.addingTimeInterval(5 * 60)

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let candidates = store.events(matching: predicate).filter { ev in
            // Exclude declined / cancelled.
            if ev.status == .canceled { return false }
            if let me = ev.attendees?.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined { return false }
            return true
        }
        guard !candidates.isEmpty else { return }

        // Score each candidate.
        let convTitle = conv.title ?? ""
        var best: (event: EKEvent, score: Double)?
        for ev in candidates {
            let evTitle = ev.title ?? ""
            let timeScore = Self.timeOverlapFraction(
                a: (convStart, convEnd),
                b: (ev.startDate, ev.endDate)
            )
            let titleScore = Self.tokenJaccard(convTitle, evTitle)
            let score = 0.6 * timeScore + 0.4 * titleScore
            if best == nil || score > best!.score {
                best = (ev, score)
            }
        }

        guard let (matched, score) = best, score >= 0.5 else {
            NSLog("[Calendar] no event match for conv %@ (best score %.2f)",
                  convId.uuidString.prefix(8) as CVarArg, best?.score ?? 0)
            return
        }

        // Save link snapshot.
        conv.calendarEventId = matched.eventIdentifier
        conv.calendarEventTitle = matched.title
        conv.calendarEventStartDate = matched.startDate
        conv.calendarEventEndDate = matched.endDate
        let attendeeNames = (matched.attendees ?? []).compactMap { participant -> String? in
            // Display name preferred, fall back to URL last component (email).
            if let name = participant.name, !name.isEmpty { return name }
            return participant.url.absoluteString.split(separator: ":").last.map(String.init)
        }
        conv.calendarAttendeesJSON = (try? String(data: JSONEncoder().encode(attendeeNames), encoding: .utf8)) ?? "[]"
        conv.updatedAt = Date()
        try? ctx.save()
        NSLog("[Calendar] ✅ linked conv %@ → event '%@' (score %.2f)",
              convId.uuidString.prefix(8) as CVarArg,
              matched.title ?? "(untitled)", score)
    }

    /// Backfill: walk completed conversations missing a calendar link, attempt to
    /// link each. Bounded to last 90 days to avoid scanning all history.
    /// Called from AppDelegate on launch (after grant + after a small delay).
    func backfillCalendarLinks() async {
        guard settings.calendarReaderEnabled else { return }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded
                && $0.status == "completed"
                && $0.calendarEventId == nil
                && $0.startedAt >= cutoff
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        desc.fetchLimit = 200
        let candidates = (try? ctx.fetch(desc)) ?? []
        guard !candidates.isEmpty else {
            NSLog("[Calendar] backfill links: nothing to do")
            return
        }
        NSLog("[Calendar] backfill links: %d conversations to attempt", candidates.count)
        var linked = 0
        for conv in candidates {
            await linkConversation(conv.id)
            // After save the row's calendarEventId either set or still nil.
            // Re-fetch for accurate counter — cheap on small results.
            if conv.calendarEventId != nil { linked += 1 }
            try? await Task.sleep(for: .milliseconds(20))
        }
        NSLog("[Calendar] backfill links: ✅ %d / %d linked", linked, candidates.count)
    }

    // MARK: - Linker scoring helpers (pure)

    /// Returns [0...1] — fraction of conversation duration that overlaps with the event.
    /// Falls back to a small reward (0.3) when the conv is zero-duration but lies inside
    /// the event window — useful for very short recordings made mid-meeting.
    static func timeOverlapFraction(a: (Date, Date), b: (Date, Date)) -> Double {
        let (aStart, aEnd) = a
        let (bStart, bEnd) = b
        let overlapStart = max(aStart, bStart)
        let overlapEnd = min(aEnd, bEnd)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        let aDuration = max(1, aEnd.timeIntervalSince(aStart))
        if overlap <= 0 { return 0 }
        // Cap fraction at 1.0 — if conv is much shorter than event we still want full credit.
        return min(1.0, overlap / aDuration)
    }

    /// Token Jaccard similarity over lowercase alphanum tokens of length ≥ 3.
    /// Returns 0 when either side is empty or no overlap.
    static func tokenJaccard(_ a: String, _ b: String) -> Double {
        let tok = { (s: String) -> Set<String> in
            Set(s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 })
        }
        let A = tok(a), B = tok(b)
        if A.isEmpty || B.isEmpty { return 0 }
        let inter = A.intersection(B).count
        let uni = A.union(B).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
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
