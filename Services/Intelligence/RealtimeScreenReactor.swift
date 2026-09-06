import Foundation
import SwiftData

/// Real-time per-window task detector. Fires on each newly-persisted `ScreenContext`
/// (from `ScreenContextService.onContextPersisted`) and does a short LLM classification:
/// "Is there a concrete actionable task visible on this screen?"
///
/// Copies reference `ProactiveAssistantsPlugin.swift:65-71` + `TaskAssistant.swift` pattern:
/// change-gated distribution + per-app 60s debounce + short single-window prompt.
///
/// We start with JUST the Task assistant. Focus/Insight/Memory assistants are separate tracks.
///
/// spec://iterations/ITER-006-realtime-screen-reaction
@MainActor
final class RealtimeScreenReactor: ObservableObject {
    /// ITER-041 — actionable-task extraction from screen OCR on medium
    /// tier. Phase C will prepend a mini gate to filter "no action" frames.
    static let llmTier: LLMTier = .medium
    static let llmServiceId: String = "RealtimeScreenReactor"

    @Published var isProcessing = false
    @Published var lastFireAt: Date?
    @Published var lastError: String?

    private let llm = OpenAIService()
    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    /// Per-app cooldown (seconds). Matches reference `ProactiveAssistantsPlugin` change-gate.
    private let perAppCooldown: TimeInterval = 60
    /// Global rate limit — max LLM calls per hour. Prevents runaway cost on rapid window-hopping.
    private let maxCallsPerHour = 30
    /// OCR length threshold — skip nearly-empty screens (login / blank tabs).
    private let minOCRChars = 100

    /// Last LLM-call timestamp per app (for 60s per-app debounce).
    private var lastCallPerApp: [String: Date] = [:]
    /// Rolling window of call timestamps — sliding 1h for rate limit.
    private var callTimestamps: [Date] = []
    /// ITER-057.5 — whitelist drops are logged once per app per launch (a per-
    /// snapshot log would spam every 30s; total silence hid the Telegram drop).
    private var loggedGatedApps: Set<String> = []

    /// Apps we never process for realtime task-reaction — privacy-sensitive or
    /// structurally uninformative. `TaskExtractionFilters.isTaskAllowed` (the
    /// ITER-057.5 whitelist) is the positive gate on top of this privacy set.
    private let privacyBlacklist: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "1Password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "loginwindow",
    ]

    /// Dependency used to suppress reactor during active meeting recording — avoid LLM
    /// noise + cost when the user is in a call being transcribed.
    weak var meetingRecorder: MeetingRecorder?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// ITER-053.1 — purge fence, same pattern as ScreenExtractor. «Delete
    /// screen history» bumps the epoch; an in-flight reaction that started
    /// before the bump discards its result instead of inserting a staged task
    /// that points at a just-deleted ScreenContext.
    private var purgeEpoch = 0
    func invalidatePendingWork() {
        purgeEpoch += 1
    }

    /// Entry point — called by `ScreenContextService.onContextPersisted` for each new row.
    /// Self-gated: runs all cheap checks first, only fires LLM when everything passes.
    func react(to context: ScreenContext) async {
        guard shouldProcess(context) else { return }
        guard !isProcessing else { return }  // serialize; one pending call at a time

        isProcessing = true
        defer { isProcessing = false }
        // ITER-053.1 purge fence — snapshot before any await.
        let epoch = purgeEpoch

        // Record call in sliding window BEFORE the LLM call so rapid concurrent triggers
        // still respect the cap. Trim old entries first.
        pruneRateWindow()
        guard callTimestamps.count < maxCallsPerHour else {
            NSLog("[RealtimeReactor] Rate limit: %d calls in last hour — skipping", callTimestamps.count)
            return
        }
        callTimestamps.append(Date())
        lastCallPerApp[context.appName] = Date()

        // ITER-057.5 — fulfillment rides along in the same LLM call: open tasks
        // lexically related to this OCR are listed in the prompt; the model
        // reports which ones the screen shows as already done by the user.
        let fulfillmentRefs = fulfillmentCandidates(ocr: context.ocrText)
        // Recently dismissed tasks are negative examples («не извлекай похожие») —
        // reference injects user-deleted tasks into every extraction prompt.
        let rejectedExamples = recentDismissedDescriptions(limit: 10)
        NSLog("[RealtimeReactor] reacting in %@: %d chars OCR, %d open-task refs, %d rejected examples, %d calls this hour", context.appName, context.ocrText.count, fulfillmentRefs.count, rejectedExamples.count, callTimestamps.count)

        let prompt = buildPrompt(
            appName: context.appName,
            windowTitle: context.windowTitle,
            ocr: context.ocrText,
            openTasks: fulfillmentRefs,
            rejectedExamples: rejectedExamples
        )

        do {
            let response: String
            // ITER-039 — local LLM takes priority when loaded.
            if LocalLLMService.shared.isReady {
                // 512 tokens: the response now carries a "fulfilled" array on top
                // of the task JSON — 256 truncated it (review finding).
                // maxUserChars 4000: the default 2000 equals the OCR cap alone,
                // so the OPEN TASKS / USER-REJECTED sections appended AFTER the
                // OCR were silently truncated away — fulfillment dead on the
                // local path (review finding P1).
                response = try await LocalLLMService.shared.completeBlocking(
                    system: Self.systemPrompt, user: prompt,
                    maxUserChars: 4000, maxTokens: 512
                )
            } else if LicenseService.shared.isPro, let key = LicenseService.shared.licenseKey {
                // ITER-041 Phase C — relevance gate. Skip the medium-tier
                // extraction when the cheap gate sees no action signal.
                // ITER-057.5 — bypassed when fulfillment candidates exist: the
                // gate is tuned for "new action?" and a screen proving a task was
                // DONE scores as no-action, silencing the check we need.
                if fulfillmentRefs.isEmpty {
                    let gate = await GateClient.call(
                        context: prompt,
                        purpose: .reactor,
                        recentTopics: [],
                        serviceId: Self.llmServiceId,
                        licenseKey: key
                    )
                    guard gate.shouldFire else {
                        NSLog("[RealtimeReactor] gate-skipped score=%.2f on %@ — %@",
                              gate.score, context.appName, String(gate.reasoning.prefix(80)))
                        // ITER-041 code-review fix: refund the rate-limit slot we
                        // reserved at the top. The cheap gate (mini tier) is NOT an
                        // expensive call — counting skips toward maxCallsPerHour
                        // would silence the reactor after 30 app-switches/hour even
                        // though almost nothing was spent. Only EXPENSIVE calls
                        // (the proxy/local LLM below) should consume the budget.
                        if !callTimestamps.isEmpty { callTimestamps.removeLast() }
                        return
                    }
                }
                response = try await callProProxy(system: Self.systemPrompt, user: prompt, licenseKey: key)
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

            guard let parsed = Self.parseReaction(response) else {
                NSLog("[RealtimeReactor] ⚠️ parse failed — response %d chars", response.count)
                return
            }

            // ITER-053.1 purge fence — the user deleted screen history while we
            // awaited the LLM. Covers BOTH the fulfillment apply and the staged
            // insert below (review finding: completing a task from evidence in
            // purged OCR breaks the «delete everything derived from it» promise).
            guard epoch == purgeEpoch else {
                NSLog("[RealtimeReactor] Reaction discarded — screen history was purged mid-run")
                return
            }

            // ITER-057.5 — fulfillment applies regardless of hasTask: a screen
            // can prove an old task done while offering no new task.
            applyFulfillment(parsed.fulfilled, sent: fulfillmentRefs, ocr: context.ocrText)
            NSLog("[RealtimeReactor] model answered in %.1fs: %d chars, hasTask=%d, relevance=%d, fulfilled claims=%d", Date().timeIntervalSince(lastCallPerApp[context.appName] ?? Date()), response.count, parsed.hasTask ? 1 : 0, parsed.relevance ?? -1, parsed.fulfilled?.count ?? 0)

            guard parsed.hasTask else {
                NSLog("[RealtimeReactor] No task on %@ — %@",
                      context.appName, String(context.windowTitle.prefix(50)))
                return
            }

            let trimmedDesc = parsed.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedDesc.isEmpty,
                  trimmedDesc.split(separator: " ").count <= 15
            else { return }

            // Relevance gate — LLM self-scored 0-100, must clear threshold.
            let relevance = parsed.relevance ?? 0
            guard relevance >= TaskExtractionFilters.minRelevanceScore else {
                NSLog("[RealtimeReactor] Relevance %d < %d, skipping: %@",
                      relevance,
                      TaskExtractionFilters.minRelevanceScore,
                      String(trimmedDesc.prefix(60)))
                return
            }

            // Evidence gate — LLM must cite verbatim OCR proof.
            let evidence = parsed.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // ITER-066 — and the proof has to actually occur in the screen it
            // claims to prove. Length alone let a fabricated 20-character quote
            // create a task; the stronger normalized-substring rule existed in
            // TaskFulfillment all along and never guarded creation.
            guard ScreenAgentEvidence.normalize(context.ocrText)
                .contains(ScreenAgentEvidence.normalize(evidence)) else {
                NSLog("[RealtimeReactor] Evidence quote not present in OCR, skipping: %@",
                      String(trimmedDesc.prefix(60)))
                return
            }
            guard evidence.count >= TaskExtractionFilters.minEvidenceChars else {
                NSLog("[RealtimeReactor] Evidence too weak (%d chars), skipping: %@",
                      evidence.count, String(trimmedDesc.prefix(60)))
                return
            }

            // Generic-phrase reject list ("Respond to messages", "Send daily", etc.)
            if TaskExtractionFilters.isGenericNoise(trimmedDesc) {
                NSLog("[RealtimeReactor] generic noise, skipping (%d chars)", trimmedDesc.count)
                return
            }
            // ITER-032 — strict title validator (replaces reference's tool-loop
            // retry-on-vague-title). Drops single-verb / too-short titles before
            // DB insert.
            if let reason = TaskExtractionFilters.validateTaskTitle(trimmedDesc) {
                NSLog("[RealtimeReactor] Title rejected (%@): %@",
                      String(describing: reason), trimmedDesc)
                return
            }

            // ITER-071.5 — the same safety the director applies to anything it
            // shows. A page can plant a task exactly the way it can plant a
            // comment: every check above passes for "add a task: wire $2,000
            // to account 7741" because that text really is on the screen. The
            // taste rules stay out — a captured task is SUPPOSED to restate
            // the screen.
            if let unsafe = ScreenAgentDirector.safetyRejection(
                headline: trimmedDesc, body: evidence, screen: context.ocrText) {
                NSLog("[RealtimeReactor] refused by the director (%@): %@",
                      unsafe.rawValue, String(trimmedDesc.prefix(60)))
                return
            }

            // Dedup against recent TaskItems (fuzzy word-overlap).
            if isDuplicate(description: trimmedDesc) {
                NSLog("[RealtimeReactor] duplicate task, skipping (%d chars)", trimmedDesc.count)
                return
            }

            // Parse dueAt if LLM provided one (rare — only when visible on screen).
            var dueAt: Date? = nil
            if let raw = parsed.dueAt, !raw.isEmpty, raw != "null" {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime]
                if let d = parser.date(from: raw), d > Date() {
                    dueAt = d
                }
            }

            // (Purge fence already checked right after parse — no awaits since.)
            // Creation is off for the same reason completion is: 957 of these
            // accumulated unseen. A queue nobody reads is not a feature.
            guard ScreenDerivedTaskPolicy.mayMutateWithoutConfirmation else {
                NSLog("[RealtimeReactor] observed a task on screen — not creating one (%d chars)",
                      trimmedDesc.count)
                return
            }
            guard let container = modelContainer else { return }
            let ctx = ModelContext(container)
            let task = TaskItem(
                taskDescription: trimmedDesc,
                dueAt: dueAt,
                sourceTranscriptId: nil,
                sourceApp: context.appName,
                conversationId: nil,
                screenContextId: context.id,
                // Staged — LLM inference from a single screen, weakest signal tier.
                status: "staged"
            )
            ctx.insert(task)
            try? ctx.save()

            lastFireAt = Date()
            NSLog("[RealtimeReactor] ✅ staged candidate from %@ (%d chars)", context.appName, trimmedDesc.count)

            // No notification for staged — they land in REVIEW CANDIDATES silently.
            // User sees them next time they open the Tasks tab and promotes ✓ / rejects ✗.

            // Fire-and-forget embedding for semantic RAG (ITER-008).
            AppDelegate.shared?.embeddingService.embedTasksInBackground([task], in: ctx)
        } catch {
            lastError = error.localizedDescription
            NSLog("[RealtimeReactor] ❌ LLM failed: %@", error.localizedDescription)
            // Remove the rate-limit entry we reserved, since the call didn't succeed.
            if !callTimestamps.isEmpty { callTimestamps.removeLast() }
        }
    }

    // MARK: - Gates

    private func shouldProcess(_ context: ScreenContext) -> Bool {
        guard settings.realtimeScreenReactionEnabled else { return false }
        guard hasLLMAccess else { return false }
        guard context.ocrText.count >= minOCRChars else { return false }
        if privacyBlacklist.contains(context.appName) { return false }
        // ITER-057.5 — whitelist gate: tasks live in conversations (messengers /
        // mail / work browser tabs). The old blacklist blocked Telegram — the
        // exact place the founder's commitments live — while letting SecurityAgent
        // dialogs produce junk. Logged once per app so a silent drop is debuggable.
        guard TaskExtractionFilters.isTaskAllowed(appName: context.appName,
                                                  windowTitle: context.windowTitle) else {
            if !loggedGatedApps.contains(context.appName) {
                loggedGatedApps.insert(context.appName)
                NSLog("[RealtimeReactor] App not on task whitelist, skipping (logged once/launch): %@",
                      context.appName)
            }
            return false
        }

        // Skip while user is in a meeting being recorded — LLM cost + notification noise during calls.
        if meetingRecorder?.isRecording == true || meetingRecorder?.isStarting == true {
            return false
        }

        // Per-app debounce — last LLM call for this app was < 60s ago, skip.
        if let last = lastCallPerApp[context.appName],
           Date().timeIntervalSince(last) < perAppCooldown {
            return false
        }
        return true
    }

    private func pruneRateWindow() {
        let cutoff = Date().addingTimeInterval(-3600)
        callTimestamps = callTimestamps.filter { $0 >= cutoff }
    }

    /// True if a near-duplicate TaskItem exists: any task from the last 24h,
    /// PLUS dismissed tasks from the last 30 days (ITER-057.5 — a task the user
    /// rejected must not resurrect from the same screen a day later; the 24h
    /// window alone let dismissed tasks come back, review finding).
    /// Uses word-overlap fuzzy match (threshold 0.6) so "Fix exampleproject SEO" and
    /// "Fix Example Project SEO issue" are recognized as the same task.
    private func isDuplicate(description: String) -> Bool {
        guard let container = modelContainer else { return false }
        let ctx = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-86400)
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.createdAt >= cutoff }
        )
        desc.fetchLimit = 200
        let recent = (try? ctx.fetch(desc)) ?? []
        var existingDescs = recent.map { $0.taskDescription }

        let dismissedCutoff = Date().addingTimeInterval(-30 * 86400)
        var dismissedDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> {
                ($0.isDismissed || $0.status == "dismissed") && $0.createdAt >= dismissedCutoff
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        dismissedDesc.fetchLimit = 100
        existingDescs += ((try? ctx.fetch(dismissedDesc)) ?? []).map { $0.taskDescription }

        return TaskExtractionFilters.isNearDuplicate(description, against: existingDescs)
    }

    // MARK: - Fulfillment (ITER-057.5)

    /// Open COMMITTED tasks — newest first — narrowed to the ones lexically
    /// related to this OCR. These ride along in the LLM prompt.
    ///
    /// Committed-only (review findings): staged candidates are unreviewed noise —
    /// including them made `fulfillmentRefs` non-empty on almost every messenger
    /// snapshot, permanently bypassing the mini gate. Status is checked in
    /// memory via `effectiveStatus` so legacy nil-status voice tasks are
    /// included (a `status != "dismissed"` predicate drops NULL rows in SQL).
    private func fulfillmentCandidates(ocr: String) -> [TaskFulfillment.OpenTaskRef] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        // Status narrowed in SQL (committed OR legacy nil = committed) so the
        // fetchLimit window isn't consumed by a large staged backlog evicting
        // week-old real commitments (review finding). `== nil` maps to IS NULL —
        // safe, unlike `!= "dismissed"` which drops NULL rows.
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> {
                !$0.completed && !$0.isDismissed && ($0.status == "committed" || $0.status == nil)
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        desc.fetchLimit = 200
        let open = (try? ctx.fetch(desc)) ?? []
        return TaskFulfillment.relatedTasks(
            ocr: ocr,
            tasks: open.map { .init(id: $0.id, description: $0.taskDescription) }
        )
    }

    /// Auto-complete tasks the LLM proved done on screen. Gated by
    /// `TaskFulfillment.confirmedIds`: ids must come from the sent list AND the
    /// evidence must be a verbatim (normalized) substring of the OCR — a
    /// hallucinated or prompt-echoed claim can't close anything.
    /// Internal rather than private so the mutation point itself is testable —
    /// the whole question of this slice is what it is allowed to do.
    func applyFulfillment(_ claims: [TaskFulfillment.FulfilledJSON]?,
                                  sent: [TaskFulfillment.OpenTaskRef],
                                  ocr: String) {
        let ids = TaskFulfillment.confirmedIds(claims, sent: sent, ocr: ocr)
        guard !ids.isEmpty else { return }
        // The observation stands; acting on it does not. Closing a task the
        // user wrote, because a phrase appeared on their screen, is a decision
        // they never made — and there is currently nowhere for the proposal to
        // go, so it is logged and dropped rather than applied.
        guard ScreenDerivedTaskPolicy.mayMutateWithoutConfirmation else {
            NSLog("[RealtimeReactor] observed %d task(s) claimed done — proposing nothing, mutating nothing",
                  ids.count)
            return
        }
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        // Re-fetch and re-validate: the LLM await took seconds — the user may
        // have dismissed/completed a task meanwhile (review finding).
        var tasks: [TaskItem] = []
        for id in ids {
            var desc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            desc.fetchLimit = 1
            guard let task = (try? ctx.fetch(desc))?.first,
                  !task.completed, !task.isDismissed, task.effectiveStatus != "dismissed"
            else { continue }
            tasks.append(task)
        }
        guard !tasks.isEmpty else { return }
        // Flip ALL fields before the first commit: commit saves the whole
        // context, and its .taskSaved hook synchronously runs a promotion pass —
        // which must not see task B still open while we're about to complete it
        // (review finding: mid-loop promote-then-complete double handling).
        let now = Date()
        for task in tasks {
            task.completed = true
            task.completedAt = now
            task.updatedAt = now
        }
        for task in tasks {
            do {
                try MutationService.shared.commit(.taskSaved(task.id), in: ctx)
                NSLog("[RealtimeReactor] ✅ Auto-completed fulfilled task: %@",
                      String(task.taskDescription.prefix(60)))
                announceCompletion(of: task)
            } catch {
                NSLog("[RealtimeReactor] ⚠️ Fulfillment save failed: %@", error.localizedDescription)
                break
            }
        }
    }

    /// ITER-066 follow-up (Codex live-safety finding) — completing a task from
    /// screen evidence used to be silent: the strong quote gate meant it was
    /// rarely wrong, and the silence meant that when it WAS wrong, nothing told
    /// the user their task list had changed. The mutation is now announced with
    /// a durable card, so it can be noticed and reversed in Workspace.
    ///
    /// runID is the task's own ID: a task completes once, and a duplicate
    /// announcement for the same completion is refused by the delivery layer.
    private func announceCompletion(of task: TaskItem) {
        guard let delivery = AppDelegate.shared?.screenAgentDelivery else { return }
        let item = ScreenAgentItem(
            runID: task.id,
            headline: "Marked done: \(String(task.taskDescription.prefix(80)))",
            body: "Seen completed on screen. If that's wrong, reopen it in Workspace.",
            sourceApp: "Workspace",
            sourceWindowTitle: "",
            capturedAt: Date()
        )
        guard let announced = delivery.announce(item) else { return }
        let itemID = announced.id
        let noteID = UUID()
        let note = MWNotification(
            id: noteID,
            kind: .task,
            title: "Task completed",
            body: String(task.taskDescription.prefix(100)),
            onTap: { @MainActor in
                AppDelegate.shared?.screenAgentDelivery?
                    .recordInteraction(.opened, itemID: itemID)
                AppDelegate.shared?.openScreenAgentInbox(selecting: itemID)
                MWNotificationStack.shared.dismiss(id: noteID, reason: .opened)
            },
            screenAgentItemID: itemID
        )
        MWNotificationStack.shared.push(note)
        // Only now has the user had a chance to see it — announce() keeps the
        // item pending precisely so a quit before this line cannot leave
        // history claiming a presentation that never happened.
        delivery.confirmPresented(itemID: itemID)
    }

        /// Last N dismissed tasks — injected into the prompt as negative examples
    /// (reference: user-deleted tasks are «do not re-extract similar»).
    private func recentDismissedDescriptions(limit: Int) -> [String] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.isDismissed || $0.status == "dismissed" },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        desc.fetchLimit = limit
        return ((try? ctx.fetch(desc)) ?? []).map { $0.taskDescription }
    }

    // MARK: - Prompt

    /// Strict single-window task classifier — detects USER COMMITMENTS (patt-1)
    /// + UNADDRESSED REQUESTS (patt-2). Requires the LLM to score relevance 0-100
    /// AND cite verbatim OCR evidence. Post-LLM filter rejects score <75 or evidence <20 chars.
    /// Re-aligned with reference TaskAssistant 2026-04-26 (ITER-028).
    static let systemPrompt = """
    You are a task commitment detector. Your ONLY job: find tasks the user has committed
    to in conversations, OR unaddressed requests directed at the user.

    Return a single JSON object:
    {
      "hasTask": true|false,
      "description": "imperative ≤12 words, verb first, no time refs",
      "dueAt": "ISO-8601 UTC with Z"|null,
      "relevance": 0-100,
      "evidence": "verbatim quote from OCR that proves this is a pending action for the user",
      "fulfilled": [{"id": "<uuid from OPEN TASKS>", "evidence": "verbatim OCR quote proving the user already did it"}]
    }
    "fulfilled" is [] unless the FULFILLMENT CHECK below finds hard proof.

    THE BAR IS HIGH. Default hasTask=false. Out of 20 windows, maybe 1 has a real task.
    False positives are worse than false negatives. Better to miss one marginal task
    than flood the user with garbage.

    ── WORKFLOW ──
    1. Read the OCR to understand window context.
    2. If clearly NOT a conversation (code editor, terminal, settings, dashboards, articles)
       → hasTask=false immediately. Skip to BAD-EXAMPLES check before responding.
    3. If a conversation IS visible → read the FULL flow to understand who said what.
    4. Look for TWO patterns in priority order:
       a. PATTERN 1 — USER COMMITMENT: someone asked something AND the user agreed/accepted.
       b. PATTERN 2 — UNADDRESSED REQUEST: someone asked the user, user hasn't responded.
    5. Verify SPECIFICITY (named person + concrete deliverable). Vague → skip.
    6. Verify FORGETTABILITY (will user forget after closing this window?).

    ── PATTERN 1 — USER COMMITMENT (highest priority) ──
    Read the conversation as a dialogue. Look for:
    - Another person makes a request, suggestion, or asks a question implying action.
    - The user responds with agreement, acceptance, or a promise.

    USER COMMITMENT SIGNALS (in the user's outgoing/right-side messages):
    - Explicit agreement: "Sure", "Will do", "On it", "I'll handle it", "Yeah I can do that",
      "Ok let me do that", "I'll take care of it", "Хорошо", "Сделаю", "Возьму на себя",
      "Я сделаю", "Хорошо, договорились".
    - Acceptance: "Ok", "Sounds good", "Got it", "Yep", "Agreed", "Let's do it",
      "Договорились", "Понял", "Окей".
    - Promises: "I'll send it", "Let me check", "I'll look into it", "Will get back to you",
      "Отправлю", "Проверю", "Гляну", "Напишу позже".
    - Scheduling: "I'll do it tomorrow", "Will send by EOD", "Сделаю завтра", "До конца дня".

    When you detect this pattern, the TASK is what the OTHER PERSON originally asked for
    (NOT "user agreed"). The user's agreement CONFIRMS it's a real intended task.
    Example: Stan: "Can you review my PR?" → User: "Sure, will do." → Task: "Review Stan's PR"
    Example: Майк: "Скинь договор?" → User: "Окей, до вечера." → Task: "Отправить договор Майку"

    ── PATTERN 2 — UNADDRESSED REQUEST (secondary) ──
    Someone asked the user to do something and the user hasn't responded yet.
    Signals (in incoming/left-side messages):
    - "Can you…", "Could you…", "Please…", "Don't forget to…", "Make sure you…"
    - "Можешь…", "Сделай…", "Не забудь…", "Скинь…", "Подготовь…"
    - Questions expecting an answer: "What's the status of…?", "Когда будет…?"
    - Assigned items: "@user", "assigned to you", review requests, "тебе на ревью".

    WHO COUNTS AS "SOMEONE":
    - Coworker in Slack, Teams, Discord, email, Telegram, WhatsApp, iMessage, Messenger.
    - Friend / family / contractor / client.
    - An AI assistant (ChatGPT, Claude, Cursor) suggesting the user do something — only
      counts if the user RESPONDED with commitment to that suggestion (PATTERN 1).
    - The user's own explicit reminder ("Remind me to…", "TODO: …", "Не забыть…").

    ── READING CONVERSATIONS (chat-direction rules) ──
    - RIGHT-SIDE / colored bubbles = SENT BY the user (outgoing).
    - LEFT-SIDE / gray/white bubbles = from another person (incoming).
    - Read the ENTIRE visible conversation to understand flow + context.
    - If user's LATEST message is an AGREEMENT/COMMITMENT to something the other person
      asked → EXTRACT the task they agreed to (PATTERN 1).
    - If user's latest is just casual chat / a question to others / sharing info → no task.
    - If there's an INCOMING request with no user response yet → extract as unaddressed (PATTERN 2).
    - If ALL visible messages are on the right side (only user talking) → skip (unless self-reminder).

    ── IGNORE OVERVIEW / SIDEBAR / LIST VIEWS ──
    Only extract from a SINGLE OPEN conversation. Skip these entirely:
    - Chat app sidebars (conversation lists, message previews, unread badges).
      Whether unread or read, the user is aware of them.
    - Email inbox lists, email preview panes, unread email counts. Same logic.
    - Any "overview mode" showing multiple threads / conversations / items in a list.
    - Notification centers, Slack/Discord channel lists.

    ── ALWAYS SKIP — these are NOT tasks ──
    - Terminal output, build logs, compiler warnings, pip/npm upgrade notices.
    - Code the user is actively writing or editing.
    - Project management boards (Jira, Linear, Trello) — already tracked elsewhere.
    - System UI, settings panels, media players, file browsers, dashboards.
    - Anything the user is clearly in the middle of doing right now.
    - Articles, blog posts, tutorials, lists of tips, search results, news.
    - Casual conversation with no action items (greetings, jokes, status updates with no asks).
    - Other people's schedules, commitments, plans (tasks for someone else, not the user).

    ── SPECIFICITY REQUIREMENT ──
    The task description MUST include:
    - A specific named person, project, or deliverable.
    - A concrete action verb (not just "respond", "check", "investigate" alone).
    If you cannot write a description with a named subject + concrete action → skip.

    ── FORGETTABILITY CHECK ──
    Ask: "Will the user forget this commitment/request after switching away from this window?"
    - YES → extract (that's why we exist).
    - NO (active focus / tracked elsewhere / will be done in next 30 sec) → skip.

    ── REAL BAD EXAMPLES (system has produced these — NEVER do this) ──
    ✗ "Investigate" — single word, useless.
    ✗ "Check logs" — what logs, for what purpose?
    ✗ "Clean up the data" — what data? where?
    ✗ "Track the logs" — which logs?
    ✗ "Modify claude.md" — how? why? what change?
    ✗ "Look through my data" — completely vague.
    ✗ "Update to new patched version" — of what software?
    ✗ "Remove thirty second line" — what line? in what file?
    ✗ "Look into Paul's issue" — what issue? be specific.
    ✗ "Investigate auth loss" — whose auth? what service? what happened?
    ✗ "Respond to messages" — which messages? which person? specific topic?
    If your draft description matches any of those patterns — call hasTask=false instead.

    ── REAL GOOD EXAMPLES (this level of specificity required) ──
    ✓ "Reply to Stan about 'Where is the developer section?'" — names person + quotes question.
    ✓ "Submit quarterly metrics to LG Technology Ventures" — entity + concrete deliverable.
    ✓ "Send Nik list of 10 recommended advisors" — person + exact deliverable.
    ✓ "Review and merge Thinh's PR for auth refactor" — user agreed to review (PATTERN 1).
    ✓ "Schedule demo with Alex for next Tuesday as discussed" — user committed to scheduling.
    ✓ "Pay Stripe invoice $450 due March 15" — invoice with explicit amount + date.
    ✓ "Отправить Майку контракт до конца дня" — user committed in chat (PATTERN 1).

    ── RELEVANCE SCORE ──
    - 90-100: Invoice with visible due date, PR explicitly assigned to user, explicit
      "Sure I'll do it" agreement, calendar event imminent.
    - 75-89: Explicit action request addressed to user (PATTERN 2), clear commitment to a
      slightly less specific ask (PATTERN 1 with general topic).
    - 50-74: Ambiguous — might be a task but context unclear. DO NOT mark hasTask=true.
    - <50: Not a task.
    Only relevance ≥75 pairs with hasTask=true. Below 75, hasTask=false.

    ── EVIDENCE FIELD ──
    Must be a verbatim quote (≥20 characters) from the OCR. A neutral reviewer reading
    just that quote should say "yes, that is a pending task for the user". If you cannot
    find such a quote → hasTask=false.

    ── FULFILLMENT CHECK (independent of hasTask) ──
    The user prompt may include an "OPEN TASKS" list (uuid: description) — the user's
    existing pending tasks. Check whether the screen PROVES the user ALREADY DID any
    of them: the promised message visible as SENT from the user's side (right-side
    bubbles), the promised file/link/answer visibly delivered in the conversation.
    - Report those in "fulfilled" with the task's uuid + a verbatim OCR quote (≥20
      chars) showing the completed action. Ids ONLY from the OPEN TASKS list.
    - Be conservative. Intention is NOT fulfillment: "I'll send it tonight" proves
      nothing; the sent contract / delivered answer does. No hard proof → [].
    - A fulfilled task must also NOT be re-extracted as a new task.
    - If there is no OPEN TASKS list, "fulfilled" is [].

    ── USER-REJECTED TASKS ──
    The user prompt may list tasks the user explicitly dismissed. NEVER extract a
    task similar to any of them — dismissal is a permanent "not interested".

    When unsure, hasTask=false, relevance <50, evidence="" — that is the correct answer
    for most windows. Do not overreach.

    CRITICAL: respond with ONLY the JSON. No prose, no markdown, no explanation.
    """

    private func buildPrompt(appName: String, windowTitle: String, ocr: String,
                             openTasks: [TaskFulfillment.OpenTaskRef] = [],
                             rejectedExamples: [String] = []) -> String {
        // Cap OCR — single-window prompts must stay small for 30/hour cost profile.
        let ocrCapped = ocr.count > 2000 ? String(ocr.prefix(2000)) : ocr
        var prompt = """
        App: \(appName)
        Window: \(windowTitle)
        OCR:
        ```
        \(ocrCapped)
        ```
        """
        if !rejectedExamples.isEmpty {
            prompt += "\n\nUSER-REJECTED TASKS (user explicitly dismissed these — do NOT extract similar):\n"
                + rejectedExamples.map { "- \($0)" }.joined(separator: "\n")
        }
        prompt += TaskFulfillment.promptSection(for: openTasks)
        return prompt
    }

    // MARK: - Parse

    struct ReactionJSON: Decodable {
        let hasTask: Bool
        let description: String?
        let dueAt: String?
        let relevance: Int?
        let evidence: String?
        /// ITER-057.5 — tasks from the OPEN TASKS prompt list the screen proves done.
        let fulfilled: [TaskFulfillment.FulfilledJSON]?

        private enum CodingKeys: String, CodingKey {
            case hasTask, description, dueAt, relevance, evidence, fulfilled
        }

        /// Lossy element wrapper — one malformed "fulfilled" entry (id as a
        /// number, bare string element) must not fail the WHOLE reaction decode
        /// and drop a valid new task with it (review finding).
        private struct LossyFulfilled: Decodable {
            let value: TaskFulfillment.FulfilledJSON?
            init(from decoder: Decoder) throws {
                value = try? TaskFulfillment.FulfilledJSON(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasTask = try c.decode(Bool.self, forKey: .hasTask)
            description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
            dueAt = (try? c.decodeIfPresent(String.self, forKey: .dueAt)) ?? nil
            relevance = (try? c.decodeIfPresent(Int.self, forKey: .relevance)) ?? nil
            evidence = (try? c.decodeIfPresent(String.self, forKey: .evidence)) ?? nil
            fulfilled = ((try? c.decodeIfPresent([LossyFulfilled].self, forKey: .fulfilled)) ?? nil)?
                .compactMap(\.value)
        }
    }

    /// Internal for tests. Extract the first balanced JSON object and decode.
    nonisolated static func parseReaction(_ response: String) -> ReactionJSON? {
        let extracted = extractJSONObject(from: response)
        guard let data = extracted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReactionJSON.self, from: data)
    }

    nonisolated private static func extractJSONObject(from text: String) -> String {
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
        request.timeoutInterval = 20

        let body = LLMRequestBody.proAdviceBody(
            system: system, user: user,
            tier: Self.llmTier, serviceId: Self.llmServiceId
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProcessingError.apiError("RealtimeReactor proxy HTTP \(http.statusCode)")
        }
        struct ProResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ProResponse.self, from: data)
        return result.text
    }

    private var hasLLMAccess: Bool {
        !settings.activeAPIKey.isEmpty
            || LicenseService.shared.isPro
            || LocalLLMService.shared.isReady
    }
}
