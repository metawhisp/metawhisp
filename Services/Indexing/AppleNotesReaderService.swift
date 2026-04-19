import Foundation
import SwiftData

/// Reads Apple Notes via AppleScript, extracts memories via LLM, persists with sourceFile FK.
///
/// Omi reference: `desktop/Desktop/Sources/AppleNotesReaderService.swift` reads NoteStore.sqlite
/// directly via GRDB. We use AppleScript bridge instead — no new dependencies, Apple Automation
/// permission flow (not Full Disk Access), full body access.
///
/// spec://BACKLOG#Phase3.E2
@MainActor
final class AppleNotesReaderService: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastSummary: String?
    @Published var lastRun: Date?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Max notes fetched per scan.
    private let maxNotesPerScan = 40
    /// Min content length to bother with LLM.
    private let minContentChars = 80
    /// Max content per note sent to LLM.
    private let maxContentCharsPerNote = 4000
    /// Min confidence for memory acceptance.
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
        NSLog("[AppleNotes] ✅ Periodic every %.0fs", interval)
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Fetch Apple Notes via AppleScript + extract memories.
    func scanNow() async {
        guard !isRunning else { return }
        guard settings.appleNotesEnabled else { return }
        guard hasLLMAccess else { return }
        guard let container = modelContainer else { return }

        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        // 1. Run AppleScript → get notes.
        let notes: [AppleNotePayload]
        do {
            notes = try await fetchNotes(limit: maxNotesPerScan)
        } catch {
            lastError = error.localizedDescription
            NSLog("[AppleNotes] ❌ AppleScript failed: %@", error.localizedDescription)
            return
        }

        guard !notes.isEmpty else {
            lastSummary = "No notes found"
            return
        }
        NSLog("[AppleNotes] Fetched %d notes", notes.count)

        // 2. Filter: only new since last scan (via sourceFile "apple-note:<id>" dedup)
        //          + only notes with meaningful body length.
        let ctx = ModelContext(container)
        let processedIds = fetchAlreadyProcessedNoteIds(in: ctx)
        let pending = notes.filter { !processedIds.contains($0.id) && $0.body.count >= minContentChars }

        guard !pending.isEmpty else {
            lastSummary = "No new notes to process"
            return
        }
        NSLog("[AppleNotes] Processing %d new notes", pending.count)

        // 3. Per-note LLM extraction.
        let existingContents = fetchRecentMemoryContents(in: ctx, limit: 150)
        var totalAdded = 0
        for note in pending {
            let prompt = buildPrompt(note: note, existing: existingContents)
            do {
                let response: String
                if LicenseService.shared.isPro, let licenseKey = LicenseService.shared.licenseKey {
                    response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: licenseKey)
                } else {
                    let apiKey = settings.activeAPIKey
                    guard !apiKey.isEmpty else { break }
                    let provider = LLMProvider(rawValue: settings.llmProvider) ?? .openai
                    response = try await llm.complete(
                        system: Self.systemPrompt,
                        user: prompt,
                        apiKey: apiKey,
                        provider: provider
                    )
                }
                let mems = parse(response)
                for m in mems where m.confidence >= minConfidence {
                    let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if existingContents.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { continue }
                    let rec = UserMemory(
                        content: trimmed,
                        category: m.category,
                        sourceApp: "Apple Notes",
                        confidence: m.confidence,
                        windowTitle: note.title,
                        contextSummary: note.folder,
                        conversationId: nil,
                        screenContextId: nil,
                        sourceFile: "apple-note:\(note.id)"
                    )
                    ctx.insert(rec)
                    totalAdded += 1
                }
            } catch {
                NSLog("[AppleNotes] ❌ Note %@ failed: %@", note.id, error.localizedDescription)
            }
        }
        try? ctx.save()
        lastSummary = "Processed \(pending.count) notes, added \(totalAdded) memories"
        NSLog("[AppleNotes] ✅ %@", lastSummary ?? "")
    }

    // MARK: - AppleScript bridge

    private struct AppleNotePayload {
        let id: String
        let title: String
        let body: String
        let folder: String
        let modifiedAt: Date?
    }

    private func fetchNotes(limit: Int) async throws -> [AppleNotePayload] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = Self.readNotesAppleScript(limit: limit)
                let process = Process()
                process.launchPath = "/usr/bin/osascript"
                process.arguments = ["-e", script]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if process.terminationStatus != 0 {
                        cont.resume(throwing: NSError(
                            domain: "AppleNotes",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "AppleScript failed" : err]
                        ))
                        return
                    }
                    let notes = Self.parseAppleScriptOutput(out)
                    cont.resume(returning: notes)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Build AppleScript. Returns notes as delimited string: id|||title|||body|||folder|||modDate<<<END>>>
    /// Uses <<<END>>> as record separator to survive \n inside bodies.
    private static func readNotesAppleScript(limit: Int) -> String {
        return """
        tell application "Notes"
            set output to ""
            set allNotes to notes
            set noteCount to 0
            repeat with n in allNotes
                if noteCount ≥ \(limit) then exit repeat
                try
                    set nId to id of n
                    set nTitle to (name of n as string)
                    set nBody to (plaintext of n as string)
                    set nFolder to "Notes"
                    try
                        set nFolder to (name of container of n as string)
                    end try
                    set nMod to (modification date of n as string)
                    set output to output & nId & "|||" & nTitle & "|||" & nBody & "|||" & nFolder & "|||" & nMod & "<<<END>>>"
                    set noteCount to noteCount + 1
                end try
            end repeat
            return output
        end tell
        """
    }

    private static func parseAppleScriptOutput(_ raw: String) -> [AppleNotePayload] {
        let records = raw.components(separatedBy: "<<<END>>>")
        var result: [AppleNotePayload] = []
        for rec in records {
            let trimmed = rec.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|||")
            guard parts.count >= 5 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = parts[2]
            let folder = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let modStr = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let modDate = parseAppleScriptDate(modStr)
            result.append(AppleNotePayload(id: id, title: title, body: body, folder: folder, modifiedAt: modDate))
        }
        return result
    }

    private static func parseAppleScriptDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Common AppleScript date format: "Saturday, April 19, 2026 at 12:30:45 PM"
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        if let d = f.date(from: raw) { return d }
        f.dateFormat = "MMMM d, yyyy 'at' h:mm:ss a"
        return f.date(from: raw)
    }

    // MARK: - Prompt (mirror FileMemoryExtractor)

    static let systemPrompt = """
    You are an expert memory curator. Extract high-value durable facts about the user from a single Apple Note they wrote or pasted.

    Apply Omi-strict rules (same as voice/file memory extraction):
    - Each memory ≤ 15 words. Start SYSTEM memories with "User".
    - Two categories: "system" (facts about user) / "interesting" (external wisdom with attribution).
    - DEFAULT TO EMPTY LIST. Max 3 memories per note.

    ACCEPT:
    - Named projects user builds / works on.
    - Named people in user's network with role.
    - Concrete preferences with reasoning.
    - Stated goals / commitments.
    - Domain expertise / role.

    REJECT:
    - Generic preferences, temporal items, quotes from third-party content user pasted,
      transient verbs ("is working on"), hedging, anything applicable to any Mac user.

    Dedup against existing memories shown in prompt.

    Return JSON: {"memories": [{"content": "...", "category": "system|interesting", "confidence": 0.0-1.0}]}
    If nothing: {"memories": []}

    CRITICAL: Respond with ONLY the JSON object. No prose. No markdown fences.
    """

    private func buildPrompt(note: AppleNotePayload, existing: [String]) -> String {
        var parts: [String] = []
        if !existing.isEmpty {
            parts.append("Existing memories (do NOT duplicate):")
            for m in existing.prefix(100) { parts.append("- \(m)") }
            parts.append("")
        }
        parts.append("Apple Note — Title: \(note.title)  Folder: \(note.folder)")
        parts.append("Body:")
        parts.append("```")
        parts.append(String(note.body.prefix(maxContentCharsPerNote)))
        parts.append("```")
        return parts.joined(separator: "\n")
    }

    // MARK: - Fetch helpers

    private func fetchAlreadyProcessedNoteIds(in ctx: ModelContext) -> Set<String> {
        let desc = FetchDescriptor<UserMemory>()
        let memories = (try? ctx.fetch(desc)) ?? []
        var ids = Set<String>()
        for m in memories {
            guard let src = m.sourceFile, src.hasPrefix("apple-note:") else { continue }
            ids.insert(String(src.dropFirst("apple-note:".count)))
        }
        return ids
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
    private struct Result: Decodable {
        let memories: [MemoryJSON]
    }

    private func parse(_ response: String) -> [MemoryJSON] {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return [] }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else { return [] }
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
            throw ProcessingError.apiError("AppleNotes proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
