import Foundation

/// ITER-075 step 1 (1.1) — when the calendar end check first fires.
enum CalendarEndStopSchedule {
    /// No end check in the first 10 minutes of a recording: a meeting whose
    /// calendar end had already passed used to get a "still recording" card
    /// within seconds of its start.
    static let minimumRecording: TimeInterval = 10 * 60

    /// After the event's end plus the grace, never before `minimumRecording`
    /// into the session, and never in the past. `sessionStart` is taken when
    /// the recording starts, so the floor holds from the very first check.
    static func fireAt(eventEnd: Date, sessionStart: Date, now: Date,
                       grace: TimeInterval = CalendarEndStopDecisionRules.defaultGraceSeconds) -> Date {
        max(eventEnd.addingTimeInterval(grace),
            sessionStart.addingTimeInterval(minimumRecording),
            now.addingTimeInterval(1))
    }
}
