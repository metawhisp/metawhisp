import Foundation

/// Outcome of `CalendarEndStopDecision.evaluate(...)`. Pure value type so
/// the AppDelegate scheduler can act on it without holding any state in
/// the decider itself.
enum CalendarEndStopDecision: Equatable {
    /// Recording continues — either we're still inside the event, or
    /// within the grace window after endDate.
    case keepRunning
    /// Past endDate + grace, audio below quiet threshold → stop now.
    case stopNow
    /// Past endDate + grace BUT audio is still active → push notification
    /// to user and re-check at `newDeadline`.
    case notifyAndExtend(newDeadline: Date)
    /// User has ignored too many notify attempts → force stop to prevent
    /// indefinite recording (e.g. someone left mic on overnight after a
    /// long-running music session).
    case hardStop
}

/// Pure-function decision for ITER-034 calendar-end-aware auto-stop.
///
/// Used by `AppDelegate` to decide what to do at `EKEvent.endDate + grace`
/// for calendar-triggered recordings. silence guard alone (3 min) was
/// insufficient because any continued audio reset it — meetings ran for
/// 30+ min past their calendar end before user remembered to press STOP.
///
/// Bug history: user report 2026-05-08 «созвон не выключается». Manual
/// stops at 09:45 (15 min into 9:30-10:00 event) and 10:41 (41 min into
/// 10:00-10:30 event) — recording overran calendar end by 11+ min on
/// average. This decider plus `EKEvent.endDate` plumbing closes the gap.
enum CalendarEndStopDecisionRules {
    static let defaultGraceSeconds: TimeInterval = 60
    static let defaultExtensionSeconds: TimeInterval = 300
    static let defaultQuietRMSThreshold: Float = 0.005
    static let defaultMaxNotifyAttempts: Int = 3
}

extension CalendarEndStopDecision {
    /// - Parameters:
    ///   - now: caller-provided clock (for tests). Production passes `Date()`.
    ///   - eventEnd: `EKEvent.endDate` snapshot from the moment the
    ///     recording started. Stale if user edits the calendar mid-record;
    ///     acceptable trade-off for simplicity.
    ///   - audioRMSLastNSec: max(mic, system) RMS observed during the
    ///     last sampling window. Caller usually polls 30s of audio.
    ///   - notifyAttemptsSoFar: how many times we've already pushed the
    ///     "meeting overrunning — tap to stop" card. Caller increments
    ///     after each `notifyAndExtend`.
    ///   - graceSeconds: grace period after `eventEnd` before any stop
    ///     decision. Default 60s — covers the common "couple of minutes
    ///     to wrap up" overrun.
    ///   - extensionSeconds: how far ahead to push the next deadline on
    ///     `notifyAndExtend`. Default 300s = 5 min.
    ///   - quietRMSThreshold: RMS below this counts as "no one talking".
    ///     Default 0.005 ≈ background room noise.
    ///   - maxNotifyAttempts: after this many `notifyAndExtend` rounds,
    ///     `hardStop` instead. Prevents infinite recording.
    static func evaluate(
        now: Date,
        eventEnd: Date,
        audioRMSLastNSec: Float,
        notifyAttemptsSoFar: Int,
        graceSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultGraceSeconds,
        extensionSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultExtensionSeconds,
        quietRMSThreshold: Float = CalendarEndStopDecisionRules.defaultQuietRMSThreshold,
        maxNotifyAttempts: Int = CalendarEndStopDecisionRules.defaultMaxNotifyAttempts
    ) -> CalendarEndStopDecision {
        // Inside event OR within grace window → keep going.
        let secondsPastEnd = now.timeIntervalSince(eventEnd)
        if secondsPastEnd < graceSeconds { return .keepRunning }

        // Past grace + already exhausted notify budget → force stop.
        if notifyAttemptsSoFar >= maxNotifyAttempts { return .hardStop }

        // Past grace, audio quiet → graceful stop.
        if audioRMSLastNSec < quietRMSThreshold { return .stopNow }

        // Audio still active → notify user, re-check after extension.
        return .notifyAndExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
    }
}
