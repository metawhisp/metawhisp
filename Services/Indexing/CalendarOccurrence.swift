import Foundation

/// ITER-075 step 1 (1.1) — one occurrence of a calendar event: its series id,
/// its title, and this occurrence's own start and end.
///
/// Every occurrence of a recurring series shares one `eventIdentifier`, and
/// EventKit's `event(withIdentifier:)` answers with the series' FIRST
/// occurrence. Its end was months in the past, so the end check fired one
/// second into the meeting (19 of 24 calendar starts, 2026-09-22…25). The
/// occurrence the calendar tick already holds is carried to the start instead,
/// and no live code looks an event up by its id.
struct CalendarOccurrence: Equatable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date

    /// This occurrence among its series': the series id plus its own start.
    var key: String { "\(eventID)@\(Int(start.timeIntervalSince1970))" }

    /// nil without an id or dates; an empty title reads "Meeting".
    init?(eventID: String?, title: String?, start: Date?, end: Date?) {
        guard let eventID, !eventID.isEmpty, let start, let end else { return nil }
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        self.eventID = eventID
        self.title = trimmed.isEmpty ? "Meeting" : trimmed
        self.start = start
        self.end = end
    }
}

/// A calendar occurrence with what decides whether it counts.
struct CalendarCandidate: Equatable {
    let occurrence: CalendarOccurrence
    let isAllDay: Bool
    let isCanceled: Bool
    let declinedByMe: Bool

    var counts: Bool { !isAllDay && !isCanceled && !declinedByMe }
}

/// Picks the occurrence the calendar tick acts on. With overlapping calendars,
/// the one that started most recently is the one the owner is in.
enum CalendarOccurrencePicker {
    /// Started and not yet ended.
    static func running(in candidates: [CalendarCandidate], at now: Date) -> CalendarOccurrence? {
        latest(candidates.filter { $0.counts && $0.occurrence.start <= now && $0.occurrence.end > now })
    }

    /// Started within the last `lookback` seconds and not yet ended.
    static func startingNow(in candidates: [CalendarCandidate], at now: Date,
                            lookback: TimeInterval = 65) -> CalendarOccurrence? {
        let lookStart = now.addingTimeInterval(-lookback)
        return latest(candidates.filter {
            $0.counts && $0.occurrence.start >= lookStart && $0.occurrence.start <= now && $0.occurrence.end >= now
        })
    }

    /// The latest start wins; on the same start the id decides, so two
    /// queries that list the same events in another order pick the same one.
    private static func latest(_ candidates: [CalendarCandidate]) -> CalendarOccurrence? {
        candidates.map(\.occurrence).max { ($0.start, $0.eventID) < ($1.start, $1.eventID) }
    }
}
