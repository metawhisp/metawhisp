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
    /// exercised without a running app, on a clock of its own.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private let now: () -> Date

    /// How long a call stopped by hand must stay out of front before its window
    /// may start a recording again: by then that call is over.
    static let heldCallRelease: TimeInterval = 30 * 60

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

    /// When each call was last the window in front, kept for `heldCallRelease`.
    private var lastInFront: [String: Date] = [:]

    /// Calls in front at some moment of the recording now running: the calls a
    /// stop by hand is about. Emptied when a recording starts and when it ends.
    private var inFrontWhileRecording: Set<String> = []
    private var wasRecording = false

    /// Calls the person stopped by hand. Their window in front starts nothing
    /// until it has been out of front for `heldCallRelease` (owner's log,
    /// 2026-10-20: a Meet stopped at 19:22:52, 19:30:40 and 19:32:43 started
    /// itself again 2.5 min, 26 s and 13 s later, each time from the window).
    private var heldCalls: Set<String> = []

    /// The calendar event running at the last tick: a stop by hand refuses its
    /// retry too, even when the recording was not started for it.
    private var eventInProgress: String?

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
    /// - parameter practiceHoldsCapture: the onboarding practice has the
    ///   microphone, so a meeting would be refused. Nothing is proposed and
    ///   nothing is spent — not an event's boundary, not one of its attempts —
    ///   until the practice gives the microphone back (step-1 review #6).
    /// The person stopped this event's recording by hand, or dismissed its
    /// countdown. Nothing starts it again by itself.
    func decline(eventID: String) {
        guard !eventID.isEmpty, declinedEvents.insert(eventID).inserted else { return }
        NSLog("[AutoStartGate] %@ turned off by hand — it will not start itself again", eventID)
    }

    /// The person stopped a recording, or dismissed its countdown, by hand. The
    /// calls they were in — in front during the recording or lately — start
    /// nothing until each has been out of front for `heldCallRelease`, and the
    /// event running now is not retried. Another call, and the next event's
    /// start, still fire.
    func stoppedByHand() {
        let t = now()
        let recent = lastInFront.filter { t.timeIntervalSince($0.value) < Self.heldCallRelease }.keys
        for name in inFrontWhileRecording.union(recent) {
            heldCalls.insert(name)
            lastInFront[name] = t
        }
        if let eventInProgress { decline(eventID: eventInProgress) }
        reset()
        NSLog("[AutoStartGate] stopped by hand — %@ will not start itself until out of front for %d min",
              heldCalls.isEmpty ? "no call" : heldCalls.sorted().joined(separator: ", "),
              Int(Self.heldCallRelease / 60))
    }

    /// Whether a stop by hand still holds this call.
    func isHeld(_ callName: String) -> Bool {
        heldCalls.contains(callName)
    }

    /// The practice took the microphone during this event's countdown and the
    /// recorder refused the start: the attempt is given back. Only the person
    /// and an attempt that ran may spend an event's retries.
    func refund(eventID: String) {
        guard let attempts = calendarAttempts[eventID], attempts > 0 else { return }
        calendarAttempts[eventID] = attempts - 1
        NSLog("[AutoStartGate] %@ refused while the practice had the microphone — the attempt is not counted", eventID)
    }

    func evaluate(
        callName: String?,
        calendarEventNow: (id: String, title: String)?,
        calendarEventInProgress: (id: String, title: String)?,
        isRecording: Bool,
        practiceHoldsCapture: Bool
    ) -> Decision {
        // The cooldown is time spent NOT recording. Counting through a meeting
        // made the wait expire while it ran, so a stop was followed instantly
        // by the next attempt.
        if isRecording { ticksSinceCalendarAttempt = 0 } else { ticksSinceCalendarAttempt += 1 }
        noteWhatIsInFront(callName, isRecording: isRecording, eventInProgress: calendarEventInProgress?.id)

        // Every proposal now would be refused. Three refused countdowns used
        // to spend all of an event's attempts, and it never started after the
        // practice. The window streak starts over too.
        if practiceHoldsCapture {
            frontStreak = 0
            currentCallName = nil
            return .idle
        }

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

        // The call the person stopped by hand starts nothing until it is over.
        if heldCalls.contains(name) {
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

    /// Keeps what a stop by hand needs: which calls were in front and when, and
    /// the event running now. A held call out of front for `heldCallRelease`
    /// is let go here.
    private func noteWhatIsInFront(_ callName: String?, isRecording: Bool, eventInProgress: String?) {
        let t = now()
        if isRecording != wasRecording { inFrontWhileRecording = [] }
        wasRecording = isRecording
        if let callName {
            lastInFront[callName] = t
            if isRecording { inFrontWhileRecording.insert(callName) }
        }
        lastInFront = lastInFront.filter { t.timeIntervalSince($0.value) < Self.heldCallRelease }
        for name in heldCalls where lastInFront[name] == nil {
            heldCalls.remove(name)
            NSLog("[AutoStartGate] %@ out of front for %d min — it may start itself again",
                  name, Int(Self.heldCallRelease / 60))
        }
        self.eventInProgress = eventInProgress
    }

    private func noteCalendarAttempt(_ eventID: String) {
        calendarAttempts[eventID, default: 0] += 1
        ticksSinceCalendarAttempt = 0
    }
}
