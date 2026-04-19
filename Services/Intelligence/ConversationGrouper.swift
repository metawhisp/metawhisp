import Foundation
import SwiftData

/// Groups transcripts into Conversations (Omi-aligned aggregation root).
/// Rule: consecutive dictations within 10 min silence belong to one Conversation.
/// Meetings always get their own Conversation (source="meeting").
///
/// Omi reference: `backend/models/conversation.py` (ConversationSource + ConversationStatus).
/// The 10-min gap is a desktop-adapted analog of Omi's 2-min wearable silence split —
/// keyboard/dictation rhythm on desktop is slower than continuous wearable audio.
///
/// spec://BACKLOG#C1.1
@MainActor
final class ConversationGrouper {
    /// Silence gap after which a dictation conversation auto-closes. 10 min for desktop.
    static let dictationGapSeconds: TimeInterval = 600

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Assign a freshly-saved HistoryItem to an active Conversation or create a new one.
    /// Called by TranscriptionCoordinator after `historyService.save(result)`.
    @discardableResult
    func assign(historyItem: HistoryItem) -> Conversation? {
        guard let container = modelContainer else { return nil }
        let ctx = ModelContext(container)

        let source = historyItem.source ?? "microphone"
        let conv = activeOrNewConversation(source: source, at: historyItem.createdAt, in: ctx)

        historyItem.conversationId = conv.id
        conv.updatedAt = historyItem.createdAt
        try? ctx.save()

        NSLog("[ConversationGrouper] Assigned HistoryItem %@ → Conversation %@ (source=%@, status=%@)",
              historyItem.id.uuidString.prefix(8) as CVarArg,
              conv.id.uuidString.prefix(8) as CVarArg,
              conv.source,
              conv.status)
        return conv
    }

    /// Explicitly close any in-progress conversations that have been idle past the gap threshold.
    /// Can be called periodically (timer) or on-demand.
    func closeStaleConversations() {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.status == "inProgress" && !$0.discarded }
        )
        descriptor.fetchLimit = 50
        guard let actives = try? ctx.fetch(descriptor) else { return }

        let now = Date()
        var closedCount = 0
        for conv in actives {
            // Dictation conversations: close if silent past gap. Meetings stay open until explicit stop.
            guard conv.source == "dictation" else { continue }
            if now.timeIntervalSince(conv.updatedAt) > Self.dictationGapSeconds {
                close(conv, in: ctx)
                closedCount += 1
            }
        }
        if closedCount > 0 {
            try? ctx.save()
            NSLog("[ConversationGrouper] Closed %d stale dictation conversations", closedCount)
        }
    }

    /// Close a specific conversation explicitly (e.g. meeting stop button).
    func closeConversation(id: UUID) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let conv = try? ctx.fetch(descriptor).first else { return }
        close(conv, in: ctx)
        try? ctx.save()
    }

    // MARK: - Private

    /// Find active dictation conversation within gap window, OR create a new one.
    /// Meetings always get a fresh conversation.
    private func activeOrNewConversation(source: String, at time: Date, in ctx: ModelContext) -> Conversation {
        let groupSource = source == "meeting" ? "meeting" : "dictation"

        if groupSource == "meeting" {
            // Meetings never merge — always fresh conversation.
            // Meeting = single-shot (one recording → one conversation) so close immediately.
            let conv = Conversation(source: "meeting", startedAt: time)
            conv.status = "completed"
            conv.finishedAt = time
            ctx.insert(conv)
            scheduleStructuredGeneration(for: conv.id)
            return conv
        }

        // Dictation: find in-progress dictation conversation within gap window.
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate {
                $0.source == "dictation" && $0.status == "inProgress" && !$0.discarded
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let active = try? ctx.fetch(descriptor).first,
           time.timeIntervalSince(active.updatedAt) <= Self.dictationGapSeconds {
            return active
        }

        // No active conversation within gap — close any stragglers + open fresh.
        // (closeStaleConversations would also catch them, but be proactive on assign.)
        if let stale = try? ctx.fetch(descriptor).first {
            close(stale, in: ctx)
        }

        let fresh = Conversation(source: "dictation", startedAt: time)
        ctx.insert(fresh)
        return fresh
    }

    private func close(_ conv: Conversation, in ctx: ModelContext) {
        conv.status = "completed"
        conv.finishedAt = Date()
        conv.updatedAt = Date()
        scheduleStructuredGeneration(for: conv.id)
    }

    /// Fire-and-forget StructuredGenerator for a closed conversation.
    /// spec://BACKLOG#C1.2
    private func scheduleStructuredGeneration(for conversationId: UUID) {
        Task { @MainActor [weak self] in
            // Small delay so the HistoryItem assigned in the same tick is persisted first.
            try? await Task.sleep(for: .milliseconds(300))
            _ = self
            await AppDelegate.shared?.structuredGenerator.generate(conversationId: conversationId)
        }
    }
}
