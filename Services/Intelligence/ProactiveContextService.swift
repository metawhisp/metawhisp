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
    }

    func onNewContext(_ ctx: ScreenContext) {
        Task { @MainActor [weak self] in
            await self?.evaluateAndSurface(ctx: ctx)
        }
    }

    // MARK: - Pipeline

    private func evaluateAndSurface(ctx: ScreenContext) async {
        // ITER-064A.9 — snapshot before any await, checked again after the model
        // call: the user can delete their screen history mid-flight.
        let epoch = purgeEpoch
        // ── Hard gates ────────────────────────────────────────────────
        guard settings.proactiveEnabled else { return }
        guard !isRunning else { return }
        if let last = lastSurfaceAt {
            let cooldownSeconds = max(60, settings.proactiveCooldownMinutes * 60)
            guard Date().timeIntervalSince(last) > cooldownSeconds else { return }
        }
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

        // ── Activity summary (last hour) ─────────────────────────────
        let now = Date()
        let lookbackStart = now.addingTimeInterval(-activityLookbackMinutes * 60)
        let activitySummary = buildActivitySummary(from: lookbackStart, to: now)

        // ── LLM call (the actual filter) ─────────────────────────────
        // ITER-027.6 — hand the assistant 2h of screen history so it can
        // INVESTIGATE with tools instead of echoing the current frame.
        let insight: ExtractedInsight?
        insight = await assistant.evaluate(
            appName: ctx.appName,
            windowTitle: ctx.windowTitle.isEmpty ? nil : ctx.windowTitle,
            ocr: ctx.ocrText,
            activitySummary: activitySummary,
            licenseKey: licenseKey,
            history: fetchHistorySnapshots(now: now)
        )

        guard let insight else { return }

        // ITER-064A.9 — the screen rows this insight was derived from may have
        // been deleted while the model was thinking. Drop it rather than saving
        // a memory the user can no longer trace to any source.
        guard epoch == purgeEpoch else {
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
        let title = insight.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = (title?.isEmpty == false) ? title! : insight.body
        let bodyText: String = (titleText == insight.body) ? "" : insight.body

        guard let delivery = AppDelegate.shared?.screenAgentDelivery else { return }
        let item = ScreenAgentItem(
            runID: UUID(),
            headline: titleText,
            body: bodyText,
            sourceApp: ctx.appName,
            sourceWindowTitle: ctx.windowTitle,
            capturedAt: ctx.timestamp,
            evidenceContextIDs: [ctx.id]
        )

        let preflight = ScreenAgentDeliveryService.Preflight(
            featureEnabled: settings.proactiveEnabled,
            isPaused: settings.screenAgentPaused,
            meetingInProgress: AppDelegate.shared?.meetingRecorder.isRecording ?? false,
            pauseDuringMeetings: true,
            // The purge fence above already proved this run is still wanted.
            visitIsStillCurrent: epoch == purgeEpoch,
            secondsSinceLastPresented: delivery.secondsSinceLastPresented,
            minimumSecondsBetween: TimeInterval(max(60, settings.proactiveCooldownMinutes * 60)),
            popupSlotsFree: MWNotificationStack.shared.freeSlots
        )

        guard let presented = delivery.deliver(item, preflight: preflight) else {
            // Suppressed or unsaved. A suppressed comment is still in the Inbox;
            // pacing is not advanced for something nobody saw.
            return
        }

        lastSurfaceAt = Date()
        let itemID = presented.id
        let note = MWNotification(
            kind: .proactive,
            title: titleText,
            body: bodyText,
            onTap: { @MainActor in
                AppDelegate.shared?.screenAgentDelivery?
                    .recordInteraction(.opened, itemID: itemID)
                AppDelegate.shared?.openScreenAgentInbox(selecting: itemID)
            },
            proactiveItems: nil
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Proactive] ✅ surfaced insight in %@ (%d chars, item %@)",
              ctx.appName, insight.body.count, itemID.uuidString)
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
