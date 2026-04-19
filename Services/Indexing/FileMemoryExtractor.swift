import Foundation
import SwiftData

/// Reads text content from indexed .md/.txt files, sends to LLM, saves UserMemory rows with sourceFile FK.
/// Runs as a second pass after FileIndexerService populates IndexedFile records.
///
/// Prompt adapted from Omi's memory extraction (`backend/utils/prompts.py:12`) — same strict
/// accept/reject rules, but input is a single file's content instead of voice transcript.
///
/// spec://BACKLOG#Phase3.E1
@MainActor
final class FileMemoryExtractor: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var lastSummary: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Max file content chars fed to LLM (safety cap, Pro proxy backend has ~32K limit).
    private let maxContentChars = 12_000
    /// Cap files processed per run — LLM cost control.
    private let maxFilesPerRun = 15
    /// Min confidence to accept extracted memory.
    private let minConfidence: Double = 0.7

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Process up to N pending IndexedFile records (contentExtractedAt == nil, isExtractable ext).
    func runPass() async {
        guard !isRunning else { return }
        guard hasLLMAccess else { return }
        guard let container = modelContainer else { return }

        isRunning = true
        defer { isRunning = false }

        let ctx = ModelContext(container)
        // Pending extractable files (md/txt/rtf/markdown).
        var desc = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { $0.contentExtractedAt == nil },
            sortBy: [SortDescriptor(\.indexedAt, order: .reverse)]
        )
        desc.fetchLimit = maxFilesPerRun * 4  // overfetch; filter client-side by extension
        let candidates = ((try? ctx.fetch(desc)) ?? [])
            .filter { IndexedFile.isExtractable($0.fileExtension) }
            .prefix(maxFilesPerRun)

        guard !candidates.isEmpty else {
            NSLog("[FileMemoryExtractor] No pending extractable files")
            return
        }

        // Pre-fetch existing memory contents for dedup hint in prompt.
        let existingContents = fetchRecentMemoryContents(in: ctx, limit: 150)

        var totalAdded = 0
        var totalProcessed = 0
        for file in candidates {
            guard let content = readFileContent(path: file.path) else {
                file.contentExtractedAt = Date()  // mark done so we don't retry unreadable files
                totalProcessed += 1
                continue
            }
            guard content.count >= 80 else {
                file.contentExtractedAt = Date()
                totalProcessed += 1
                continue
            }

            let prompt = buildPrompt(filename: file.filename, folder: file.folder, content: content, existing: existingContents)
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
                var added = 0
                for m in mems where m.confidence >= minConfidence {
                    let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if existingContents.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        continue
                    }
                    let rec = UserMemory(
                        content: trimmed,
                        category: m.category,
                        sourceApp: "File Indexer",
                        confidence: m.confidence,
                        windowTitle: file.filename,
                        contextSummary: file.folder,
                        conversationId: nil,
                        screenContextId: nil,
                        sourceFile: file.path
                    )
                    ctx.insert(rec)
                    added += 1
                }
                file.contentExtractedAt = Date()
                totalAdded += added
                totalProcessed += 1
            } catch {
                lastError = error.localizedDescription
                NSLog("[FileMemoryExtractor] ❌ %@: %@", file.filename, error.localizedDescription)
                // Don't mark contentExtractedAt — will retry next run.
            }
        }
        try? ctx.save()
        lastSummary = "Processed \(totalProcessed) files, added \(totalAdded) memories"
        NSLog("[FileMemoryExtractor] ✅ %@", lastSummary ?? "")
    }

    // MARK: - System prompt (adapted from Omi memory extraction)

    static let systemPrompt = """
    You are an expert memory curator. Extract high-value durable facts about the user from the content of a file they have stored on their Mac (likely a personal note, Obsidian vault page, draft, etc.).

    Apply Omi-strict rules:
    - Each memory ≤ 15 words, start SYSTEM memories with "User".
    - Two categories: "system" (facts about the user) / "interesting" (external wisdom WITH attribution: "Source: insight").
    - DEFAULT TO EMPTY LIST. Max 3 memories per file.

    ACCEPT:
    - Named projects user builds ("User builds Overchat, an AI ChatGPT wrapper").
    - Named people in network with role ("User's cofounder Vlad handles backend").
    - Concrete preferences with reasoning ("User prefers PARA method for Obsidian vault organization").
    - Stated goals / commitments ("User aims to ship MetaWhisp v1 by May").
    - Domain expertise ("User is founder of Overchat, AI wrapper company").

    REJECT:
    - Generic preferences ("likes coffee") without specifics.
    - Temporal/scheduled items ("meeting Thursday", "plan for next week").
    - Quotes from third-party content user pasted (book excerpts, articles) — these aren't facts about the user.
    - Transient verbs ("is working on", "is building") — too vague, will age out.
    - Hedging ("may be", "probably", "seems to").
    - Anything applicable to ANY Mac user.

    Dedup — existing memories are provided; do NOT re-extract semantically similar.

    Return JSON:
    {"memories": [{"content": "...", "category": "system|interesting", "confidence": 0.0-1.0}]}

    If nothing qualifies: {"memories": []}

    CRITICAL: Respond with ONLY the JSON object. No prose, no translation, no markdown fences.
    """

    // MARK: - Helpers

    private func buildPrompt(filename: String, folder: String, content: String, existing: [String]) -> String {
        var parts: [String] = []
        if !existing.isEmpty {
            parts.append("Existing memories (do NOT re-extract or duplicate):")
            for m in existing.prefix(100) { parts.append("- \(m)") }
            parts.append("")
        }
        parts.append("File: \(filename)  (from folder: \(folder))")
        parts.append("Content:")
        parts.append("```")
        parts.append(String(content.prefix(maxContentChars)))
        parts.append("```")
        let joined = parts.joined(separator: "\n")
        if joined.count > 20000 { return String(joined.prefix(20000)) }
        return joined
    }

    private func readFileContent(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        // Limit by file size first — avoid loading huge text.
        if data.count > 2 * 1024 * 1024 { return nil }  // 2 MB content cap
        return String(data: data, encoding: .utf8)
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
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            NSLog("[FileMemoryExtractor] ⚠️ Parse failed: %@", String(extracted.prefix(200)))
            return []
        }
        return result.memories.filter { mem in
            let wc = mem.content.split(separator: " ").count
            return wc <= 15 && ["system", "interesting"].contains(mem.category)
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
            throw ProcessingError.apiError("FileMemory proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty || LicenseService.shared.isPro
    }
}
