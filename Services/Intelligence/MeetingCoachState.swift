import Foundation

/// Shared state for the live meeting copilot overlay (ITER-019.2).
///
/// During an active meeting `LiveMeetingAdvisor` feeds 30s partial transcripts
/// into `MeetingCoachService.process(...)`, which calls the LLM with a
/// meeting-specific prompt and emits a `Suggestion` here. The
/// `MeetingCoachWindow` observes `@Published` properties and renders a
/// floating overlay (no notification banners).
///
/// Lifecycle:
/// - `arm()`  — meeting started; window can show; reset list
/// - `disarm()` — meeting stopped; window hides
@MainActor
final class MeetingCoachState: ObservableObject {
    static let shared = MeetingCoachState()

    /// One LLM-generated suggestion in the running list.
    struct Suggestion: Identifiable {
        enum Kind: String {
            case question     // "Worth asking: ..."
            case attention    // "Pay attention to: ..."
            case missed       // "Not yet covered: ..."
            case followUp     // "Consider following up on: ..."
        }
        let id = UUID()
        let kind: Kind
        let text: String
        let createdAt: Date
    }

    /// Suggestions in chronological order (newest last). Window renders newest
    /// first; capped at `maxSuggestions` so old ones fall off.
    @Published private(set) var suggestions: [Suggestion] = []
    /// Last 200 chars of transcript — shown as "what was just said" footer.
    @Published private(set) var transcriptTail: String = ""
    /// True while a meeting is recording AND the user has the overlay enabled.
    @Published private(set) var isVisible: Bool = false
    /// True while we're awaiting an LLM response (UI shows "thinking…" state).
    @Published var isProcessing: Bool = false

    /// How many to keep in the rolling list. Anything older slides off the top.
    private let maxSuggestions = 3
    /// Auto-remove a suggestion this many seconds after it was added. Keeps
    /// the overlay clean — user complaint was «они не пропадают».
    private let suggestionTTL: TimeInterval = 90

    /// Per-suggestion expiration tasks so we can cancel them on disarm.
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func arm() {
        cancelAllExpirations()
        suggestions = []
        transcriptTail = ""
        isProcessing = false
        isVisible = true
    }

    func disarm() {
        cancelAllExpirations()
        isVisible = false
    }

    func addSuggestion(_ kind: Suggestion.Kind, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = Suggestion(kind: kind, text: trimmed, createdAt: Date())
        suggestions.append(item)
        if suggestions.count > maxSuggestions {
            // Cancel + drop the oldest expiration tasks too.
            let dropped = suggestions.prefix(suggestions.count - maxSuggestions)
            for old in dropped { expirationTasks.removeValue(forKey: old.id)?.cancel() }
            suggestions.removeFirst(suggestions.count - maxSuggestions)
        }
        // Schedule TTL removal — fades out after the window expires unless
        // the meeting ends first (disarm cancels all).
        expirationTasks[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.suggestionTTL ?? 90))
            guard !Task.isCancelled, let self else { return }
            self.suggestions.removeAll { $0.id == item.id }
            self.expirationTasks.removeValue(forKey: item.id)
        }
    }

    private func cancelAllExpirations() {
        for (_, task) in expirationTasks { task.cancel() }
        expirationTasks.removeAll()
    }

    func updateTranscriptTail(_ text: String) {
        // Keep just the last 200 chars so the overlay footer stays compact.
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 200 {
            transcriptTail = cleaned
        } else {
            transcriptTail = "…" + cleaned.suffix(200)
        }
    }
}
