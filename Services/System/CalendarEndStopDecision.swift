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
    /// Both strong signals say meeting is ongoing (audio active AND meeting
    /// app visible). Extend the deadline silently — no user-facing card.
    /// ITER-035-followup (2026-05-12): the previous behavior pushed a
    /// «RECORDING STOPPED · Meeting overrunning» card here, which was both
    /// misleading (recording was NOT stopped) and noisy (fires within
    /// minutes of recording start if the calendar event was short).
    case silentExtend(newDeadline: Date)
    /// Past endDate + grace, ONE positive signal but not both → push a
    /// user-facing «still recording» card and re-check at `newDeadline`.
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
    ///   - audioRMSLastNSec: instantaneous RMS sample at fire time. Used as
    ///     a fast quiet-check, BUT it can be false-positive during the
    ///     200-500ms pauses between sentences. The sliding-window guard
    ///     `recentAudioActive` (below) is the authoritative signal for
    ///     "someone is still talking."
    ///   - notifyAttemptsSoFar: how many times we've already pushed the
    ///     "meeting overrunning — tap to stop" card. Caller increments
    ///     after each `notifyAndExtend`.
    ///   - recentAudioActive: ITER-034.1 (2026-05-11) — true iff audio
    ///     crossed the silence threshold within the last sliding window
    ///     (caller usually 30s). When true, we never `.stopNow` — at worst
    ///     we `.notifyAndExtend`. Closes the bug where a single quiet
    ///     instant between sentences killed an ongoing meeting.
    ///   - meetingAppVisible: ITER-034.1 — true iff a recognized meeting
    ///     app (Zoom / Meet / Teams / Discord / FaceTime / Webex / etc) was
    ///     foreground in the recent ScreenContext window. User-requested
    ///     signal: "if the meeting is still open on my screen, don't stop
    ///     it just because there was silence." When true, blocks `.stopNow`
    ///     same as `recentAudioActive`.
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
        recentAudioActive: Bool = false,
        meetingAppVisible: Bool = false,
        graceSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultGraceSeconds,
        extensionSeconds: TimeInterval = CalendarEndStopDecisionRules.defaultExtensionSeconds,
        quietRMSThreshold: Float = CalendarEndStopDecisionRules.defaultQuietRMSThreshold,
        maxNotifyAttempts: Int = CalendarEndStopDecisionRules.defaultMaxNotifyAttempts
    ) -> CalendarEndStopDecision {
        // Inside event OR within grace window → keep going.
        let secondsPastEnd = now.timeIntervalSince(eventEnd)
        if secondsPastEnd < graceSeconds { return .keepRunning }

        // Past grace + exhausted notify budget → force stop, UNLESS audio is
        // currently active. 2026-05-15 bug: user's Google-Meet-in-Chrome call
        // ran for 46 min and got hard-stopped at the 3rd notify because the
        // meeting-app probe doesn't recognize browser-tab meetings. Audio
        // was loud the entire time (RMS 0.099-1.0). Real-life recording
        // shouldn't get killed when there's clearly still conversation.
        // The safety valve fires ONLY when room is genuinely quiet.
        if notifyAttemptsSoFar >= maxNotifyAttempts && !recentAudioActive {
            return .hardStop
        }
        // Audio still active after 3 notifies — extend silently rather than
        // killing the recording. User will get a final card every 5 min if
        // they want to stop, but the recorder keeps capturing.
        if notifyAttemptsSoFar >= maxNotifyAttempts {
            return .silentExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
        }

        // ITER-034.1 — sliding-window guards. A single quiet sample is NOT
        // enough evidence the meeting is over. We need EITHER:
        //   • audio continuously quiet for the caller's sliding window, OR
        //   • the meeting app gone from screen recently.
        // Either positive signal → don't stop. Both → silent extend.

        // Past grace, audio quiet, and no positive "still going" signal → stop.
        if audioRMSLastNSec < quietRMSThreshold && !recentAudioActive && !meetingAppVisible {
            return .stopNow
        }

        // ITER-035-followup (2026-05-12) — both strong signals say meeting is
        // ongoing → silent extension, no user card. Avoids the «RECORDING
        // STOPPED · Meeting overrunning» false-alarm card the user reported
        // hitting after only ~5 minutes of recording.
        if recentAudioActive && meetingAppVisible {
            return .silentExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
        }

        // One positive signal — uncertain, notify the user and re-check later.
        return .notifyAndExtend(newDeadline: now.addingTimeInterval(extensionSeconds))
    }
}
