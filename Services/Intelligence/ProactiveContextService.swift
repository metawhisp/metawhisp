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
    func onNewContext(_ ctx: ScreenContext) {
        Task { @MainActor [weak self] in
            await self?.evaluateAndSurface(ctx: ctx)
        }
    }

    // MARK: - Pipeline

    private func evaluateAndSurface(ctx: ScreenContext) async {
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
        let insight: ExtractedInsight?
        insight = await assistant.evaluate(
            appName: ctx.appName,
            windowTitle: ctx.windowTitle.isEmpty ? nil : ctx.windowTitle,
            ocr: ctx.ocrText,
            activitySummary: activitySummary,
            licenseKey: licenseKey
        )

        guard let insight else { return }

        // ── Persist for cross-restart dedup ──────────────────────────
        await storage.save(insight)

        // ── Surface ──────────────────────────────────────────────────
        // Single-line render: headline as the card's main text, body as
        // the secondary line. No more "list of related conversations".
        lastSurfaceAt = Date()
        let title = insight.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = (title?.isEmpty == false) ? title! : insight.body
        let bodyText: String = (titleText == insight.body) ? "" : insight.body
        let note = MWNotification(
            kind: .proactive,
            title: titleText,
            body: bodyText,
            onTap: nil,
            proactiveItems: nil
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Proactive] ✅ surfaced insight in %@ (%d chars)",
              ctx.appName, insight.body.count)
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
