import AppKit
import Combine
import Foundation

/// Decides when a call should start recording itself.
///
/// Two ways in:
///
/// - **Calendar.** A non-allday event that has just started fires immediately,
///   whatever is on screen. An event may fire again while it is still running
///   if the attempt recorded nothing — see `CalendarAutoStartRetry` for the
///   ceiling.
/// - **The window in front.** A recognised call window that stays frontmost
///   for ten seconds fires. `SystemAudioCaptureService.detectCallContext` is
///   what makes a window "recognised": an always-call application, a chat app
///   showing a call indicator in its title, or a browser whose title carries a
///   meeting address. The caller then shows a five-second countdown and, once
///   recording, a sixty-second audio sniff discards a meeting that turned out
///   to be nobody talking.
///
/// Two requirements were dropped, each because it made the gate silent rather
/// than careful:
///
/// - Sustained AUDIO (removed 2026-05-15): the caller could not probe audio
///   without a running recorder and hardcoded `false`, so the condition could
///   never be met.
/// - FULLSCREEN for browser calls (removed 2026-09-17): a meeting run in an
///   ordinary window beside your notes — the common case — never crossed the
///   threshold, so recording only ever started from a calendar event. The
///   countdown and the post-start sniff are what keep a glance at a meeting
///   page from becoming a recording.
///
/// The gate is a pure state holder — the AppDelegate runs a one-second tick
/// loop that calls `evaluate(...)` and acts on the `Decision`.
///
/// spec://iterations/ITER-026-v2-meeting-auto-start
@MainActor
final class MeetingAutoStartGate {
    static let shared = MeetingAutoStartGate()

    /// The app uses `shared`; a fresh instance exists so the decision can be
    /// exercised without a running app.
    init() {}

    /// User explicit spec — 10 sec of a sustained call window in front.
    private let sustainedSecondsRequired: Int = 10

    /// Counter for "call window frontmost, sustained" — reset on any drop.
    private var frontStreak: Int = 0

    /// Snapshot of the call name we've been tracking so the consumer knows
    /// what to start ("Google Meet" / "Zoom" / etc).
    private var currentCallName: String?

    /// Set when the boundary already fired for this event so the next tick
    /// doesn't double-fire on it.
    private var lastCalendarEventID: String?

    /// Attempts made per event, so a retry can stop.
    private var calendarAttempts: [String: Int] = [:]

    /// Ticks since the last calendar attempt — the retry's spacing. It does
    /// NOT advance while a meeting is recording: counting through a recording
    /// meant a stop could be followed by a retry 98 ms later (owner's log,
    /// 2026-09-22 16:17:30).
    private var ticksSinceCalendarAttempt: Int = 0

    /// Events the person turned off by hand. A retry is for a meeting that
    /// gave up on its own, never for one someone stopped.
    private var declinedEvents: Set<String> = []

    /// Reset the window-tracking state. Called when the caller knows the gate
    /// should forget what it was watching (recording started, user declined).
    /// Calendar attempts survive on purpose: forgetting them here would let
    /// the event that just started fire again on the very next tick.
    func reset() {
        frontStreak = 0
        currentCallName = nil
    }

    /// What the caller should do this tick.
    enum Decision: Equatable {
        /// No call signal at all — nothing to do.
        case idle
        /// Signal present but not yet sustained — keep monitoring.
        case tracking(name: String, secondsLeft: Int)
        /// Ten seconds of a call window in front. Caller shows the plashka and
        /// runs countdown + audio-sniff before starting.
        case fallbackReady(name: String)
        /// A calendar event is due. Caller shows the plashka immediately for
        /// THAT event regardless of what is on screen.
        case calendarReady(name: String, eventID: String)
    }

    /// Called every ~1 second by the AppDelegate fast-tick loop.
    ///
    /// - parameter callName: name returned by `detectCallContext` for the
    ///   FRONTMOST window only; nil when the user isn't looking at a call.
    /// - parameter calendarEventNow: a non-allday event that has just started.
    /// - parameter calendarEventInProgress: a non-allday event that is running
    ///   right now, whether or not it just started.
    /// - parameter isRecording: whether a meeting is already being recorded —
    ///   nothing is proposed on top of one.
    /// The person stopped this event's recording by hand, or dismissed its
    /// countdown. Nothing starts it again by itself.
    func decline(eventID: String) {
        guard !eventID.isEmpty, declinedEvents.insert(eventID).inserted else { return }
        NSLog("[AutoStartGate] %@ turned off by hand — it will not start itself again", eventID)
    }

    func evaluate(
        callName: String?,
        calendarEventNow: (id: String, title: String)?,
        calendarEventInProgress: (id: String, title: String)?,
        isRecording: Bool
    ) -> Decision {
        // The cooldown is time spent NOT recording. Counting through a meeting
        // made the wait expire while it ran, so a stop was followed instantly
        // by the next attempt.
        if isRecording { ticksSinceCalendarAttempt = 0 } else { ticksSinceCalendarAttempt += 1 }

        // Calendar trumps everything. Fire once per boundary.
        if let ev = calendarEventNow, ev.id != lastCalendarEventID {
            lastCalendarEventID = ev.id
            noteCalendarAttempt(ev.id)
            return .calendarReady(name: ev.title, eventID: ev.id)
        }

        // The event is still running and the last attempt left nothing
        // recording. Ask again — bounded.
        if let ev = calendarEventInProgress,
           CalendarAutoStartRetry.shouldRetry(attempts: calendarAttempts[ev.id] ?? 0,
                                              ticksSinceLast: ticksSinceCalendarAttempt,
                                              isRecording: isRecording,
                                              eventInProgress: true,
                                              declined: declinedEvents.contains(ev.id)) {
            noteCalendarAttempt(ev.id)
            NSLog("[AutoStartGate] retrying %@ — attempt %d of %d, nothing is recording",
                  ev.title, calendarAttempts[ev.id] ?? 0, CalendarAutoStartRetry.maxAttempts)
            return .calendarReady(name: ev.title, eventID: ev.id)
        }

        // No call window in front → idle, and the streak starts over.
        guard let name = callName else {
            frontStreak = 0
            currentCallName = nil
            return .idle
        }

        // A different call than the one being tracked starts its own streak.
        if currentCallName != name {
            currentCallName = name
            frontStreak = 0
        }

        frontStreak += 1

        if frontStreak >= sustainedSecondsRequired {
            let finalName = name
            frontStreak = 0
            currentCallName = nil
            return .fallbackReady(name: finalName)
        }

        return .tracking(name: name, secondsLeft: max(0, sustainedSecondsRequired - frontStreak))
    }

    private func noteCalendarAttempt(_ eventID: String) {
        calendarAttempts[eventID, default: 0] += 1
        ticksSinceCalendarAttempt = 0
    }
}
