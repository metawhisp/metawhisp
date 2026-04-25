import Foundation
import SwiftData

/// User-defined goal — a persistent target the assistant tracks across the day.
/// Three goal shapes (mirrors `GoalRecord`):
/// - `boolean`  — done / not done today (e.g. "Take meds", "Journal entry").
///   Only `currentValue` is used (0 = not done, 1 = done). Reset each day on first read.
/// - `scale`    — qualitative 1-N rating (e.g. "Mood: 1-10", "Energy: 1-5").
///   `minValue` and `maxValue` define the scale range. `currentValue` is today's rating.
/// - `numeric`  — counter toward a target (e.g. "20 push-ups", "3000 words").
///   `targetValue` is the goal, `currentValue` is progress. `unit` labels both.
///
/// Goals feed two systems:
/// - MetaChat: injected as `<active_goals>` block in chat context so the LLM can
///   answer "how am I doing on my goals?" and weave goal progress into advice.
/// - DailySummary: passed to `energyAgent` and `headlineAgent` so the recap can
///   reference progress ("ahead on writing, behind on push-ups").
///
/// All forward-compat fields are Optional → SwiftData lightweight migration adds
/// columns without a versioning plan.
/// spec://BACKLOG#Phase5.G1
@Model
final class Goal {
    var id: UUID
    /// Short imperative title — "Write 1000 words", "Take vitamin D", "Mood check".
    var title: String
    /// Optional longer rationale shown in detail view + sometimes used by chat LLM.
    var goalDescription: String?
    /// One of "boolean" | "scale" | "numeric". Controls UI shape and progress math.
    var goalType: String
    /// For numeric: the target. For scale: unused (use maxValue). For boolean: 1.
    var targetValue: Double?
    /// Today's progress. Boolean: 0 or 1. Scale: minValue...maxValue. Numeric: 0...∞.
    var currentValue: Double
    /// Scale lower bound (inclusive). Default 1 if scale.
    var minValue: Double?
    /// Scale upper bound (inclusive). Default 10 if scale.
    var maxValue: Double?
    /// Display unit for numeric goals — "words", "push-ups", "min", "pages".
    var unit: String?
    /// When true, goal appears in active list, MetaChat context, and DailySummary.
    /// When false, it's archived but kept for history.
    var isActive: Bool
    /// Soft-delete marker — kept for audit, excluded from queries.
    var isDismissed: Bool
    /// When `currentValue` was last touched. Lets us show "updated 2h ago" + reset
    /// boolean / scale goals on the next calendar day.
    var lastProgressAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        title: String,
        goalType: String,
        goalDescription: String? = nil,
        targetValue: Double? = nil,
        currentValue: Double = 0,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        unit: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.goalDescription = goalDescription
        self.goalType = goalType
        self.targetValue = targetValue
        self.currentValue = currentValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.unit = unit
        self.isActive = true
        self.isDismissed = false
        self.lastProgressAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Derived

    /// Normalised 0…1 progress for the progress bar UI + LLM hints.
    /// Boolean → 0 or 1. Scale → (current - min) / (max - min). Numeric → current / target.
    var progressFraction: Double {
        switch goalType {
        case "boolean":
            return currentValue >= 1 ? 1 : 0
        case "scale":
            let lo = minValue ?? 1
            let hi = maxValue ?? 10
            let span = max(hi - lo, 0.0001)
            return min(max((currentValue - lo) / span, 0), 1)
        case "numeric":
            let target = targetValue ?? 0
            guard target > 0 else { return 0 }
            return min(max(currentValue / target, 0), 1)
        default:
            return 0
        }
    }

    /// Human-readable progress for UI + LLM context.
    /// "Done" / "Pending" · "7/10" · "350/1000 words"
    var progressLabel: String {
        switch goalType {
        case "boolean":
            return currentValue >= 1 ? "Done" : "Pending"
        case "scale":
            let lo = minValue ?? 1
            let hi = maxValue ?? 10
            return "\(formattedNumber(currentValue))/\(formattedNumber(hi))"
                + (lo == 1 ? "" : " (min \(formattedNumber(lo)))")
        case "numeric":
            let target = targetValue ?? 0
            let unitSuffix = (unit?.isEmpty == false) ? " \(unit!)" : ""
            return "\(formattedNumber(currentValue))/\(formattedNumber(target))\(unitSuffix)"
        default:
            return "\(formattedNumber(currentValue))"
        }
    }

    /// Strip trailing `.0` for whole numbers — UI doesn't need "7.0/10".
    private func formattedNumber(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    /// Boolean / scale goals reset at the start of each day. Numeric goals accumulate.
    /// Call before reading `currentValue` for display so stale yesterday-progress is wiped.
    func resetIfNewDay(now: Date = Date(), calendar: Calendar = .current) {
        guard goalType == "boolean" || goalType == "scale" else { return }
        guard let last = lastProgressAt else { return }
        if !calendar.isDate(last, inSameDayAs: now) {
            currentValue = 0
            updatedAt = now
        }
    }
}
