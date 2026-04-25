import Foundation
import SwiftData

/// Aggregates `Conversation.primaryProject` raw strings into canonical Project clusters
/// via `ProjectAlias`, then surfaces summaries + details for the Projects view + MetaChat.
///
/// Two paths feed canonicalization:
/// 1. **Cheap path** (`resolveCanonical`) — case-insensitive exact match against any
///    alias of an existing `ProjectAlias`. Hit → reuse canonical. Miss → create new row.
/// 2. **Quality path** (`mergeAliases`) — periodic embedding-similarity pass across
///    `ProjectAlias.centroidEmbedding` pairs. Pairs with cosine > 0.88 collapse:
///    smaller (fewer aliases) merges INTO larger.
///
/// Backfill: on app launch, run `backfillProjects()` to re-trigger StructuredGenerator
/// for `Conversation` rows with `primaryProject == nil && status == "completed"` so
/// existing meetings get classified retroactively.
///
/// spec://iterations/ITER-014-project-clustering
@MainActor
final class ProjectAggregator: ObservableObject {
    @Published var lastError: String?
    @Published var lastBackfillCount: Int = 0
    @Published var lastMergeCount: Int = 0

    private var modelContainer: ModelContainer?
    /// Cosine threshold for merging two project centroids. 0.88 calibrated to
    /// catch "Overchat" vs "OverchatAI" while not collapsing "Overchat" vs "Overmind".
    /// Same family of thresholds as `EmbeddingService.dedupThreshold` (0.92) but
    /// looser because project names are short and contextual variation is wider.
    private let mergeThreshold: Float = 0.88

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public API used by Projects view + MetaChat + backfill

    /// All known project clusters with up-to-date counts of linked items.
    /// Returns sorted by lastActivity desc (most recently touched on top).
    func listProjects() -> [ProjectSummary] {
        guard let ctx = ctx() else { return [] }

        // 1. Pull all aliases. Empty → no projects yet.
        let aliasDesc = FetchDescriptor<ProjectAlias>(
            sortBy: [SortDescriptor(\.canonicalName, order: .forward)]
        )
        let allAliases = (try? ctx.fetch(aliasDesc)) ?? []
        guard !allAliases.isEmpty else { return [] }

        // 2. Build raw → canonical map for fast lookup against Conversation.primaryProject.
        var rawToCanonical: [String: String] = [:]
        for alias in allAliases {
            for raw in alias.aliases {
                rawToCanonical[raw.lowercased()] = alias.canonicalName
            }
        }

        // 3. Pull all completed conversations with a project tag. We do counts in-memory
        //    rather than per-canonical fetches because predicate-side OR-of-aliases is
        //    awkward in SwiftData.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        )
        let allConvs = (try? ctx.fetch(convDesc)) ?? []

        // 4. Aggregate per-canonical.
        var bucket: [String: BucketState] = [:]
        for conv in allConvs {
            guard let raw = conv.primaryProject?.lowercased(),
                  let canonical = rawToCanonical[raw] else { continue }
            var state = bucket[canonical] ?? BucketState()
            state.conversationCount += 1
            state.conversationIds.append(conv.id)
            if let lst = state.lastActivity {
                if conv.startedAt > lst { state.lastActivity = conv.startedAt }
            } else {
                state.lastActivity = conv.startedAt
            }
            bucket[canonical] = state
        }

        // 5. Pull tasks + memories linked through conversation IDs we collected.
        // Task counts: split MY (assignee==nil) from waiting-on (anyone else).
        if !bucket.isEmpty {
            let allConvIds = Set(bucket.values.flatMap { $0.conversationIds })
            let taskDesc = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> {
                    !$0.isDismissed && $0.conversationId != nil
                }
            )
            for t in (try? ctx.fetch(taskDesc)) ?? [] {
                guard let cid = t.conversationId, allConvIds.contains(cid) else { continue }
                // Find canonical for this conversation.
                guard let conv = allConvs.first(where: { $0.id == cid }),
                      let raw = conv.primaryProject?.lowercased(),
                      let canonical = rawToCanonical[raw],
                      var state = bucket[canonical] else { continue }
                if t.completed {
                    state.completedTaskCount += 1
                } else if t.effectiveStatus == "committed" {
                    state.pendingTaskCount += 1
                    if let assignee = t.assignee?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !assignee.isEmpty {
                        state.members.insert(assignee)
                    }
                }
                bucket[canonical] = state
            }
            let memDesc = FetchDescriptor<UserMemory>(
                predicate: #Predicate<UserMemory> {
                    !$0.isDismissed && $0.conversationId != nil
                }
            )
            for m in (try? ctx.fetch(memDesc)) ?? [] {
                guard let cid = m.conversationId, allConvIds.contains(cid) else { continue }
                guard let conv = allConvs.first(where: { $0.id == cid }),
                      let raw = conv.primaryProject?.lowercased(),
                      let canonical = rawToCanonical[raw],
                      var state = bucket[canonical] else { continue }
                state.memoryCount += 1
                bucket[canonical] = state
            }
        }

        // 6. Materialize ProjectSummary in last-activity order.
        return bucket
            .compactMap { (canonical, state) -> ProjectSummary? in
                guard let last = state.lastActivity else { return nil }
                return ProjectSummary(
                    canonicalName: canonical,
                    conversationCount: state.conversationCount,
                    memoryCount: state.memoryCount,
                    pendingTaskCount: state.pendingTaskCount,
                    completedTaskCount: state.completedTaskCount,
                    lastActivity: last,
                    members: state.members
                )
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Detail bundle for a single project — used by ProjectDetailView.
    func details(for canonicalName: String) -> ProjectDetails {
        guard let ctx = ctx() else {
            return ProjectDetails(canonicalName: canonicalName, conversations: [],
                                   memories: [], tasks: [])
        }
        guard let alias = aliasRow(named: canonicalName, ctx: ctx) else {
            return ProjectDetails(canonicalName: canonicalName, conversations: [],
                                   memories: [], tasks: [])
        }
        let aliasesLower = Set(alias.aliases.map { $0.lowercased() })

        // Pull completed conversations whose primaryProject matches any alias.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let convs = ((try? ctx.fetch(convDesc)) ?? [])
            .filter { aliasesLower.contains(($0.primaryProject ?? "").lowercased()) }
        let convIds = Set(convs.map { $0.id })

        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let tasks = ((try? ctx.fetch(taskDesc)) ?? [])
            .filter { $0.conversationId.map { convIds.contains($0) } ?? false }

        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let mems = ((try? ctx.fetch(memDesc)) ?? [])
            .filter { $0.conversationId.map { convIds.contains($0) } ?? false }

        return ProjectDetails(
            canonicalName: canonicalName,
            conversations: convs,
            memories: mems,
            tasks: tasks
        )
    }

    /// Delete a project cluster (ITER-021.1).
    ///
    /// Two-step operation:
    /// 1. UNLINK every `Conversation` whose `primaryProject` matches any of the
    ///    cluster's aliases (case-insensitive) — sets it to `nil`. Conversations
    ///    themselves are NOT deleted; only their project tag is cleared. The
    ///    transcript / memories / tasks linked to those conversations stay intact.
    /// 2. DELETE the `ProjectAlias` row so the cluster disappears from
    ///    `listProjects()` immediately.
    ///
    /// Returns the number of conversations that were unlinked, for UI feedback
    /// ("Removed project X — 6 conversations are now uncategorized").
    ///
    /// Idempotent: deleting an already-gone project returns 0 with no error.
    @discardableResult
    func deleteProject(canonicalName: String) -> Int {
        guard let ctx = ctx() else { return 0 }
        guard let alias = aliasRow(named: canonicalName, ctx: ctx) else {
            NSLog("[ProjectAggregator] deleteProject: alias '%@' not found — no-op",
                  canonicalName)
            return 0
        }
        let aliasesLower = Set(alias.aliases.map { $0.lowercased() })

        // Step 1 — unlink. Predicate-side OR-of-aliases is awkward in SwiftData,
        // so fetch all primary-project-tagged convs and filter in Swift. Cheap
        // — there are typically <100 such rows.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        )
        let convs = (try? ctx.fetch(convDesc)) ?? []
        var unlinked = 0
        for c in convs {
            let raw = (c.primaryProject ?? "").lowercased()
            if aliasesLower.contains(raw) {
                c.primaryProject = nil
                c.updatedAt = Date()
                unlinked += 1
            }
        }

        // Step 2 — delete the alias row. After save, listProjects() no longer
        // surfaces this cluster.
        ctx.delete(alias)
        try? ctx.save()
        NSLog("[ProjectAggregator] 🗑 deleted project '%@' — %d conversations unlinked",
              canonicalName, unlinked)
        return unlinked
    }

    /// Take a raw project name (from `Conversation.primaryProject`), find or create
    /// its canonical alias. Always returns a canonical name.
    /// Side effect: inserts a new `ProjectAlias` row if no match.
    @discardableResult
    func resolveCanonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ctx = ctx() else { return trimmed }

        // Cheap path: case-insensitive substring/exact match across all aliases.
        let allDesc = FetchDescriptor<ProjectAlias>()
        for alias in (try? ctx.fetch(allDesc)) ?? [] {
            if alias.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                return alias.canonicalName
            }
        }

        // Miss → new row. Canonical = first observed variant (we don't try to "prettify").
        let new = ProjectAlias(canonicalName: trimmed)
        ctx.insert(new)
        try? ctx.save()
        NSLog("[ProjectAggregator] +new project alias: %@", trimmed)
        return new.canonicalName
    }

    /// Re-run StructuredGenerator for completed conversations missing `primaryProject`
    /// (rows finalized before ITER-014 ship). Skips placeholder titles — those are handled
    /// by `StructuredGenerator.backfillPlaceholders()` independently.
    func backfillProjects(structuredGenerator: StructuredGenerator) async {
        guard let ctx = ctx() else { return }
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded
                && $0.status == "completed"
                && $0.primaryProject == nil
                && $0.title != nil
                && $0.title != "Quick note"
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        desc.fetchLimit = 200
        let needs = (try? ctx.fetch(desc)) ?? []
        guard !needs.isEmpty else {
            NSLog("[ProjectAggregator] backfill: nothing to do")
            return
        }
        NSLog("[ProjectAggregator] backfill: %d conversations need project tag", needs.count)

        var done = 0
        for conv in needs {
            // Reset the structured fields so generate() takes the full LLM path
            // (it short-circuits when title+overview are present).
            conv.title = nil
            conv.overview = nil
            conv.category = nil
            conv.emoji = nil
            try? ctx.save()
            await structuredGenerator.generate(conversationId: conv.id)
            done += 1
            // After each generate, also run resolveCanonical to seed ProjectAlias.
            if let raw = conv.primaryProject {
                _ = resolveCanonical(raw)
            }
            // Tiny pause so we don't hammer the proxy.
            try? await Task.sleep(for: .milliseconds(300))
        }
        lastBackfillCount = done
        NSLog("[ProjectAggregator] backfill done: %d conversations classified", done)
    }

    /// Periodic merge pass: compute centroid per ProjectAlias from its conversations'
    /// embeddings, then collapse pairs with cosine > mergeThreshold. Smaller cluster
    /// (fewer aliases) merges INTO larger; larger keeps its canonical name.
    func mergeAliases() async {
        guard let ctx = ctx() else { return }
        let allDesc = FetchDescriptor<ProjectAlias>()
        var aliases = (try? ctx.fetch(allDesc)) ?? []
        guard aliases.count >= 2 else { return }

        // 1. Refresh centroid for each alias from its tagged conversations.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil && $0.embedding != nil }
        )
        let convs = (try? ctx.fetch(convDesc)) ?? []
        for alias in aliases {
            let aliasesLower = Set(alias.aliases.map { $0.lowercased() })
            let vecs: [[Float]] = convs.compactMap { c in
                guard aliasesLower.contains((c.primaryProject ?? "").lowercased()),
                      let data = c.embedding else { return nil }
                let v = EmbeddingService.decode(data)
                return v.isEmpty ? nil : v
            }
            if vecs.isEmpty { alias.centroidEmbedding = nil; continue }
            let dim = vecs[0].count
            var sum = [Float](repeating: 0, count: dim)
            for v in vecs where v.count == dim {
                for i in 0..<dim { sum[i] += v[i] }
            }
            let centroid = sum.map { $0 / Float(vecs.count) }
            alias.centroidEmbedding = EmbeddingService.encode(centroid)
        }
        try? ctx.save()

        // 2. Compare pairs. Greedy merge: bigger absorbs smaller.
        // Re-fetch (centroids updated above).
        aliases = (try? ctx.fetch(allDesc)) ?? []
        var merges = 0
        var dead = Set<UUID>()
        let withCentroid = aliases.filter { $0.centroidEmbedding != nil }
        for i in 0..<withCentroid.count {
            let a = withCentroid[i]
            if dead.contains(a.id) { continue }
            for j in (i + 1)..<withCentroid.count {
                let b = withCentroid[j]
                if dead.contains(b.id) { continue }
                guard let aData = a.centroidEmbedding, let bData = b.centroidEmbedding else { continue }
                let aVec = EmbeddingService.decode(aData)
                let bVec = EmbeddingService.decode(bData)
                let sim = EmbeddingService.cosineSimilarity(aVec, bVec)
                guard sim >= mergeThreshold else { continue }
                // Merge smaller into larger.
                let (winner, loser) = a.aliases.count >= b.aliases.count ? (a, b) : (b, a)
                for alias in loser.aliases { winner.addAlias(alias) }
                dead.insert(loser.id)
                ctx.delete(loser)
                merges += 1
                NSLog("[ProjectAggregator] merge: '%@' + '%@' (sim=%.3f)",
                      winner.canonicalName, loser.canonicalName, sim)
            }
        }
        try? ctx.save()
        lastMergeCount = merges
    }

    // MARK: - Internal helpers

    private func ctx() -> ModelContext? {
        guard let container = modelContainer else { return nil }
        return ModelContext(container)
    }

    private func aliasRow(named: String, ctx: ModelContext) -> ProjectAlias? {
        let allDesc = FetchDescriptor<ProjectAlias>()
        return (try? ctx.fetch(allDesc))?
            .first { $0.aliases.contains { $0.localizedCaseInsensitiveCompare(named) == .orderedSame } }
    }

    private struct BucketState {
        var conversationCount = 0
        var memoryCount = 0
        var pendingTaskCount = 0
        var completedTaskCount = 0
        var lastActivity: Date?
        var conversationIds: [UUID] = []
        var members: Set<String> = []
    }
}

// MARK: - DTOs

struct ProjectSummary: Identifiable {
    let canonicalName: String
    let conversationCount: Int
    let memoryCount: Int
    let pendingTaskCount: Int
    let completedTaskCount: Int
    let lastActivity: Date
    let members: Set<String>

    var id: String { canonicalName }
}

struct ProjectDetails {
    let canonicalName: String
    let conversations: [Conversation]
    let memories: [UserMemory]
    let tasks: [TaskItem]
}
