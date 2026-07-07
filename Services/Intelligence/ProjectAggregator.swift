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
    /// catch "ChatApp" vs "ChatAppAI" while not collapsing "ChatApp" vs "Overmind".
    /// Same family of thresholds as `EmbeddingService.dedupThreshold` (0.92) but
    /// looser because project names are short and contextual variation is wider.
    private let mergeThreshold: Float = 0.88

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public API used by Projects view + MetaChat + backfill

    /// All known project clusters with up-to-date counts of linked items.
    /// Returns sorted by lastActivity desc (most recently touched on top).
    ///
    /// ITER-032: by default hides projects with `conversationCount < 2` to
    /// keep the Projects view free of singleton noise (LLM-hallucinated
    /// one-off names). Pass `includeSingletons: true` to disable the gate
    /// (Settings → "Show all projects" toggle).
    func listProjects(includeSingletons: Bool = false) -> [ProjectSummary] {
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
        // ITER-032 display threshold — projects with only 1 conversation
        // are noise (typos, LLM hallucinations, one-off mentions). Filter
        // unless caller explicitly asked to include singletons.
        return bucket
            .compactMap { (canonical, state) -> ProjectSummary? in
                guard let last = state.lastActivity else { return nil }
                if !includeSingletons && state.conversationCount < 2 { return nil }
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

    /// Returns the list of all known variant strings for the alias whose
    /// canonical matches `canonicalName` (case-insensitive). Empty if not
    /// found. Used by ProjectDetailView to render the ALIASES section.
    func aliasVariants(for canonicalName: String) -> [String] {
        guard let ctx = ctx() else { return [] }
        guard let alias = aliasRow(named: canonicalName, ctx: ctx) else { return [] }
        return alias.aliases
    }

    // MARK: - Curative pass (ITER-032.2)

    /// One-shot curative migration. Runs on startup gated by an
    /// `@AppStorage` flag in `AppSettings`. Three phases:
    ///   1. **Reclassify suspect conversations** — for each conversation
    ///      whose `primaryProject` is a SUSPECT variant (not currently the
    ///      canonical of an established cluster), re-run StructuredGenerator
    ///      so the LLM picks again WITH the existing-canonicals hint
    ///      (ITER-032.1 prompt change). Often re-tags `HallucinatedName` → `Example Project`.
    ///   2. **Recanonicalize** — for each ProjectAlias, set canonical to
    ///      the variant with the highest conversation count. Garbage
    ///      variants with 0 references stop being the displayed name.
    ///   3. **Prune orphan aliases** — alias rows where ZERO conversations
    ///      reference any of their variants → delete.
    /// Returns counts for logging.
    @discardableResult
    func curativePass(generator: StructuredGenerator) async -> (reclassified: Int, recanonicalized: Int, pruned: Int) {
        let reclassified = await reclassifySuspiciousConversations(generator: generator)
        let recanonicalized = recanonicalizeAll()
        let pruned = pruneOrphanAliases()
        NSLog("[ProjectAggregator] curativePass — reclassified=%d recanonicalized=%d pruned=%d",
              reclassified, recanonicalized, pruned)
        return (reclassified, recanonicalized, pruned)
    }

    /// For each conversation tagged with a SUSPECT primaryProject value
    /// (not in established-canonicals list, where established = alias with
    /// conversationCount ≥ 2), re-run StructuredGenerator. The new prompt
    /// (ITER-032.1) injects existing canonicals so the LLM is encouraged
    /// to reuse them.
    private func reclassifySuspiciousConversations(generator: StructuredGenerator) async -> Int {
        guard let ctx = ctx() else { return 0 }
        // ITER-050 B1.1 — same wipe-before-check hazard as backfillProjects.
        guard generator.hasLLMAccess else {
            NSLog("[ProjectAggregator] reclassify: no LLM access — skipping")
            return 0
        }
        // Build set of "established" canonicals (≥ 2 conversations).
        let established = Set(listProjects(includeSingletons: false).map { $0.canonicalName.lowercased() })
        guard !established.isEmpty else {
            NSLog("[ProjectAggregator] reclassify: no established canonicals — skipping")
            return 0
        }
        // Pull conversations whose primaryProject is NOT in the established set.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil && $0.title != nil && $0.title != "Quick note" }
        )
        let allConvs = (try? ctx.fetch(convDesc)) ?? []
        let suspects = allConvs.filter { conv in
            guard let raw = conv.primaryProject?.lowercased() else { return false }
            return !established.contains(raw)
        }
        guard !suspects.isEmpty else { return 0 }
        NSLog("[ProjectAggregator] reclassify: %d suspect conversations", suspects.count)
        var done = 0
        for conv in suspects {
            // Snapshot first (ITER-050 B1.1) — restore on failed generate.
            let oldTitle = conv.title
            let oldOverview = conv.overview
            let oldCategory = conv.category
            let oldEmoji = conv.emoji
            let oldProject = conv.primaryProject
            // Reset structured fields so generator takes the full LLM path.
            conv.title = nil
            conv.overview = nil
            conv.category = nil
            conv.emoji = nil
            conv.primaryProject = nil
            try? ctx.save()
            let convId = conv.id
            await generator.generate(conversationId: convId)
            // Review fix — same stale-context hazard as backfillProjects:
            // decide success and restore through a fresh context.
            if let freshCtx = self.ctx(),
               let fresh = try? freshCtx.fetch(FetchDescriptor<Conversation>(
                   predicate: #Predicate { $0.id == convId })).first {
                if fresh.title == nil {
                    fresh.title = oldTitle
                    fresh.overview = oldOverview
                    fresh.category = oldCategory
                    fresh.emoji = oldEmoji
                    fresh.primaryProject = oldProject
                    try? freshCtx.save()
                    NSLog("[ProjectAggregator] reclassify: generate failed — restored fields for %@", "\(convId)")
                } else if let raw = fresh.primaryProject {
                    // resolveCanonical seeds the alias for whatever raw value
                    // the LLM produced.
                    _ = resolveCanonical(raw)
                }
            }
            done += 1
            try? await Task.sleep(for: .milliseconds(300))
        }
        return done
    }

    /// For every ProjectAlias, compute conversation counts per variant and
    /// promote the highest-count variant to canonical. Deterministic
    /// alphabetical tie-break. Skips aliases with only 1 variant (already
    /// canonical-as-only-variant).
    private func recanonicalizeAll() -> Int {
        guard let ctx = ctx() else { return 0 }
        let allAliases = (try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []
        guard !allAliases.isEmpty else { return 0 }
        // Tally Conversation.primaryProject (case-insensitive).
        let convs = (try? ctx.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        ))) ?? []
        var globalCounts: [String: Int] = [:]
        for c in convs {
            guard let raw = c.primaryProject?.lowercased() else { continue }
            globalCounts[raw, default: 0] += 1
        }
        var changed = 0
        for alias in allAliases where alias.aliases.count >= 2 {
            // Build counts dict scoped to THIS alias's variants only.
            var counts: [String: Int] = [:]
            for v in alias.aliases { counts[v.lowercased()] = globalCounts[v.lowercased()] ?? 0 }
            let pick = AliasCanonicalPicker.pickByConversationCount(
                variants: alias.aliases, counts: counts
            )
            if !pick.isEmpty,
               pick.localizedCaseInsensitiveCompare(alias.canonicalName) != .orderedSame {
                NSLog("[ProjectAggregator] recanonicalize: '%@' → '%@'",
                      alias.canonicalName, pick)
                alias.canonicalName = pick
                alias.updatedAt = Date()
                changed += 1
            }
        }
        try? ctx.save()
        return changed
    }

    /// Delete aliases whose every variant has ZERO conversation references.
    /// These are leftover hallucination clusters after `reclassifySuspicious`
    /// migrated all the conversations away.
    private func pruneOrphanAliases() -> Int {
        guard let ctx = ctx() else { return 0 }
        let allAliases = (try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []
        guard !allAliases.isEmpty else { return 0 }
        let convs = (try? ctx.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        ))) ?? []
        let referencedLowercased = Set(convs.compactMap { $0.primaryProject?.lowercased() })
        var deleted = 0
        for alias in allAliases {
            let aliasesLower = alias.aliases.map { $0.lowercased() }
            let anyReferenced = aliasesLower.contains { referencedLowercased.contains($0) }
            if !anyReferenced {
                NSLog("[ProjectAggregator] prune: '%@' (0 conversations across %d variants)",
                      alias.canonicalName, alias.aliases.count)
                ctx.delete(alias)
                deleted += 1
            }
        }
        try? ctx.save()
        return deleted
    }

    /// User-controlled rename to a free-form name. Unlike `setCanonical`,
    /// the new name does NOT need to already be in the aliases list — it's
    /// added if missing. Useful when the user wants a project to display
    /// under a name that the LLM never produced (e.g. shorter / cleaner).
    @discardableResult
    func renameCanonical(currentCanonical: String, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ctx = ctx() else { return false }
        guard let alias = aliasRow(named: currentCanonical, ctx: ctx) else {
            NSLog("[ProjectAggregator] renameCanonical: '%@' not found", currentCanonical)
            return false
        }
        // Add as variant if not already present.
        if !alias.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            alias.addAlias(trimmed)
        }
        let oldCanonical = alias.canonicalName
        alias.canonicalName = trimmed
        alias.updatedAt = Date()
        try? ctx.save()
        NSLog("[ProjectAggregator] renameCanonical: '%@' → '%@'", oldCanonical, trimmed)
        return true
    }

    // MARK: - User-controlled corrections (ITER-032.1)

    /// Set a different variant from the alias's `aliases` list as the new
    /// canonical name. Used by ProjectDetailView when the auto-picked
    /// canonical is wrong (e.g. LLM hallucination won the merge winner pick).
    /// The variant MUST already exist in the alias's aliases list — caller
    /// supplies one of the existing variants, not a free-form string.
    /// - Returns: `true` on success, `false` if alias/variant not found.
    @discardableResult
    func setCanonical(currentCanonical: String, newCanonical: String) -> Bool {
        guard let ctx = ctx() else { return false }
        guard let alias = aliasRow(named: currentCanonical, ctx: ctx) else {
            NSLog("[ProjectAggregator] setCanonical: '%@' not found", currentCanonical)
            return false
        }
        // Variant must already be in aliases (case-insensitive match).
        guard alias.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(newCanonical) == .orderedSame }) else {
            NSLog("[ProjectAggregator] setCanonical: '%@' not in aliases of '%@'", newCanonical, currentCanonical)
            return false
        }
        // Pick the EXACTLY-cased variant from aliases so we preserve original input.
        let exactCased = alias.aliases.first { $0.localizedCaseInsensitiveCompare(newCanonical) == .orderedSame } ?? newCanonical
        let oldCanonical = alias.canonicalName
        alias.canonicalName = exactCased
        alias.updatedAt = Date()
        try? ctx.save()
        NSLog("[ProjectAggregator] setCanonical: '%@' → '%@'", oldCanonical, exactCased)
        return true
    }

    /// Extract a variant out of an existing alias into its OWN new
    /// ProjectAlias row. Used when an LLM-hallucination variant got merged
    /// into a real cluster (or vice versa) and the user wants them separate.
    /// - Returns: `true` on success, `false` if not found / nothing to split.
    @discardableResult
    func splitAlias(currentCanonical: String, variantToSplit: String) -> Bool {
        guard let ctx = ctx() else { return false }
        guard let alias = aliasRow(named: currentCanonical, ctx: ctx) else {
            NSLog("[ProjectAggregator] splitAlias: '%@' not found", currentCanonical)
            return false
        }
        // Refuse to remove the LAST variant (would leave alias with no aliases).
        guard alias.aliases.count >= 2 else {
            NSLog("[ProjectAggregator] splitAlias: '%@' is the only variant — refusing", variantToSplit)
            return false
        }
        // Variant must exist in the aliases list.
        guard let exactCased = alias.aliases.first(where: { $0.localizedCaseInsensitiveCompare(variantToSplit) == .orderedSame }) else {
            NSLog("[ProjectAggregator] splitAlias: '%@' not in aliases of '%@'", variantToSplit, currentCanonical)
            return false
        }
        // If the variant being split IS the current canonical, pick another
        // variant as the surviving canonical first.
        if alias.canonicalName.localizedCaseInsensitiveCompare(exactCased) == .orderedSame {
            let nextCanonical = alias.aliases.first { $0.localizedCaseInsensitiveCompare(exactCased) != .orderedSame } ?? alias.canonicalName
            alias.canonicalName = nextCanonical
        }
        // Remove from current alias.
        var arr = alias.aliases.filter { $0.localizedCaseInsensitiveCompare(exactCased) != .orderedSame }
        if arr.isEmpty { arr = [alias.canonicalName] }  // safety
        alias.aliasesJSON = (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? alias.aliasesJSON
        alias.updatedAt = Date()
        // Insert new standalone alias row for the split variant.
        let new = ProjectAlias(canonicalName: exactCased)
        ctx.insert(new)
        try? ctx.save()
        NSLog("[ProjectAggregator] splitAlias: '%@' extracted from '%@' as new alias", exactCased, currentCanonical)
        return true
    }

    /// Take a raw project name (from `Conversation.primaryProject`), find or create
    /// its canonical alias. Always returns a canonical name.
    /// Side effect: inserts a new `ProjectAlias` row if no match, OR adds the
    /// new variant to an existing alias's `aliases` list when ITER-032
    /// `ProjectClusterDecision.canMerge` says they're the same project.
    @discardableResult
    func resolveCanonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ctx = ctx() else { return trimmed }

        let allDesc = FetchDescriptor<ProjectAlias>()
        let existing = (try? ctx.fetch(allDesc)) ?? []

        // Phase A — fast path: exact (case-insensitive) match against any
        // already-stored variant. Avoids canonical recomputation when the
        // LLM just gave us back a string we already saw.
        for alias in existing {
            if alias.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                return alias.canonicalName
            }
        }

        // Phase B — ITER-032: try to merge into an existing alias before
        // inserting a new row. `canMerge` handles transliteration, case,
        // emoji, punctuation, and Levenshtein-≤-2 typo tolerance with
        // length + digit-token guards. The first existing alias with ANY
        // variant that canMerges absorbs the new variant.
        for alias in existing {
            if alias.aliases.contains(where: { ProjectClusterDecision.canMerge($0, trimmed) }) {
                alias.addAlias(trimmed)
                alias.updatedAt = Date()
                try? ctx.save()
                NSLog("[ProjectAggregator] dedup: '%@' → '%@'", trimmed, alias.canonicalName)
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
        // ITER-050 B1.1 — never start a pass that wipes fields we may not be
        // able to regenerate: a license hiccup mid-pass once stripped 196
        // conversations of their titles/overviews.
        guard structuredGenerator.hasLLMAccess else {
            NSLog("[ProjectAggregator] backfill: no LLM access — skipping")
            return
        }
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
            // Snapshot first (ITER-050 B1.1) — if generate() fails (access
            // dropped mid-pass, proxy error), restore instead of leaving the
            // conversation stripped.
            let oldTitle = conv.title
            let oldOverview = conv.overview
            let oldCategory = conv.category
            let oldEmoji = conv.emoji
            // Reset the structured fields so generate() takes the full LLM path
            // (it short-circuits when title+overview are present).
            conv.title = nil
            conv.overview = nil
            conv.category = nil
            conv.emoji = nil
            try? ctx.save()
            let convId = conv.id
            await structuredGenerator.generate(conversationId: convId)
            // Review fix — generate() writes through its OWN ModelContext;
            // this loop's `conv` can be stale. Decide success and restore
            // through a fresh context so we see what actually landed.
            if let freshCtx = self.ctx(),
               let fresh = try? freshCtx.fetch(FetchDescriptor<Conversation>(
                   predicate: #Predicate { $0.id == convId })).first {
                if fresh.title == nil {
                    fresh.title = oldTitle
                    fresh.overview = oldOverview
                    fresh.category = oldCategory
                    fresh.emoji = oldEmoji
                    try? freshCtx.save()
                    NSLog("[ProjectAggregator] backfill: generate failed — restored fields for %@", "\(convId)")
                } else if let raw = fresh.primaryProject {
                    // After each generate, also run resolveCanonical to seed ProjectAlias.
                    _ = resolveCanonical(raw)
                }
            }
            done += 1
            // Tiny pause so we don't hammer the proxy.
            try? await Task.sleep(for: .milliseconds(300))
        }
        lastBackfillCount = done
        NSLog("[ProjectAggregator] backfill done: %d conversations classified", done)
    }

    /// Periodic merge pass — runs at app startup (one-shot to clean legacy
    /// duplicates created before ITER-032) and on a schedule.
    ///
    /// Two-stage:
    /// 1. **Deterministic pass** (ITER-032): for every pair of existing
    ///    aliases, run `ProjectClusterDecision.canMerge` on every cross-
    ///    variant pair. If any cross-variant pair merges, absorb smaller
    ///    cluster into larger. Catches all the Голосок/VoiceSnack,
    ///    Island Expand/Expend, ChatApp/🚀ChatApp duplicates that already
    ///    exist in the DB from before the pre-creation hook was added.
    /// 2. **Embedding pass**: compute centroid per ProjectAlias from its
    ///    conversations' embeddings, then collapse pairs with cosine ≥
    ///    `mergeThreshold`. Catches semantic duplicates that don't share
    ///    surface form (`Acme Mail` vs `AcmeEmail Project`).
    ///
    /// Merge rule: smaller cluster (fewer aliases) merges INTO larger;
    /// larger keeps its canonical name. Ties broken by older `createdAt`.
    func mergeAliases() async {
        guard let ctx = ctx() else { return }
        let allDesc = FetchDescriptor<ProjectAlias>()
        var aliases = (try? ctx.fetch(allDesc)) ?? []
        guard aliases.count >= 2 else { return }

        // STAGE 1 — Deterministic canonical+Lev pass (ITER-032).
        var deterministicMerges = 0
        var killed = Set<UUID>()
        for i in 0..<aliases.count {
            let a = aliases[i]
            if killed.contains(a.id) { continue }
            for j in (i + 1)..<aliases.count {
                let b = aliases[j]
                if killed.contains(b.id) { continue }
                // Match if ANY pair of variants across the two aliases canMerge.
                let crossMatch = a.aliases.contains { variantA in
                    b.aliases.contains { ProjectClusterDecision.canMerge(variantA, $0) }
                }
                if crossMatch {
                    let (winner, loser) = a.aliases.count >= b.aliases.count ? (a, b) : (b, a)
                    for v in loser.aliases { winner.addAlias(v) }
                    winner.updatedAt = Date()
                    killed.insert(loser.id)
                    ctx.delete(loser)
                    deterministicMerges += 1
                    NSLog("[ProjectAggregator] deterministic merge: '%@' ← '%@'",
                          winner.canonicalName, loser.canonicalName)
                }
            }
        }
        try? ctx.save()
        if deterministicMerges > 0 {
            // Refetch — deletions invalidated some pointers above.
            aliases = (try? ctx.fetch(allDesc)) ?? []
        }
        guard aliases.count >= 2 else {
            lastMergeCount = deterministicMerges
            return
        }

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
        // ITER-032: total merge count = deterministic pass (Stage 1) + embedding pass (Stage 2).
        lastMergeCount = deterministicMerges + merges
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
