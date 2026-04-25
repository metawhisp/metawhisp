import Foundation
import SwiftData

/// Pro-proxy client for OpenAI `text-embedding-3-small` (1536 dims).
/// Used for:
/// - Semantic dedup: reject new memory/task when cosine similarity to existing > 0.92.
/// - Semantic retrieval: MetaChat RAG picks top-K records by similarity to user question.
/// - Backfill: fills embedding field on rows created before this rollout.
///
/// Graceful degradation: when LLM access is unavailable or the call fails, callers
/// write the row with `embedding = nil` and fall back to string-matching retrieval.
/// spec://iterations/ITER-008-embeddings
@MainActor
final class EmbeddingService: ObservableObject {
    /// Embedding dimension for text-embedding-3-small.
    static let dimension = 1536

    /// Cosine-similarity threshold for rejecting near-duplicates on insert.
    /// 0.92 calibrated empirically: "User likes coffee" vs "User enjoys drinking coffee"
    /// ≈ 0.95, same-meaning paraphrases ≈ 0.90-0.97; unrelated content stays < 0.75.
    static let dedupThreshold: Float = 0.92

    @Published var isRunning = false
    @Published var lastError: String?

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public API

    /// Embed an array of texts via Pro proxy. Returns vectors aligned to input order.
    /// Requires LicenseService.shared.isPro + valid licenseKey. Throws otherwise.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard texts.count <= 100 else {
            throw NSError(domain: "Embedding", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "max 100 texts per call"])
        }
        guard let key = LicenseService.shared.licenseKey, LicenseService.shared.isPro else {
            throw NSError(domain: "Embedding", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Pro license required for embeddings"])
        }

        let url = URL(string: "https://api.metawhisp.com/api/pro/embed")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["texts": texts])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Embedding", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(snippet)"])
        }

        struct EmbedResponse: Decodable { let embeddings: [[Float]] }
        let parsed = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard parsed.embeddings.count == texts.count else {
            throw NSError(domain: "Embedding", code: 502,
                          userInfo: [NSLocalizedDescriptionKey: "count mismatch: got \(parsed.embeddings.count), expected \(texts.count)"])
        }
        return parsed.embeddings
    }

    /// Embed a single text. Convenience wrapper.
    func embedOne(_ text: String) async throws -> [Float] {
        let vectors = try await embed([text])
        guard let first = vectors.first else {
            throw NSError(domain: "Embedding", code: 500, userInfo: [NSLocalizedDescriptionKey: "empty response"])
        }
        return first
    }

    // MARK: - Math

    /// Cosine similarity between two vectors. Returns value in [-1, 1].
    /// Returns 0 for mismatched dimensions or zero vectors (safe degenerate case).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrtf(normA) * sqrtf(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Serialization

    /// Pack [Float] → Data (raw Float32 LE bytes).
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    /// Unpack Data → [Float]. Returns empty on malformed input.
    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - Fire-and-forget helpers (called from extractors after insert)

    /// Embed freshly-inserted memories in background. Graceful fail: nil embedding
    /// just means the row falls back to string matching in MetaChat.
    nonisolated func embedMemoriesInBackground(_ memories: [UserMemory], in ctx: ModelContext) {
        guard !memories.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let texts = memories.map(\.content)
            do {
                let vectors = try await self.embed(texts)
                for (memory, vec) in zip(memories, vectors) {
                    memory.embedding = Self.encode(vec)
                }
                try? ctx.save()
                NSLog("[EmbeddingService] Embedded %d new memories", memories.count)
            } catch {
                NSLog("[EmbeddingService] Memory embed failed (graceful): %@", error.localizedDescription)
            }
        }
    }

    /// Embed freshly-inserted tasks in background.
    nonisolated func embedTasksInBackground(_ tasks: [TaskItem], in ctx: ModelContext) {
        guard !tasks.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let texts = tasks.map(\.taskDescription)
            do {
                let vectors = try await self.embed(texts)
                for (task, vec) in zip(tasks, vectors) {
                    task.embedding = Self.encode(vec)
                }
                try? ctx.save()
                NSLog("[EmbeddingService] Embedded %d new tasks", tasks.count)
            } catch {
                NSLog("[EmbeddingService] Task embed failed (graceful): %@", error.localizedDescription)
            }
        }
    }

    /// Embed a freshly-finalized Conversation in background. Source text is built
    /// from `title + overview + transcript prefix` so the LLM sees both the structured
    /// summary and concrete content (names, projects, decisions). Fire-and-forget;
    /// nil embedding just means MetaChat falls back to recency for this conversation.
    nonisolated func embedConversationInBackground(_ conversation: Conversation,
                                                    sourceText: String,
                                                    in ctx: ModelContext) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let vec = try await self.embedOne(text)
                conversation.embedding = Self.encode(vec)
                try? ctx.save()
                NSLog("[EmbeddingService] Embedded conversation %@",
                      conversation.id.uuidString.prefix(8) as CVarArg)
            } catch {
                NSLog("[EmbeddingService] Conversation embed failed (graceful): %@",
                      error.localizedDescription)
            }
        }
    }

    // MARK: - Dedup helper

    /// True if `candidate` vector is ≥ threshold cosine-similar to any vector in `against`.
    /// Skips empty vectors in `against`. Used by extractors before insert.
    static func isSemanticDuplicate(candidate: [Float],
                                    against: [[Float]],
                                    threshold: Float = dedupThreshold) -> Bool {
        guard !candidate.isEmpty else { return false }
        for other in against where other.count == candidate.count {
            if cosineSimilarity(candidate, other) >= threshold {
                return true
            }
        }
        return false
    }

    // MARK: - Backfill (one-time on app startup)

    /// Fill missing `embedding` on UserMemory + TaskItem + Conversation rows.
    /// Batches of up to 50 per call. No-op when not Pro. Runs in background.
    func backfillMissing() async {
        guard LicenseService.shared.isPro, let _ = LicenseService.shared.licenseKey else { return }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)

        // Fetch memories missing embedding.
        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate<UserMemory> { !$0.isDismissed && $0.embedding == nil }
        )
        let memories = (try? ctx.fetch(memDesc)) ?? []

        // Fetch tasks missing embedding (skip dismissed, skip the "dismissed" status).
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isDismissed && $0.embedding == nil }
        )
        let allTasks = (try? ctx.fetch(taskDesc)) ?? []
        let tasks = allTasks.filter { $0.status != "dismissed" }

        // Fetch conversations missing embedding. Only completed ones — in-progress
        // rows don't have stable title/overview yet, would re-embed on close anyway.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { !$0.discarded && $0.embedding == nil && $0.status == "completed" }
        )
        let conversations = (try? ctx.fetch(convDesc)) ?? []
        // Build source text per conversation upfront — joined transcript fetched here
        // so the backfill loop stays in pure embed mode.
        let convSources: [(Conversation, String)] = conversations.compactMap { conv in
            let text = Self.buildConversationEmbeddingSource(for: conv, in: ctx)
            return text.isEmpty ? nil : (conv, text)
        }

        guard !memories.isEmpty || !tasks.isEmpty || !convSources.isEmpty else {
            NSLog("[EmbeddingBackfill] Nothing to backfill")
            return
        }

        NSLog("[EmbeddingBackfill] Starting: %d memories, %d tasks, %d conversations",
              memories.count, tasks.count, convSources.count)

        do {
            try await backfill(items: memories, text: { $0.content }, assign: { $0.embedding = $1 }, ctx: ctx, kind: "memories")
            try await backfill(items: tasks, text: { $0.taskDescription }, assign: { $0.embedding = $1 }, ctx: ctx, kind: "tasks")
            // Conversations need a paired (item, text) tuple because the source text
            // isn't a single property — it's title + overview + transcript prefix.
            try await backfillPaired(pairs: convSources, assign: { $0.embedding = $1 }, ctx: ctx, kind: "conversations")
            NSLog("[EmbeddingBackfill] ✅ Embedded %d memories, %d tasks, %d conversations",
                  memories.count, tasks.count, convSources.count)
        } catch {
            lastError = error.localizedDescription
            NSLog("[EmbeddingBackfill] ❌ Failed: %@", error.localizedDescription)
        }
    }

    /// Build the canonical source text for a Conversation embedding.
    /// `title + " · " + overview + " " + transcript prefix (≤1200 chars)`.
    /// Static so it can be reused by StructuredGenerator without instantiating EmbeddingService.
    static func buildConversationEmbeddingSource(for conv: Conversation,
                                                  in ctx: ModelContext,
                                                  transcriptCharLimit: Int = 1200) -> String {
        var parts: [String] = []
        if let t = conv.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            parts.append(t)
        }
        if let ov = conv.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !ov.isEmpty {
            parts.append(ov)
        }
        // Pull the linked transcripts in chronological order. Cap total chars so
        // very long meetings don't dominate the embedding (the title+overview are
        // the high-signal parts; transcript adds concrete subject anchors).
        let convId = conv.id
        var histDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate<HistoryItem> { $0.conversationId == convId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        histDesc.fetchLimit = 50
        let items = (try? ctx.fetch(histDesc)) ?? []
        var transcript = items.map(\.displayText).joined(separator: " ")
        if transcript.count > transcriptCharLimit {
            transcript = String(transcript.prefix(transcriptCharLimit))
        }
        if !transcript.isEmpty { parts.append(transcript) }
        return parts.joined(separator: " · ")
    }

    private func backfill<Item: AnyObject>(items: [Item],
                                           text: (Item) -> String,
                                           assign: (Item, Data) -> Void,
                                           ctx: ModelContext,
                                           kind: String) async throws {
        let batchSize = 50
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            let batch = Array(items[batchStart..<batchEnd])
            let texts = batch.map(text)
            let vectors = try await embed(texts)
            for (item, vec) in zip(batch, vectors) {
                assign(item, Self.encode(vec))
            }
            try? ctx.save()
            NSLog("[EmbeddingBackfill] %@ batch %d/%d done", kind, batchEnd, items.count)
            // Tiny pause so backfill doesn't starve other tasks.
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Same as `backfill` but the source text is precomputed per item (e.g. when text
    /// is built from multiple fields + DB lookups, not a single property accessor).
    private func backfillPaired<Item: AnyObject>(pairs: [(Item, String)],
                                                  assign: (Item, Data) -> Void,
                                                  ctx: ModelContext,
                                                  kind: String) async throws {
        let batchSize = 50
        for batchStart in stride(from: 0, to: pairs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, pairs.count)
            let batch = Array(pairs[batchStart..<batchEnd])
            let texts = batch.map(\.1)
            let vectors = try await embed(texts)
            for ((item, _), vec) in zip(batch, vectors) {
                assign(item, Self.encode(vec))
            }
            try? ctx.save()
            NSLog("[EmbeddingBackfill] %@ batch %d/%d done", kind, batchEnd, pairs.count)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
