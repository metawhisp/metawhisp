import Foundation
import SwiftData

/// Aggregates `Conversation.primaryProject` raw strings into canonical Project clusters
/// via `ProjectAlias`, then surfaces summaries + details for the Projects view + MetaChat.
///
/// Two paths feed canonicalization:
/// 1. **Cheap path** (`existingCanonical`) — case-insensitive exact match against any
///    alias of an existing `ProjectAlias`. Hit → reuse canonical. Miss → no project (T4: calls and
///    dictations never create one; agents and the user do, through TrackerService).
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
    /// FEAT-0006 — `Tracker.store`. A project in it (`TrackedProject`) is real: never pruned, merged away or
    /// renamed by the automatic passes below, always listed (I6).
    private var trackerContainer: ModelContainer?
    /// The app runs with a tracker; when its store failed to open, the passes that delete, merge or rename
    /// projects stop rather than treat every agent's project as automatic (review P2-5: fail closed).
    private var trackerRequired = false
    private var trackerMissing: Bool { trackerRequired && trackerContainer == nil }
    /// Cosine threshold for merging two project centroids. 0.88 calibrated to
    /// catch "ChatApp" vs "ChatAppAI" while not collapsing "ChatApp" vs "Overmind".
    /// Same family of thresholds as `EmbeddingService.dedupThreshold` (0.92) but
    /// looser because project names are short and contextual variation is wider.
    private let mergeThreshold: Float = 0.88

    func configure(modelContainer: ModelContainer, trackerContainer: ModelContainer? = nil,
                   trackerRequired: Bool = false) {
        self.modelContainer = modelContainer
        self.trackerContainer = trackerContainer
        self.trackerRequired = trackerRequired
        if trackerMissing { NSLog("[ProjectAggregator] no tracker store — prune, merge and renaming are off") }
    }

    /// FEAT-0006 §5.4 — ids of the projects agents or the user made real.
    func trackedProjectIds() -> Set<UUID> {
        guard let trackerContainer else { return [] }
        let rows = (try? ModelContext(trackerContainer).fetch(FetchDescriptor<TrackedProject>())) ?? []
        return Set(rows.map(\.projectId))
    }

    /// Projects the prune and recanonicalize passes never delete or rename: the ones agents or the user made real, and
    /// the ones the user put away — an archived project must still be there, as it was, to restore (Codex review
    /// P2-5). The merge pass skips archived projects altogether (`mergeAliases`).
    func protectedProjectIds() -> Set<UUID> {
        trackedProjectIds().union(archivedProjectIds())
    }

    /// FEAT-0006 §5.4 — which of two similar projects absorbs the other. A tracked project always survives; two
    /// tracked projects are never merged; otherwise the bigger (more aliases) wins, as before.
    static func mergeWinner(_ a: ProjectAlias, _ b: ProjectAlias,
                            tracked: Set<UUID>) -> (winner: ProjectAlias, loser: ProjectAlias)? {
        let ta = tracked.contains(a.id), tb = tracked.contains(b.id)
        if ta && tb { return nil }
        if ta { return (a, b) }
        if tb { return (b, a) }
        return a.aliases.count >= b.aliases.count ? (a, b) : (b, a)
    }

    // MARK: - Public API used by Projects view + MetaChat + backfill

    /// All known project clusters with up-to-date counts of linked items.
    /// Returns sorted by lastActivity desc (most recently touched on top).
    ///
    /// ITER-032: by default hides projects with `conversationCount < 2` to
    /// keep the Projects view free of singleton noise (LLM-hallucinated
    /// one-off names). Pass `includeSingletons: true` to disable the gate
    /// (Settings → "Show all projects" toggle).
    /// Owner 2026-11-27 (Q4) — projects the user put away.
    func archivedProjectIds() -> Set<UUID> {
        guard let trackerContainer else { return [] }
        return Set(((try? ModelContext(trackerContainer).fetch(FetchDescriptor<ArchivedProject>())) ?? []).map(\.projectId))
    }

    /// `archived`: the projects the user put away instead of the others (the "Archived · N" card, Q4).
    func listProjects(includeSingletons: Bool = false, archived: Bool = false) -> [ProjectSummary] {
        guard let ctx = ctx() else { return [] }
        let putAway = archivedProjectIds()

        // 1. Pull all aliases. Empty → no projects yet.
        let aliasDesc = FetchDescriptor<ProjectAlias>(
            sortBy: [SortDescriptor(\.canonicalName, order: .forward)]
        )
        let allAliases = (try? ctx.fetch(aliasDesc)) ?? []
        guard !allAliases.isEmpty else { return [] }

        // 2. Raw name → project, the same index the board reads (FEAT-0006 §9b).
        let rawToCanonical = TaskProjects.nameIndex(allAliases).mapValues(\.canonicalName)

        // 3. Pull all completed conversations with a project tag. We do counts in-memory
        //    rather than per-canonical fetches because predicate-side OR-of-aliases is
        //    awkward in SwiftData.
        // Only the fields the counts need (2026-11-26, Workspace load): a conversation row carries embeddings and
        // long JSON the list never reads.
        var convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        )
        convDesc.propertiesToFetch = [\.id, \.primaryProject, \.startedAt]
        let allConvs = (try? ctx.fetch(convDesc)) ?? []

        // 4. Aggregate per-canonical.
        var bucket: [String: BucketState] = [:]
        // Conversation → its project, looked up once per task and memory instead of a scan of every conversation.
        var canonicalByConv: [UUID: String] = [:]
        for conv in allConvs {
            guard let raw = conv.primaryProject?.lowercased(),
                  let canonical = rawToCanonical[raw] else { continue }
            canonicalByConv[conv.id] = canonical
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

        // 5. Tasks by the one rule the board shows them by (FEAT-0006 §9b): the record's project, else the
        //    conversation's. Memories through the conversations collected above.
        let nameOfProject = Dictionary(allAliases.map { ($0.id, $0.canonicalName) }, uniquingKeysWith: { a, _ in a })
        let projectOfTask = TaskProjects.map(main: ctx, tracker: trackerContainer.map(ModelContext.init))
        if !projectOfTask.isEmpty {
            var taskDesc = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { !$0.isDismissed })
            taskDesc.propertiesToFetch = [\.id, \.completed, \.status, \.assignee]
            for t in (try? ctx.fetch(taskDesc)) ?? [] {
                guard let pid = projectOfTask[t.id], let canonical = nameOfProject[pid] else { continue }
                var state = bucket[canonical] ?? BucketState()
                state.taskIds.insert(t.id)
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
        }
        if !bucket.isEmpty {
            var memDesc = FetchDescriptor<UserMemory>(
                predicate: #Predicate<UserMemory> {
                    !$0.isDismissed && $0.conversationId != nil
                }
            )
            memDesc.propertiesToFetch = [\.conversationId]
            for m in (try? ctx.fetch(memDesc)) ?? [] {
                guard let cid = m.conversationId, let canonical = canonicalByConv[cid],
                      var state = bucket[canonical] else { continue }
                state.memoryCount += 1
                bucket[canonical] = state
            }
        }

        // FEAT-0006 §5.4 — tracked projects are listed whatever their conversation count, with their tracker tasks.
        let tracked = trackedProjectIds()
        var trackedNames = Set<String>()
        if !tracked.isEmpty, let trackerContainer {
            let trackedRows = (try? ModelContext(trackerContainer).fetch(FetchDescriptor<TrackedProject>())) ?? []
            for alias in allAliases where tracked.contains(alias.id) {
                trackedNames.insert(alias.canonicalName)
                var state = bucket[alias.canonicalName] ?? BucketState()
                let since = trackedRows.first { $0.projectId == alias.id }?.updatedAt ?? alias.updatedAt
                state.lastActivity = max(state.lastActivity ?? since, since)
                bucket[alias.canonicalName] = state
            }
        }

        // Every project the user has is listed (the "+ add project" menu offers exactly these), a project with no
        // conversation left included (review 2026-11-27, #8).
        if includeSingletons {
            for alias in allAliases where bucket[alias.canonicalName] == nil {
                var state = BucketState()
                state.lastActivity = alias.updatedAt
                bucket[alias.canonicalName] = state
            }
        }

        // 6. Materialize ProjectSummary in last-activity order.
        // ITER-032 display threshold — projects with only 1 conversation
        // are noise (typos, LLM hallucinations, one-off mentions). Filter
        // unless caller explicitly asked to include singletons.
        let idOf = Dictionary(allAliases.map { ($0.canonicalName, $0.id) }, uniquingKeysWith: { a, _ in a })
        return bucket
            .compactMap { (canonical, state) -> ProjectSummary? in
                guard let last = state.lastActivity else { return nil }
                if putAway.contains(idOf[canonical] ?? UUID()) != archived { return nil }
                if !includeSingletons && state.conversationCount < 2 && !trackedNames.contains(canonical) { return nil }
                return ProjectSummary(
                    canonicalName: canonical,
                    projectId: allAliases.first { $0.canonicalName == canonical }?.id,
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
        // A conversation is this project's when the shared name index points its project name here (§9b).
        let index = TaskProjects.nameIndex((try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? [])
        let aliasesLower = Set(index.filter { $0.value.id == alias.id }.map(\.key))

        // Pull completed conversations whose primaryProject matches any alias.
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let convs = ((try? ctx.fetch(convDesc)) ?? [])
            .filter { aliasesLower.contains(($0.primaryProject ?? "").lowercased()) }
        let convIds = Set(convs.map { $0.id })

        // FEAT-0006 §9b — the project's tasks by the one rule the board shows them by.
        let projectOfTask = TaskProjects.map(main: ctx, tracker: trackerContainer.map(ModelContext.init))
        let ids = projectOfTask.filter { $0.value == alias.id }.map(\.key)
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && ids.contains($0.id) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let tasks = ((try? ctx.fetch(taskDesc)) ?? []).filter { $0.effectiveStatus != "dismissed" }

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
    func deleteProject(canonicalName: String,
                       ledgerURL: URL = ProjectBackfillLedger.fileURL(in: AppIdentity.current.supportDirectory)) -> Int {
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
        var unlinkedIDs: [UUID] = []
        for c in convs {
            let raw = (c.primaryProject ?? "").lowercased()
            if aliasesLower.contains(raw) {
                c.primaryProject = nil
                c.updatedAt = Date()
                unlinked += 1
                unlinkedIDs.append(c.id)
            }
        }
        // ITER-075 step 1 (1.6) — the owner took these conversations' project
        // away; the project backfill must not give it back.
        var ledger = ProjectBackfillLedger(fileURL: ledgerURL)
        do {
            try ledger.mark(unlinkedIDs)
        } catch {
            NSLog("[ProjectAggregator] deleteProject: the checked list was not saved — %@", error.localizedDescription)
        }

        // FEAT-0006 §5.4 — the project is no longer tracked; its tracker tasks stay, with no project and no key.
        if let trackerContainer {
            let tctx = ModelContext(trackerContainer)
            let pid: UUID? = alias.id
            for t in (try? tctx.fetch(FetchDescriptor<TrackedProject>())) ?? [] where t.projectId == alias.id {
                tctx.delete(t)
            }
            for r in (try? tctx.fetch(FetchDescriptor<TaskTrackerRecord>(predicate: #Predicate { $0.projectId == pid }))) ?? [] {
                r.projectId = nil
                r.key = nil
                r.parentTaskId = nil
                r.updatedAt = Date()
            }
            try? tctx.save()
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
    /// The name a project goes by now, from its id: a project's page follows the project, not a name that a rename or
    /// a split moved to another row (review 2026-11-27, #2).
    func canonicalName(of projectId: UUID) -> String? {
        guard let ctx = ctx() else { return nil }
        var d = FetchDescriptor<ProjectAlias>(predicate: #Predicate { $0.id == projectId })
        d.fetchLimit = 1
        return (try? ctx.fetch(d))?.first?.canonicalName
    }

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
        // Without LLM access a pass would change nothing.
        // The pass runs on the cloud path only.
        guard generator.hasCloudLLMAccess else {
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
            let convId = conv.id
            // ITER-075 step 1 (1.6) — nothing is cleared first: the full path
            // is asked for outright, and the old fields stand until a result
            // replaces them (a quit between clearing and restoring left a
            // conversation blank for good).
            // The generator writes only an existing project (T4); nothing to seed here.
            await generator.generate(conversationId: convId, preferCloud: true, isRegeneration: true)
            done += 1
            try? await Task.sleep(for: .milliseconds(300))
        }
        return done
    }

    /// For every ProjectAlias, compute conversation counts per variant and
    /// promote the highest-count variant to canonical. Deterministic
    /// alphabetical tie-break. Skips aliases with only 1 variant (already
    /// canonical-as-only-variant).
    func recanonicalizeAll() -> Int {
        guard !trackerMissing, let ctx = ctx() else { return 0 }
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
        let tracked = protectedProjectIds()
        // FEAT-0006 §5.4 — a tracked project's name is the user's or its folder's; only the user renames it.
        for alias in allAliases where alias.aliases.count >= 2 && !tracked.contains(alias.id) {
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
    func pruneOrphanAliases() -> Int {
        guard !trackerMissing, let ctx = ctx() else { return 0 }
        let allAliases = (try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []
        guard !allAliases.isEmpty else { return 0 }
        let convs = (try? ctx.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.primaryProject != nil }
        ))) ?? []
        let referencedLowercased = Set(convs.compactMap { $0.primaryProject?.lowercased() })
        var deleted = 0
        let tracked = protectedProjectIds()
        // FEAT-0006 §5.4 — an agent's project usually has no conversations; it is real anyway.
        for alias in allAliases where !tracked.contains(alias.id) {
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
        // Not to a name another project goes by: two projects of one name would show as one card (review #9).
        let others = ((try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []).filter { $0.id != alias.id }
        if others.contains(where: { o in o.aliases.contains { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
                                      || o.canonicalName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            NSLog("[ProjectAggregator] renameCanonical: '%@' is another project's name — refused", trimmed)
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

    /// T4 (owner 2026-11-25; cause fixed 2026-11-26): the user's project a name from a call or a dictation points
    /// to, or nil. Never creates a project — only an agent or the user makes one (TrackerService). A spelling of an
    /// existing project (`ProjectClusterDecision.canMerge`) joins it as a variant.
    func existingCanonical(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null", let ctx = ctx() else { return nil }
        // A project the user put away gets no new conversations (Q4).
        let putAway = archivedProjectIds()
        let existing = ((try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []).filter { !putAway.contains($0.id) }
        // Exact (case-insensitive) match against any stored variant.
        if let hit = existing.first(where: { a in
            a.aliases.contains { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        }) {
            return hit.canonicalName
        }
        // A spelling of an existing project (transliteration, case, emoji, punctuation).
        for alias in existing where alias.aliases.contains(where: { ProjectClusterDecision.canMerge($0, trimmed) }) {
            alias.addAlias(trimmed)
            alias.updatedAt = Date()
            try? ctx.save()
            NSLog("[ProjectAggregator] dedup: '%@' → '%@'", trimmed, alias.canonicalName)
            return alias.canonicalName
        }
        return nil
    }

    /// The project a conversation is written with after its summary step: `proposed` (the model's name, already
    /// looked up by `existingCanonical`, so an active project or none, T4) — unless the conversation is in a project
    /// the user archived. That project gets no new conversations and loses none of its own (Q4): a regeneration
    /// used to write the lookup's nil over it, and its tasks left the project with it (Codex review P2-9).
    func projectAfterGeneration(proposed: String?, current: String?) -> String? {
        guard let current, let ctx = ctx() else { return proposed }
        let putAway = archivedProjectIds()
        guard !putAway.isEmpty else { return proposed }
        let projects = (try? ctx.fetch(FetchDescriptor<ProjectAlias>())) ?? []
        guard let hit = TaskProjects.nameIndex(projects)[current.lowercased()], putAway.contains(hit.id) else {
            return proposed
        }
        return current
    }

    /// When PROJECT joined the structuring prompt (ITER-014, 2026-04-25). A
    /// conversation from after it already had the question asked: an empty
    /// project there is the LLM's answer, not a gap. ITER-075 step 1 (1.6).
    static let projectQuestionShipped = Date(timeIntervalSince1970: 1_777_075_200)   // 2026-04-25 00:00 UTC

    /// Re-run StructuredGenerator for completed conversations missing `primaryProject`
    /// (rows finalized before ITER-014 ship). Skips placeholder titles — those are handled
    /// by `StructuredGenerator.backfillPlaceholders()` independently. Runs on the
    /// cloud path only, so it starts only with cloud access.
    func backfillProjects(structuredGenerator: StructuredGenerator) async {
        await backfillProjects(
            hasLLMAccess: structuredGenerator.hasCloudLLMAccess,
            ledgerURL: ProjectBackfillLedger.fileURL(in: AppIdentity.current.supportDirectory)
        ) { convId in
            // Backfill stays on the cloud path, like the other backfills.
            await structuredGenerator.generate(conversationId: convId, preferCloud: true, isRegeneration: true)
        }
    }

    /// The pass itself, with the run and the checked list passed in.
    func backfillProjects(hasLLMAccess: Bool, ledgerURL: URL, limit: Int = 200,
                          pause: Duration = .milliseconds(300),
                          generate: (UUID) async -> StructuredOutcome) async {
        guard let ctx = ctx() else { return }
        // Without LLM access a pass would change nothing.
        guard hasLLMAccess else {
            NSLog("[ProjectAggregator] backfill: no LLM access — skipping")
            return
        }
        // ITER-075 step 1 (1.6) — conversations already checked are skipped;
        // every launch used to send the same 200 to the LLM (a 5.5-minute pass).
        var ledger = ProjectBackfillLedger(fileURL: ledgerURL)
        let shipped = Self.projectQuestionShipped
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                !$0.discarded
                && $0.status == "completed"
                && $0.primaryProject == nil
                && $0.title != nil
                && $0.title != "Quick note"
                && $0.startedAt < shipped
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let needs = ProjectBackfillLedger.pending((try? ctx.fetch(desc)) ?? [], id: \.id,
                                                  checked: ledger.checked, limit: limit)
        guard !needs.isEmpty else {
            NSLog("[ProjectAggregator] backfill: nothing to do")
            return
        }
        NSLog("[ProjectAggregator] backfill: %d conversations need project tag", needs.count)

        var classified = 0
        for conv in needs {
            let convId = conv.id
            // ITER-075 step 1 (1.6) — nothing is cleared first. The full path
            // is asked for outright, and the old title, overview, category and
            // emoji stand until a result replaces them. They used to be cleared
            // and saved first and put back after the run; a quit in between
            // left the conversation blank for good (2026-09-22).
            let outcome = await generate(convId)
            do {
                try ledger.record(convId, outcome: outcome)
            } catch {
                NSLog("[ProjectAggregator] backfill: the checked list was not saved — %@", error.localizedDescription)
            }
            if outcome == .written { classified += 1 }
            // Tiny pause so we don't hammer the proxy.
            try? await Task.sleep(for: pause)
        }
        lastBackfillCount = classified
        NSLog("[ProjectAggregator] backfill done: %d of %d conversations classified", classified, needs.count)
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
        guard !trackerMissing, let ctx = ctx() else { return }
        let allDesc = FetchDescriptor<ProjectAlias>()
        // An archived project is put away as it is: it neither absorbs nor is merged into another, so it is there to
        // restore with what it had (Codex review P2-5).
        let archived = archivedProjectIds()
        func mergeable() -> [ProjectAlias] { ((try? ctx.fetch(allDesc)) ?? []).filter { !archived.contains($0.id) } }
        var aliases = mergeable()
        guard aliases.count >= 2 else { return }
        NSLog("[ProjectAggregator] merge pass start — %d aliases", aliases.count)

        let tracked = trackedProjectIds()
        // STAGE 1 — Deterministic canonical+Lev pass (ITER-032).
        var deterministicMerges = 0
        var killed = Set<UUID>()
        for i in 0..<aliases.count {
            let a = aliases[i]
            if killed.contains(a.id) { continue }
            for j in (i + 1)..<aliases.count {
                // A row that was merged away absorbs nothing more (it can lose to a tracked row).
                if killed.contains(a.id) { break }
                let b = aliases[j]
                if killed.contains(b.id) { continue }
                // Match if ANY pair of variants across the two aliases canMerge.
                let crossMatch = a.aliases.contains { variantA in
                    b.aliases.contains { ProjectClusterDecision.canMerge(variantA, $0) }
                }
                if crossMatch, let pair = Self.mergeWinner(a, b, tracked: tracked) {
                    let (winner, loser) = pair
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
            aliases = mergeable()
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
        aliases = mergeable()
        var merges = 0
        var dead = Set<UUID>()
        let withCentroid = aliases.filter { $0.centroidEmbedding != nil }
        for i in 0..<withCentroid.count {
            let a = withCentroid[i]
            if dead.contains(a.id) { continue }
            for j in (i + 1)..<withCentroid.count {
                if dead.contains(a.id) { break }
                let b = withCentroid[j]
                if dead.contains(b.id) { continue }
                guard let aData = a.centroidEmbedding, let bData = b.centroidEmbedding else { continue }
                let aVec = EmbeddingService.decode(aData)
                let bVec = EmbeddingService.decode(bData)
                let sim = EmbeddingService.cosineSimilarity(aVec, bVec)
                guard sim >= mergeThreshold else { continue }
                // Merge smaller into larger; a tracked project always survives (FEAT-0006 §5.4).
                guard let pair = Self.mergeWinner(a, b, tracked: tracked) else { continue }
                let (winner, loser) = pair
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
        NSLog("[ProjectAggregator] merge pass done — deterministic=%d embedding=%d, %d aliases with centroid", deterministicMerges, merges, withCentroid.count)
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
        /// Tasks counted already (a tracker task of a call is counted once).
        var taskIds: Set<UUID> = []
    }
}

// MARK: - DTOs

struct ProjectSummary: Identifiable {
    let canonicalName: String
    /// `ProjectAlias.id` — what a project's Tasks page filters by.
    let projectId: UUID?
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
