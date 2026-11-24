import Foundation

/// What one meeting recording is, fixed when it starts: how it started, the
/// name it goes by, the calendar occurrence it belongs to, and its real start —
/// and, once stopped, its real stop.
///
/// It travels with the captured audio into the save (ITER-083). The event used
/// to live in two AppDelegate fields that the next recording overwrote before
/// the earlier one was saved, and the saved meeting got no event at all: one
/// was guessed afterwards by time overlap, which failed for every call that ran
/// past its slot.
///
/// Only a calendar start has an event. A call window ("Google Meet" names every
/// Meet room) or a hand on the record button says nothing about which meeting
/// it is, and nothing here guesses.
struct RecordingContext: Equatable {
    enum Origin: String, Equatable {
        case calendar, fallback, manual
    }

    let origin: Origin
    /// The name the grouper keys a resume on: the event's title for a
    /// calendar start, the call app's for a fallback start, none for manual.
    let callName: String?
    let event: CalendarOccurrence?
    /// Taken before the recorder starts.
    let startedAt: Date
    /// Taken when the recording stops, before any asynchronous work.
    private(set) var stoppedAt: Date?
    /// What the stop was (ITER-083 I3): an `ended` meeting settles before it
    /// is processed, any other is final at once. nil until stopped.
    private(set) var outcome: StopOutcome?

    var occurrenceKey: String? { event?.key }

    static func calendar(_ event: CalendarOccurrence, startedAt: Date) -> RecordingContext {
        RecordingContext(origin: .calendar, callName: event.title, event: event, startedAt: startedAt)
    }

    static func fallback(callName: String, startedAt: Date) -> RecordingContext {
        RecordingContext(origin: .fallback, callName: callName, event: nil, startedAt: startedAt)
    }

    static func manual(startedAt: Date) -> RecordingContext {
        RecordingContext(origin: .manual, callName: nil, event: nil, startedAt: startedAt)
    }

    /// The snapshot a stop hands to the save; a second stop keeps the first.
    func stopped(at date: Date, outcome: StopOutcome? = nil) -> RecordingContext {
        var copy = self
        if copy.stoppedAt == nil {
            copy.stoppedAt = date
            copy.outcome = outcome
        }
        return copy
    }
}
