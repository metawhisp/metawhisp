import Foundation
import SwiftData

/// Proactive in-the-moment surfacing (ITER-015).
///
/// While the user is COMPOSING in Slack/Mail/Notion/etc., MetaWhisp silently
/// embeds the current screen text, finds the top 2-3 relevant memories +
/// past decisions + pending waiting-on tasks, and shows a peripheral chip
/// (via `ProactiveChipWindow`) for 8 seconds. Not a notification — no OS
/// banner, no sound, no flow interrupt.
///
/// Design principles:
/// - Opt-in (off by default). Settings toggle + per-app blacklist.
/// - Cooldown between surfaces (default 5 min) — never spammy.
/// - High relevance threshold (cosine ≥ 0.55). Missing relevance → no chip.
/// - Sensitive-app blacklist (1Password, Keychain, Terminal).
/// - Min OCR length (80 chars). Tiny windows don't trigger.
/// - Composing-intent heuristic v1: whitelist of known composing apps.
///
/// spec://iterations/ITER-015-proactive-surfacing
@MainActor
final class ProactiveContextService: ObservableObject {
    @Published var isRunning = false
    @Published var lastSurfaceAt: Date?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    weak var embeddingService: EmbeddingService?

    /// Cosine threshold. Keeps the bar high — better to show nothing than noise.
    private let relevanceThreshold: Float = 0.55
    /// Min OCR chars to bother embedding.
    private let minContextChars = 80
    /// How many items total across all types.
    private let maxChipItems = 3

    /// Known composing-friendly apps. v1 heuristic — whitelist is tighter than
    /// blacklist, keeps false-positives to ~zero. v2 will add a micro-classifier.
    private let composingAppBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",        // Slack
        "com.apple.mail",                    // Mail
        "com.apple.MobileSMS",              // Messages
        "notion.id",                         // Notion
        "com.linear",                        // Linear (some bundle variants)
        "com.linear.linear",
        "com.figma.Desktop",                 // Figma comments
        "md.obsidian",                       // Obsidian
        "com.microsoft.Outlook",             // Outlook
        "com.hnc.Discord",                   // Discord
        "com.telegram.macos",                // Telegram
        "ru.keepcoder.Telegram",
        "com.loom.desktop",                  // Loom comments
    ]
    /// Name-based fallback (when bundleID isn't known from OCR pipeline).
    private let composingAppNames: Set<String> = [
        "Slack", "Mail", "Messages", "Notion", "Linear", "Figma", "Obsidian",
        "Outlook", "Discord", "Telegram", "Loom", "Spark", "Airmail", "Superhuman",
    ]

    func configure(modelContainer: ModelContainer, embeddingService: EmbeddingService) {
        self.modelContainer = modelContainer
        self.embeddingService = embeddingService
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
        // ── Gates ───────────────────────────────────────────────────────────
        guard settings.proactiveEnabled else { return }
        guard !isRunning else { return }           // concurrency guard
        if let last = lastSurfaceAt {
            let cooldownSeconds = max(60, settings.proactiveCooldownMinutes * 60)
            guard Date().timeIntervalSince(last) > cooldownSeconds else { return }
        }
        guard ctx.ocrText.count >= minContextChars else { return }
        guard !isBlacklisted(appName: ctx.appName) else { return }
        guard isComposingApp(appName: ctx.appName) else { return }

        isRunning = true
        defer { isRunning = false }

        // ── Retrieve candidates in parallel ─────────────────────────────────
        guard let embedding = embeddingService else { return }
        // Truncate OCR to first 1500 chars — enough signal, respect embedding token cap.
        let queryText = String(ctx.ocrText.prefix(1500))
        let queryVec: [Float]
        do {
            queryVec = try await embedding.embedOne(queryText)
        } catch {
            NSLog("[Proactive] embed failed (graceful): %@", error.localizedDescription)
            return
        }
        guard !queryVec.isEmpty else { return }

        var items: [SurfaceItem] = []
        items.append(contentsOf: rankedMemories(query: queryVec))
        items.append(contentsOf: rankedConversations(query: queryVec))
        items.append(contentsOf: rankedWaitingTasks(query: queryVec, ctxText: queryText))

        // Apply global threshold + cap + dedup.
        items = items
            .filter { $0.relevance >= relevanceThreshold }
            .sorted { $0.relevance > $1.relevance }
            .prefix(maxChipItems)
            .map { $0 }

        guard !items.isEmpty else { return }

        // ── Surface chip ────────────────────────────────────────────────────
        lastSurfaceAt = Date()
        ProactiveChipWindow.shared.show(items: items, source: ctx.appName)
        NSLog("[Proactive] surfaced %d items for app=%@ (cos range %.2f-%.2f)",
              items.count, ctx.appName,
              items.map(\.relevance).min() ?? 0,
              items.map(\.relevance).max() ?? 0)
    }

    // MARK: - Retrieval helpers

    private func rankedMemories(query: [Float]) -> [SurfaceItem] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.embedding != nil }
        )
        let mems = (try? ctx.fetch(desc)) ?? []
        return mems.compactMap { m -> SurfaceItem? in
            guard let data = m.embedding else { return nil }
            let vec = EmbeddingService.decode(data)
            guard !vec.isEmpty else { return nil }
            let sim = EmbeddingService.cosineSimilarity(query, vec)
            let label = m.headline?.isEmpty == false ? m.headline! : String(m.content.prefix(60))
            return SurfaceItem(
                kind: .memory,
                title: label,
                subtitle: m.content,
                relevance: sim,
                tapAction: .openChat(query: "Что ты знаешь про \"\(label)\"?")
            )
        }
    }

    private func rankedConversations(query: [Float]) -> [SurfaceItem] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.discarded && $0.embedding != nil && $0.title != nil }
        )
        let convs = (try? ctx.fetch(desc)) ?? []
        return convs.compactMap { c -> SurfaceItem? in
            guard let data = c.embedding else { return nil }
            let vec = EmbeddingService.decode(data)
            guard !vec.isEmpty else { return nil }
            let sim = EmbeddingService.cosineSimilarity(query, vec)
            let title = c.title ?? "untitled"
            return SurfaceItem(
                kind: .pastDecision,
                title: title,
                subtitle: c.overview ?? "",
                relevance: sim,
                tapAction: .openChat(query: "Расскажи про созвон \"\(title)\"")
            )
        }
    }

    /// Waiting-on tasks where the assignee's name appears in the current screen text.
    /// Cheap boost: if user is typing AT that person, remind them what's owed.
    private func rankedWaitingTasks(query: [Float], ctxText: String) -> [SurfaceItem] {
        guard let container = modelContainer else { return [] }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> {
                !$0.isDismissed && !$0.completed && $0.assignee != nil
            }
        )
        let tasks = (try? ctx.fetch(desc)) ?? []
        let lowered = ctxText.lowercased()
        return tasks.compactMap { t -> SurfaceItem? in
            guard let name = t.assignee, !name.isEmpty else { return nil }
            let nameLower = name.lowercased()
            // Only include when the assignee name is present in the context.
            guard lowered.contains(nameLower) else { return nil }
            // Score = embedding cosine if available, else flat 0.6 (above threshold).
            var sim: Float = 0.6
            if let data = t.embedding {
                let vec = EmbeddingService.decode(data)
                if !vec.isEmpty {
                    sim = max(0.6, EmbeddingService.cosineSimilarity(query, vec))
                }
            }
            return SurfaceItem(
                kind: .waitingOnTask,
                title: "Waiting on \(name)",
                subtitle: t.taskDescription,
                relevance: sim,
                tapAction: .openChat(query: "Напомни что я жду от \(name)")
            )
        }
    }

    // MARK: - App gating

    private func isBlacklisted(appName: String) -> Bool {
        let list = settings.proactiveBlacklist
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let lowered = appName.lowercased()
        return list.contains { !$0.isEmpty && lowered.contains($0) }
    }

    private func isComposingApp(appName: String) -> Bool {
        let lowered = appName.lowercased()
        if composingAppNames.contains(where: { $0.lowercased() == lowered }) { return true }
        // Substring tolerance: "Slack", "Slack.app", "Slack (Helper)" — all map.
        for n in composingAppNames {
            if lowered.contains(n.lowercased()) { return true }
        }
        return false
    }
}

// MARK: - SurfaceItem DTO

enum SurfaceItemKind {
    case memory
    case pastDecision
    case waitingOnTask
    case projectContext
}

enum SurfaceTapAction {
    case openChat(query: String)
    case openTab(MainWindowView.SidebarTab)
}

struct SurfaceItem: Identifiable {
    let id = UUID()
    let kind: SurfaceItemKind
    let title: String
    let subtitle: String
    let relevance: Float
    let tapAction: SurfaceTapAction

    var iconName: String {
        switch kind {
        case .memory:         return "brain"
        case .pastDecision:   return "bubble.left.and.bubble.right"
        case .waitingOnTask:  return "clock"
        case .projectContext: return "folder"
        }
    }
}
