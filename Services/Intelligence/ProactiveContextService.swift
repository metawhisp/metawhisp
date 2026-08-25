import CoreGraphics
import Foundation
import SwiftData

/// Proactive in-the-moment surfacing (ITER-027 v1 — text-only insight extraction).
///
/// As the user works ANYWHERE, MetaWhisp asks an LLM whether there's ONE
/// specific, non-obvious insight worth surfacing right now. Most ticks
/// return nothing — that's the point. When something fires, it's actionable:
/// *"Sensitive credentials visible — mask before sharing"*, *"Year 2026 —
/// did you mean 2027?"*, *"Stashed changes 2h ago — git stash pop"*.
///
/// Replaces the pre-027 cosine-retrieval pipeline that surfaced lists of
/// "тематически близких созвонов" — list noise that the user reasonably
/// described as "вода" (specs/health-reports/2026-05-08*.md).
///
/// Pipeline per `evaluateAndSurface(ctx:)` call:
///   1. Hard gates: `proactiveEnabled`, cooldown, OCR length, blacklist.
///      Most calls still exit early — but the gate is "is this a sensitive
///      context the user opted out of?" (blacklist), NOT "is this a
///      pre-approved composing app?" (the prior whitelist). Reference
///      (omi-style) keeps gating to blacklist + the LLM itself, on the
///      principle that the model is a better content filter than a
///      hardcoded app list. Whitelist was removed 2026-05-11 after audit
///      showed it dropped 14 days of work in Claude / Safari / Chrome /
///      Arc on the floor (all non-composing) → 1 surfaced insight in 14
///      days.
///   2. Build activity summary from last hour's `ScreenContext`.
///   3. Call `InsightAssistantService.evaluate(...)` — the LLM is the
///      filter. It either returns an insight or `nil`.
///   4. Persist returned insight via `InsightStorage` (cross-restart dedup).
///   5. Push as a single-line `.proactive` MWNotification.
///
/// ITER-027.6 (future) adds a vision pass + 2-phase SQL tool loop for
/// deeper-context insights ("you stashed changes 2h ago" needs the LLM
/// to be able to query terminal OCR from an hour back).
@MainActor
final class ProactiveContextService: ObservableObject {
    @Published var isRunning = false
    @Published var lastSurfaceAt: Date?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?

    // ITER-027 dependencies. Wired by `configure(...)` from AppDelegate.
    private weak var insightAssistant: InsightAssistantService?
    private var insightStorage: InsightStorage?

    /// Min OCR chars to bother the LLM. Tiny windows have nothing to
    /// reason about; saves a proxy call.
    private let minContextChars = 80

    /// How many minutes back the activity summary covers. Reference: 60.
    private let activityLookbackMinutes: TimeInterval = 60

    /// ITER-027.6 — how far back the investigation tools can search, and the
    /// record cap that bounds the in-memory snapshot array handed to the loop.
    private let investigationLookbackMinutes: TimeInterval = 120
    private let investigationMaxSnapshots = 400

    /// Fetch the last 2h of screen contexts (newest first) for the
    /// investigation loop. Empty array → assistant falls back to the legacy
    /// single-pass path.
    private func fetchHistorySnapshots(now: Date) -> [InsightInvestigator.Snapshot] {
        guard let container = modelContainer else { return [] }
        let cutoff = now.addingTimeInterval(-investigationLookbackMinutes * 60)
        var descriptor = FetchDescriptor<ScreenContext>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = investigationMaxSnapshots
        let context = ModelContext(container)
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map {
            InsightInvestigator.Snapshot(
                time: $0.timestamp, app: $0.appName,
                window: $0.windowTitle, ocr: $0.ocrText
            )
        }
    }

    func configure(modelContainer: ModelContainer,
                   insightAssistant: InsightAssistantService) {
        self.modelContainer = modelContainer
        self.insightAssistant = insightAssistant
        self.insightStorage = InsightStorage(modelContainer: modelContainer)
        // ITER-027.4 — seed the dedup window from persisted insights so
        // the LLM doesn't repeat what it told the user before app restart.
        Task { [weak self] in
            guard let self,
                  let storage = self.insightStorage,
                  let assistant = self.insightAssistant else { return }
            let recent = await storage.loadRecent(limit: 50)
            assistant.seedDedup(from: recent)
            NSLog("[Proactive] dedup seeded with %d prior insights", recent.count)
        }
    }

    /// Called on every new `ScreenContext` row persisted (existing hook).
    /// Gated hard — most calls exit early without doing any work.
    /// ITER-064A.9 — purge fence, same shape as `ScreenExtractor` and
    /// `RealtimeScreenReactor` already have. This service was the one screen
    /// consumer the delete path did not invalidate, so an insight whose model
    /// call was in flight when the user deleted their screen history would come
    /// back, get saved as a memory, and be surfaced — derived entirely from
    /// rows that no longer exist.
    private var purgeEpoch = 0

    func invalidatePendingWork() {
        purgeEpoch += 1
        runQueue.cancelAll()
    }

    /// ITER-066 follow-up (Codex P0) — the newest-value queue, actually wired.
    /// It was written, tested and then left as dead code while production kept
    /// the `guard !isRunning` drop, which discards exactly the screens the
    /// user moves to during a slow model call.
    private var runQueue = ScreenAgentRunQueue<ScreenContext>()

    /// The journal row of the analysis currently in flight, so the deadline
    /// watchdog can mark it expired without guessing by contextID.
    private var currentRunHandle: UUID?

    func onNewContext(_ ctx: ScreenContext) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .startNow(let token, let permit) = self.runQueue.submit(ctx, at: Date()) {
                await self.drive(token, permit: permit)
            }
        }
    }

    /// Run one context, then whatever was newest while it ran. Depth is
    /// bounded: the queue holds at most one pending context.
    ///
    /// The deadline is enforced over the ACTIVE call too, not only the queue:
    /// a stuck transport used to own the runner for its full timeout, so the
    /// screens the user moved to meanwhile sat pending far past any deadline.
    /// The watchdog finishes the run's queue slot at the deadline; the late
    /// completion then reports in with a stranger's permit and is ignored.
    /// The late RESULT may still surface — but only through the same guards
    /// every result passes (still the accepted screen, purge epoch, toggles),
    /// which is freshness by identity, not by clock.
    private func drive(_ ctx: ScreenContext,
                       permit: ScreenAgentRunQueue<ScreenContext>.RunPermit) async {
        isRunning = true
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(ScreenAgentTimingPolicy.endToEndDeadline * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            NSLog("[Proactive] run past deadline — releasing the queue")
            // The journal hears about the timeout too — only a row still
            // "running" is marked, and a late real completion overwrites it
            // with the truer outcome.
            if let handle = self.currentRunHandle {
                AppDelegate.shared?.screenAgentDelivery?.expireRun(runID: handle)
            }
            await self.settleQueue(finishing: permit)
        }
        await evaluateAndSurface(ctx: ctx)
        watchdog.cancel()
        await settleQueue(finishing: permit)
    }

    /// One place decides what a finished (or expired) run means for the queue.
    /// Both the normal completion and the watchdog land here; the permit makes
    /// the second arrival a no-op, so they cannot double-start or double-stop.
    private func settleQueue(
        finishing permit: ScreenAgentRunQueue<ScreenContext>.RunPermit) async {
        switch runQueue.finish(permit, at: Date()) {
        case .startNow(let next, let nextPermit):
            await drive(next, permit: nextPermit)
        case .expired(let dropped):
            isRunning = runQueue.isRunning
            NSLog("[Proactive] pending context expired unshown (%@)", dropped.appName)
        default:
            // A stale watchdog or late completion must not stop a successor
            // run the other party already started.
            isRunning = runQueue.isRunning
        }
    }

    // MARK: - Pipeline

    private func evaluateAndSurface(ctx: ScreenContext) async {
        // ITER-064A.9 — snapshot before any await, checked again after the model
        // call: the user can delete their screen history mid-flight.
        let epoch = purgeEpoch
        // ITER-067 — the identity of this run. There is one analysis per
        // captured context, so the context's own ID is the stable surrogate
        // until a durable run record exists: a fresh UUID per call made the
        // idempotency check inert, and one minted here would still not survive
        // a relaunch mid-run.
        let runID = ctx.id
        // ── Hard gates ────────────────────────────────────────────────
        guard settings.proactiveEnabled, settings.screenContextEnabled else { return }
        // ITER-070 follow-up (Codex) — one pacing choice governs the cost gate
        // too. The legacy cooldown sat in front of the delivery gate, so
        // "Frequent" was silently overridden by whatever the old slider said.
        let pacing = ScreenAgentPacing(rawValue: settings.screenAgentPacing) ?? .balanced
        if let since = AppDelegate.shared?.screenAgentDelivery?.secondsSinceLastPresented,
           since < pacing.minimumSecondsBetween { return }
        guard ctx.ocrText.count >= minContextChars else { return }
        guard !isBlacklisted(appName: ctx.appName) else { return }
        // No composing-app whitelist (removed 2026-05-11). The LLM is the
        // content filter — it returns `no_advice` for screens that aren't
        // worth surfacing. Blacklist above is the only hardcoded gate; users
        // can extend it from Settings → Proactive blacklist for sensitive
        // contexts they don't want analyzed (banking, password vaults, etc).
        guard let assistant = insightAssistant,
              let storage = insightStorage else { return }
        guard let licenseKey = LicenseService.shared.licenseKey,
              !licenseKey.isEmpty else {
            // Pro-only feature; quietly no-op for free tier.
            return
        }

        isRunning = true
        defer { isRunning = false }

        // ── The run journal (plan §4) ────────────────────────────────
        // Every analysis run leaves a row, silences included. Preflight
        // rejections above never started an analysis and stay unjournaled.
        // The row is closed by its own ID — closing by non-unique contextID
        // let overlapping runs close each other with the wrong outcome.
        let journal = AppDelegate.shared?.screenAgentDelivery
        let runHandle = journal?.beginRun(
            contextID: ctx.id, trigger: "contextAccepted",
            deadlineAt: Date().addingTimeInterval(ScreenAgentTimingPolicy.endToEndDeadline))
        currentRunHandle = runHandle
        var runOutcome = "abandoned"
        var runEvidence: [String] = []
        defer {
            // Only clear our own handle — a watchdog-promoted successor may
            // already own the slot by the time this run's defer fires.
            if currentRunHandle == runHandle { currentRunHandle = nil }
            if let runHandle {
                journal?.completeRun(runID: runHandle, outcomeReason: runOutcome,
                                     evidenceRefs: runEvidence)
            }
        }

        // The watchdog's successor lands while the previous evaluation still
        // owns the assistant; its re-entrancy guard would return nil and this
        // run would be journaled "noProposal" — an invented decision about an
        // analysis that never ran (Codex).
        if insightAssistant?.isEvaluating == true {
            runOutcome = "assistantBusy"
            return
        }

        // ── Activity summary (last hour) ─────────────────────────────
        let now = Date()
        let lookbackStart = now.addingTimeInterval(-activityLookbackMinutes * 60)
        let activitySummary = buildActivitySummary(from: lookbackStart, to: now)

        // ── LLM call (the actual filter) ─────────────────────────────
        // ITER-027.6 — hand the assistant 2h of screen history so it can
        // INVESTIGATE with tools instead of echoing the current frame.
        let insight: ExtractedInsight?
        let history = fetchHistorySnapshots(now: now)
        // ITER-069 §5 — the investigator may reach into the user's own store,
        // read-only, one call per kind, through the same executor MetaChat
        // already trusts with its privacy filters. Nothing here may mutate.
        let toolExecutor = AppDelegate.shared?.chatService.toolExecutor
        let evaluation = await assistant.evaluate(
            appName: ctx.appName,
            windowTitle: ctx.windowTitle.isEmpty ? nil : ctx.windowTitle,
            ocr: ctx.ocrText,
            activitySummary: activitySummary,
            licenseKey: licenseKey,
            history: history,
            searchTasks: toolExecutor.map { executor in
                { query in
                    let result = await executor.executeReadOnly(
                        .init(id: nil, tool: "searchTasks", args: ["query": query, "limit": "8"]))
                    // Codex P1 — a failure summary is not evidence.
                    return result.ok ? result.summary : "Error: task search failed"
                }
            },
            searchMemories: toolExecutor.map { executor in
                { query in
                    let result = await executor.executeReadOnly(
                        .init(id: nil, tool: "searchMemories", args: ["query": query, "limit": "8"]))
                    return result.ok ? result.summary : "Error: memory search failed"
                }
            }
        )
        insight = evaluation?.insight

        guard let insight else {
            runOutcome = "noProposal"
            return
        }

        // ITER-066 — the director decides, not the producer. Everything above
        // this line proposes; nothing above it may interrupt the user.
        //
        // The insight path predates evidence refs, so the runtime issues one
        // reference for the screen this run is about and the claim is checked
        // against it. That is narrower than the full allowlist ITER-066
        // describes, and deliberately so: it catches the failure that actually
        // shipped — a comment asserting something the current screen does not
        // say — rather than pretending a richer contract exists.
        // ITER-066 — production and the replay deck share this adapter, so a
        // fixture exercises the exact bridge a live insight crosses.
        // Codex P0 — the investigator reads history, so history is legitimate
        // evidence. Citing only the current screen silenced every historical
        // insight wholesale as "ungrounded": the claim was true, the runtime
        // had simply thrown away where it came from.
        let (evidence, evidenceIDs) = ScreenAgentCandidateAdapter.evidence(
            contextID: ctx.id, ocrText: ctx.ocrText, history: history,
            retrieved: evaluation?.retrieved ?? [])
        let candidate = ScreenAgentCandidateAdapter.candidate(from: insight, citing: evidenceIDs)
        var decision = ScreenAgentDirector.decide(
            candidates: [candidate],
            evidence: evidence,
            screenText: ctx.ocrText,
            recentHeadlines: recentDeliveredHeadlines(),
            rejectedSignatures: AppDelegate.shared?.screenAgentDelivery?
                .rejectedSignatures() ?? []
        )

        // ITER-069 — the one vision call, spent exactly where the spec says:
        // text produced a concrete claim that only eyes can verify. Consent is
        // read live, the frame must be the same generation, and the answer is
        // judged by the same director with nothing else relaxed.
        if case .silence(.needsVision) = decision,
           settings.screenAgentVisualConsent,
           let visionClient = AppDelegate.shared?.screenAgentVision {
            let outcome = await visionClient.analyzeCurrentFrame(
                contextID: ctx.id,
                visualConsentGranted: { AppSettings.shared.screenAgentVisualConsent },
                isStillCurrent: { [weak self] in
                    self?.purgeEpoch == epoch
                        && AppDelegate.shared?.screenContext.lastAcceptedContextID == ctx.id
                        // Codex P0 — master-off mid-flight kills the result.
                        && AppSettings.shared.screenContextEnabled
                        && AppSettings.shared.proactiveEnabled
                })
            if case .facts(let facts) = outcome, !facts.isEmpty {
                let (seeingEvidence, seeingIDs) = ScreenAgentCandidateAdapter.evidence(
                    contextID: ctx.id, ocrText: ctx.ocrText,
                    history: history, visualFacts: facts)
                var seeingCandidate = ScreenAgentCandidateAdapter.candidate(
                    from: insight, citing: seeingIDs)
                // Only the facts that are ABOUT the claim license it — an
                // unrelated observation must leave needsVision standing.
                seeingCandidate.visualEvidenceIDs = ScreenAgentCandidateAdapter
                    .supportingVisualIDs(
                        facts: facts,
                        claim: seeingCandidate.headline + " " + seeingCandidate.body)
                decision = ScreenAgentDirector.decide(
                    candidates: [seeingCandidate],
                    evidence: seeingEvidence,
                    screenText: ctx.ocrText,
                    recentHeadlines: recentDeliveredHeadlines(),
                    rejectedSignatures: AppDelegate.shared?.screenAgentDelivery?
                        .rejectedSignatures() ?? []
                )
            }
        }
        guard case .item(let directedHeadline, let directedBody, let citedIDs) = decision else {
            if case .silence(let reason) = decision {
                runOutcome = reason.rawValue
                NSLog("[Proactive] silent — %@", reason.rawValue)
                // Codex P0 — the assistant remembers an insight in its session
                // dedup the moment it returns it, so a director rejection also
                // blocked every retry of the same idea for the session. A
                // guard-level rejection is the director's verdict on THIS
                // attempt, not a fact about the idea; the user's own verdicts
                // (duplicate, userRejected) do stay remembered.
                switch reason {
                case .duplicate, .userRejected: break
                default: assistant.retract(insight)
                }
            }
            return
        }

        // The director said item; the journal keeps what it cited, past the
        // run — the decision's evidence IDs used to be discarded here (Codex).
        runOutcome = "item"
        runEvidence = citedIDs

        // ITER-064A.9 — the screen rows this insight was derived from may have
        // been deleted while the model was thinking. Drop it rather than saving
        // a memory the user can no longer trace to any source.
        guard epoch == purgeEpoch else {
            runOutcome = "invalidated"
            NSLog("[Proactive] Screen history deleted mid-run — discarding insight")
            return
        }

        // ── Persist for cross-restart dedup ──────────────────────────
        await storage.save(insight)

        // ── Surface ──────────────────────────────────────────────────
        // ITER-067 — the comment is written down first and shown second. It
        // used to be pushed straight onto the stack with `onTap: nil`, so it
        // bypassed the quiet-hours and pacing every other notification
        // respects, clicking it did nothing, and nothing recorded that it had
        // ever happened.
        let titleText = directedHeadline
        let bodyText: String = (titleText == directedBody) ? "" : directedBody

        guard let delivery = AppDelegate.shared?.screenAgentDelivery else { return }
        let item = ScreenAgentItem(
            runID: runID,
            headline: titleText,
            body: bodyText,
            sourceApp: ctx.appName,
            sourceWindowTitle: ctx.windowTitle,
            capturedAt: ctx.timestamp,
            evidenceContextIDs: [ctx.id]
        )

        let preflight = ScreenAgentDeliveryService.Preflight(
            // Codex P0 — the final gate re-checks everything that can be
            // withdrawn mid-run: the master capture toggle and the TCC
            // permission, not only the agent toggle.
            featureEnabled: settings.proactiveEnabled
                && settings.screenContextEnabled
                && CGPreflightScreenCaptureAccess(),
            isPaused: settings.screenAgentPaused,
            meetingInProgress: AppDelegate.shared?.meetingRecorder.isRecording ?? false,
            pauseDuringMeetings: true,
            // ITER-067 — the purge fence only proves history was not deleted.
            // The promise is narrower and more important: the user is still
            // looking at the screen this is about. `lastAcceptedContextID` is
            // whatever the capture path most recently committed, so a window
            // switch during the model call retires this run rather than
            // interrupting someone about a screen they left.
            visitIsStillCurrent: epoch == purgeEpoch
                && AppDelegate.shared?.screenContext.lastAcceptedContextID == ctx.id
                && Date().timeIntervalSince(ctx.timestamp)
                    <= ScreenAgentTimingPolicy.maxResultAgeSeconds,
            secondsSinceLastPresented: delivery.secondsSinceLastPresented,
            // ITER-070 — one plain-language choice governs this now.
            minimumSecondsBetween: (ScreenAgentPacing(rawValue: settings.screenAgentPacing)
                ?? .balanced).minimumSecondsBetween,
            popupSlotsFree: MWNotificationStack.shared.freeSlots,
            presentedLast24h: delivery.presentedInLast24h(),
            dailyLimit: (ScreenAgentPacing(rawValue: settings.screenAgentPacing) ?? .balanced).dailyLimit
        )

        guard let presented = delivery.deliver(item, preflight: preflight) else {
            // Suppressed or unsaved. A suppressed comment is still in the Inbox;
            // pacing is not advanced for something nobody saw.
            return
        }

        lastSurfaceAt = Date()
        let itemID = presented.id
        // The record says `presented` only once the card is actually on screen.
        defer { delivery.confirmPresented(itemID: itemID) }
        let noteID = UUID()
        let note = MWNotification(
            id: noteID,
            kind: .proactive,
            title: titleText,
            body: bodyText,
            onTap: { @MainActor in
                AppDelegate.shared?.screenAgentDelivery?
                    .recordInteraction(.opened, itemID: itemID)
                AppDelegate.shared?.openScreenAgentInbox(selecting: itemID)
                // Opening it is the end of the card's life on screen; leaving
                // it up invites repeated clicks that overwrite the record.
                MWNotificationStack.shared.dismiss(id: noteID, reason: .opened)
            },
            screenAgentItemID: itemID,
            proactiveItems: nil
        )
        MWNotificationStack.shared.push(note)
        // DoD §8 — settled-context→card latency, measurable from the log:
        // grep "latency=" and compute the percentile instead of guessing.
        NSLog("[Proactive] ✅ surfaced insight in %@ (%d chars, item %@, latency=%.1fs)",
              ctx.appName, insight.body.count, itemID.uuidString,
              Date().timeIntervalSince(ctx.timestamp))
    }

    /// Headlines the user was actually shown recently. Rewording an idea does
    /// not make it new, and the old edit-distance dedup only caught it when the
    /// words barely changed.
    private func recentDeliveredHeadlines(limit: Int = 20) -> [String] {
        AppDelegate.shared?.screenAgentDelivery?
            .recentItems(limit: limit)
            .map(\.headline) ?? []
    }

    // MARK: - Activity summary

    /// Pull last-hour `ScreenContext` rows from SwiftData and hand to the
    /// pure-function builder. Bounds memory by capping fetch to recent
    /// rows (the time predicate further filters in-window).
    private func buildActivitySummary(from lookbackStart: Date, to now: Date) -> String {
        guard let container = modelContainer else { return "" }
        let mctx = ModelContext(container)
        var desc = FetchDescriptor<ScreenContext>(
            predicate: #Predicate { $0.timestamp > lookbackStart && $0.timestamp <= now },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // 60 minutes × 1 frame / 30s = 120 max in a heavy session; cap at
        // 500 to be safe against bursty captures.
        desc.fetchLimit = 500
        let rows = (try? mctx.fetch(desc)) ?? []
        let mapped = rows.map { ctx in
            ActivitySummaryBuilder.Row(
                appName: ctx.appName,
                windowTitle: ctx.windowTitle,
                timestamp: ctx.timestamp
            )
        }
        return ActivitySummaryBuilder.build(rows: mapped, lookbackStart: lookbackStart, now: now)
    }

    // MARK: - App gating

    private func isBlacklisted(appName: String) -> Bool {
        let list = settings.proactiveBlacklist
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let lowered = appName.lowercased()
        return list.contains { !$0.isEmpty && lowered.contains($0) }
    }
}
