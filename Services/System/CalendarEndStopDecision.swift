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
    /// Both strong signals say meeting is ongoing (audio active AND a call
    /// seen by the call detector). Extend the deadline silently — no
    /// user-facing card.
    /// ITER-035-followup (2026-05-12): the previous behavior pushed a
    /// «RECORDING STOPPED · Meeting overrunning» card here, which was both
    /// misleading (recording was NOT stopped) and noisy (fires within
    /// minutes of recording start if the calendar event was short).
    case silentExtend(newDeadline: Date)
    /// Past endDate + grace, ONE positive signal but not both, and it is the
    /// recording's one real question: audio on, no call seen, no card yet →
    /// push a user-facing «still recording» card, count the round, and
    /// re-check at `newDeadline`.
    case notifyAndExtend(newDeadline: Date)
    /// Past endDate + grace, ONE positive signal but not both, and nothing to
    /// ask: the card was already shown this recording, a call was seen, or
    /// the room is quiet → count the round toward `hardStop` and re-check at
    /// `newDeadline`, with no card. 2026-10-20: every such round pushed a
    /// card — six that day, one every five minutes, all timed out untapped.
    case extendWithoutCard(newDeadline: Date)
    /// Too many uncertain rounds have passed and the room is quiet → force
    /// stop to prevent indefinite recording (e.g. someone left mic on
    /// overnight after a long-running music session).
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
    /// A call the detector saw this recently still counts as on. One re-check
    /// interval: a call seen at any point since the previous check counts.
    static let defaultCallSeenWithinSeconds: TimeInterval = 300
    static let defaultQuietRMSThreshold: Float = 0.005
    static let defaultMaxNotifyAttempts: Int = 3
}

extension CalendarEndStopDecision {
    /// - Parameters:
    ///   - now: caller-provided clock (for tests). Production passes `Date()`.
    ///   - eventEnd: `EKEvent.endDate` snapshot from the moment the
    ///     recording started. Stale if user edits the calendar mid-record;
    ///     acceptable trade-off for simplicity.
    ///   - audioRMSLastNSec: instantaneous RMS sample at fire time. Used as
    ///     a fast quiet-check, BUT it can be false-positive during the
    ///     200-500ms pauses between sentences. The sliding-window guard
    ///     `recentAudioActive` (below) is the authoritative signal for
    ///     "someone is still talking."
    ///   - notifyAttemptsSoFar: uncertain rounds so far — caller increments
    ///     after each `notifyAndExtend` AND each `extendWithoutCard`. The name
    ///     is from when every such round pushed the card; since 2026-10-20 at
    ///     most one does, and the count still drives `hardStop` as before.
    ///   - recentAudioActive: ITER-034.1 (2026-05-11) — true iff audio
    ///     crossed the silence threshold within the last sliding window
    ///     (caller usually 30s). When true, we never `.stopNow` — at worst
    ///     we extend. Closes the bug where a single quiet
    ///     instant between sentences killed an ongoing meeting.
    ///   - lastCallSeenAt: when the call detector (`ScreenContextService`
    ///     running `SystemAudioCaptureService.detectCallContext`) last saw a
    ///     call in front; nil when it never did. A sighting within
    ///     `callSeenWithinSeconds` means a call is on. ITER-034.1's
    ///     user-requested signal: "if the meeting is still open on my screen,
    ///     don't stop it just because there was silence" — so a call seen
    ///     blocks `.stopNow` same as `recentAudioActive`. 2026-10-20: this was
    ///     a second probe over the screen captures of the last 60 s, with its
    ///     own app list (no Dia). Five of the day's six overrun cards fired
    ///     with no capture in that minute, three of them while the detector
    ///     held «Google Meet (app=Dia)». One source answers "is a call on"
    ///     now: the detector's.
    ///   - overrunCardShown: whether this recording already pushed the
    ///     «still recording» card. Ask once: with audio on the recording
    ///     continues whether or not the card is tapped, so a second card asks
    ///     nothing new. What ends a recording past this point is audio going
    ///     quiet — `stopNow`, or `hardStop` once the budget is spent.
    ///   - graceSeconds: grace period after `eventEnd` before any stop
    ///     decision. Default 60s — covers the common "couple of minutes
    ///     to wrap up" overrun.
    ///   - extensionSeconds: how far ahead to push the next deadline on
    ///     `notifyAndExtend`. Default 300s = 5 min.
    ///   - callSeenWithinSeconds: how recent a sighting still counts.
    ///     Default 300s = one re-check interval.
    ///   - quietRMSThreshold: RMS below this counts as "no one talking".
    ///     Default 0.005 ≈ background room noise.
    ///   - maxNotifyAttempts: after this many uncertain rounds
    ///     (`notifyAndExtend` or `extendWithoutCard`), `hardStop` instead once
    ///     the room is quiet. Prevents infinite recording.
    static func evaluate(
        now: Date,
        eventEnd: Date,
        audioRMSLastNSec: Float,
        notifyAttemptsSoFar: Int,
        recentAudioActive: Bool = false,
        lastCallSeenAt: Date? = nil,
        overrunCardShown: Bool = false,
        graceSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultGraceSeconds,
        extensionSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultExtensionSeconds,
        callSeenWithinSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultCallSeenWithinSeconds,
        quietRMSThreshold: Float = CalendarEndStopDecisionRules.defaultQuietRMSThreshold,
        maxNotifyAttempts: Int = CalendarEndStopDecisionRules.defaultMaxNotifyAttempts
    ) -> CalendarEndStopDecision {
        // Inside event OR within grace window → keep going.
        let secondsPastEnd = now.timeIntervalSince(eventEnd)
        if secondsPastEnd < graceSeconds { return .keepRunning }

        let callSeen = lastCallSeenAt.map { now.timeIntervalSince($0) <= callSeenWithinSeconds } ?? false

        // Past grace + exhausted notify budget → force stop, UNLESS audio is
        // currently active. 2026-05-15 bug: user's Google-Meet-in-Chrome call
        // ran for 46 min and got hard-stopped at the 3rd notify because the
        // meeting-app probe doesn't recognize browser-tab meetings. Audio
        // was loud the entire time (RMS 0.099-1.0). Real-life recording
        // shouldn't get killed when there's clearly still conversation.
        // The safety valve fires ONLY when room is genuinely quiet.
        // (That probe was replaced by the call detector on 2026-10-20.)
        if notifyAttemptsSoFar >= maxNotifyAttempts && !recentAudioActive {
            return .hardStop
        }
        // Audio still active after 3 uncertain rounds — extend silently
        // rather than killing the recording; the recorder keeps capturing.
        if notifyAttemptsSoFar >= maxNotifyAttempts {
            return .silentExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
        }

        // ITER-034.1 — sliding-window guards. A single quiet sample is NOT
        // enough evidence the meeting is over. We need EITHER:
        //   • audio continuously quiet for the caller's sliding window, OR
        //   • no call seen by the detector within `callSeenWithinSeconds`.
        // Either positive signal → don't stop. Both → silent extend.

        // Past grace, audio quiet, and no positive "still going" signal → stop.
        if audioRMSLastNSec < quietRMSThreshold && !recentAudioActive && !callSeen {
            return .stopNow
        }

        // ITER-035-followup (2026-05-12) — both strong signals say meeting is
        // ongoing → silent extension, no user card. Avoids the «RECORDING
        // STOPPED · Meeting overrunning» false-alarm card the user reported
        // hitting after only ~5 minutes of recording.
        if recentAudioActive && callSeen {
            return .silentExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
        }

        // One positive signal — uncertain; re-check later either way. Ask the
        // user only when it is a real choice: someone is talking, no call has
        // been on screen, and this recording has not asked yet. Everything
        // else extends without a card and still counts toward `hardStop`.
        let deadline = now.addingTimeInterval(extensionSeconds)
        if recentAudioActive && !callSeen && !overrunCardShown {
            return .notifyAndExtend(newDeadline: deadline)
        }
        return .extendWithoutCard(newDeadline: deadline)
    }
}
