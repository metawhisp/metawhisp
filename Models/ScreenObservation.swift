import Foundation
import SwiftData

/// Observation record for a screen activity window.
/// Mirrors Omi's `ObservationRecord` (`desktop/Desktop/Sources/Rewind/Core/ObservationRecord.swift`):
/// "Every screenshot analysis produces an observation — whether or not a task was found."
///
/// We diverge from Omi per-snapshot and instead batch per-visit (consecutive same-app window as one observation)
/// to keep Pro-proxy cost reasonable (~20 observations/hour vs 120 raw snapshots).
///
/// spec://BACKLOG#Phase2.R1
@Model
final class ScreenObservation {
    var id: UUID
    /// FK to the last ScreenContext in the visit window (Omi uses screenshotId — we use UUID of ScreenContext).
    var screenContextId: UUID?
    /// App frontmost during this observation window.
    var appName: String
    /// Window title snippet (can change within a visit — we record the last).
    var windowTitle: String?
    /// 1-2 sentence description of what the user was doing.
    /// "User reviewing Overchat analytics in GA4."
    var contextSummary: String
    /// Specific current activity verb-phrase.
    /// "Analyzing traffic decline", "Writing documentation", "Reviewing PR".
    var currentActivity: String
    /// Whether an actionable task was spotted (R2 will link TaskItem via screenContextId).
    var hasTask: Bool
    /// Optional preview of the task (full TaskItem stored separately by R2).
    var taskTitle: String?
    /// Omi's CategoryEnum value (work / personal / technology / ...). Nil if LLM couldn't classify.
    var sourceCategory: String?
    /// Focus status from Omi: "focused" | "distracted" | nil. Heuristic — if user is switching apps fast, distracted.
    var focusStatus: String?
    /// Start of the observation window.
    var startedAt: Date
    /// End of the observation window.
    var endedAt: Date
    var createdAt: Date

    init(
        screenContextId: UUID?,
        appName: String,
        windowTitle: String?,
        contextSummary: String,
        currentActivity: String,
        hasTask: Bool,
        taskTitle: String? = nil,
        sourceCategory: String? = nil,
        focusStatus: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = UUID()
        self.screenContextId = screenContextId
        self.appName = appName
        self.windowTitle = windowTitle
        self.contextSummary = contextSummary
        self.currentActivity = currentActivity
        self.hasTask = hasTask
        self.taskTitle = taskTitle
        self.sourceCategory = sourceCategory
        self.focusStatus = focusStatus
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = Date()
    }
}
