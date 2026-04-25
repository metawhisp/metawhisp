import Foundation
import SwiftData

/// A single message in the Chat thread.
/// Mirrors `Message` (`backend/models/chat.py`) with minimal fields — no files/voice/sharing in MVP.
/// spec://BACKLOG#B2
@Model
final class ChatMessage {
    var id: UUID
    /// "human" — user typed; "ai" — assistant response.
    var sender: String
    var text: String
    var createdAt: Date
    /// If the AI response errored, capture for UI display.
    var errorText: String?

    /// ITER-016 — pending tool call awaiting user confirmation.
    /// Non-nil means: LLM output contained `<tool_call>` block, UI must render a
    /// confirm bubble (Yes / Cancel) instead of free text. On confirm, ChatService
    /// executes via ChatToolExecutor, sets `toolResultSummary`, and appends a new
    /// assistant message with the human-readable outcome.
    /// JSON-encoded `ChatToolExecutor.ToolCall` — {"tool":"…","args":{…}}.
    /// Nil on all legacy messages (Optional → SwiftData lightweight migration).
    var pendingToolCallJSON: String?
    /// Preview string the confirm UI shows ("Dismiss task \"Reply to Mike\"").
    /// Computed during validate(); stored so we don't re-run validation on re-render.
    var pendingToolPreview: String?
    /// Outcome line after execute. Nil while pending. Non-nil and non-empty → the
    /// tool ran (successfully or not) and the user sees this text in place of the
    /// confirm buttons ("✓ Dismissed task: Reply to Mike" or "✗ Task not found").
    var toolResultSummary: String?
    /// ITER-016 v2 — Wall-clock time when the tool actually ran (or was rejected).
    /// Drives the Undo button visibility window in `ChatView` (60s default).
    /// Distinct from `createdAt` because the user may sit on a confirm bubble for
    /// minutes before pressing YES — the undo clock starts at execute, not at LLM reply.
    var toolExecutedAt: Date?

    /// ITER-017 v2 — Native `tool_call_id` from Groq function-calling response.
    /// Used to correlate this assistant turn with the matching `{role:"tool", tool_call_id:...}`
    /// follow-up message we send back to the LLM after execute. Nil when message
    /// originated from the legacy `<tool_call>` regex path (no native id).
    var toolCallIdNative: String?

    /// ITER-017 v2 — Pretty-printed user prompt that produced this assistant turn.
    /// We persist it ON THE assistant message (not inferred at re-send time) because
    /// the retrieval blocks (memories/tasks/etc.) can drift between turns and we want
    /// the LLM follow-up to see the SAME context the original tool_call was made against.
    /// Only set on assistant messages that issued a tool_call (otherwise nil).
    var originatingUserPrompt: String?

    /// ITER-017 v2 — Parent assistant-message id when THIS message is a follow-up
    /// inserted after a tool execute (multi-step chain). Lets the UI render chain
    /// affordances and the chain-builder walk back to the root.
    var followupOfMessageId: UUID?

    init(sender: String, text: String, errorText: String? = nil,
         pendingToolCallJSON: String? = nil, pendingToolPreview: String? = nil) {
        self.id = UUID()
        self.sender = sender
        self.text = text
        self.errorText = errorText
        self.createdAt = Date()
        self.pendingToolCallJSON = pendingToolCallJSON
        self.pendingToolPreview = pendingToolPreview
    }
}
