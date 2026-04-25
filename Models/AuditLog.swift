import Foundation
import SwiftData

/// Append-only audit row for every MetaChat tool execution (ITER-016 v2).
///
/// Why: when LLM mutations enter the picture, an undo path AND a "what did the
/// AI do today" review need a stable trail. We never delete or mutate AuditLog
/// rows after insert — only flip `undone` when the user reverts a recent action.
///
/// Snapshot strategy: for every supported tool we capture the minimum state
/// required to revert in `snapshotJSON`. Stored as JSON to keep the schema
/// flat across heterogeneous payloads:
///   - dismissTask         → {"taskId": "...", "wasIsDismissed": false, "wasStatus": "committed"}
///   - completeTask        → {"taskId": "...", "wasCompleted": false, "wasCompletedAt": null}
///   - dismissMemory       → {"memoryId": "...", "wasIsDismissed": false}
///   - updateGoalProgress  → {"goalId": "...", "previousValue": 3.0}
///   - addTask             → {"createdTaskId": "..."}     (revert = soft-delete)
///   - addMemory           → {"createdMemoryId": "..."}   (revert = soft-delete)
///
/// Undo eligibility: any entry with `undone == false` AND age < `Self.undoWindowSeconds`
/// (60s default — chat-style undo is short by design; longer edits user goes to
/// Tasks/Memories tab manually).
///
/// spec://iterations/ITER-016-conversational-mutation
@Model
final class AuditLog {
    var id: UUID
    var timestamp: Date
    /// Name of the tool exactly as called (matches `ChatToolExecutor.ToolCall.tool`).
    var tool: String
    /// Original tool args, JSON-encoded `[String: String]`.
    var argsJSON: String
    /// `summary` line from `ExecResult` — human-readable outcome for audit display.
    var resultSummary: String
    /// Whether the execution succeeded (false → snapshot is meaningless, undo skips).
    var success: Bool
    /// Snapshot needed to revert the mutation. Nil for failed executions.
    var snapshotJSON: String?
    /// True after `ChatToolExecutor.undo(_:)` reverts this entry. Append-only model:
    /// we never delete the row, just flip the bit so re-undo is a no-op.
    var undone: Bool
    /// Foreign key to the `ChatMessage` that triggered this tool call. Lets the UI
    /// rebind the undo button after restart by walking from message → audit row.
    var chatMessageId: UUID?

    /// Window after which an undo button stops appearing in chat. Beyond this the
    /// row is still in the DB for review, just not interactively revertible.
    static let undoWindowSeconds: TimeInterval = 60

    init(
        tool: String,
        argsJSON: String,
        resultSummary: String,
        success: Bool,
        snapshotJSON: String?,
        chatMessageId: UUID?
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.tool = tool
        self.argsJSON = argsJSON
        self.resultSummary = resultSummary
        self.success = success
        self.snapshotJSON = snapshotJSON
        self.undone = false
        self.chatMessageId = chatMessageId
    }

    /// True when within the undo window AND not already undone AND succeeded.
    var isUndoable: Bool {
        guard success, !undone else { return false }
        return Date().timeIntervalSince(timestamp) <= Self.undoWindowSeconds
    }
}
