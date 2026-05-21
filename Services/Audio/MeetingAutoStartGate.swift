import AppKit
import Combine
import Foundation

/// Decides if a detected call should auto-start recording.
///
/// Replaces the old "first detect → 5s countdown → start" path which fired on
/// any single screen-context tick that matched a call pattern (false-positive
/// example: opening a Meet link to check it for 5 seconds triggered a full
/// recording). User explicit feedback 2026-05-02:
///
/// - **Strong path — calendar:** if a non-allday calendar event is starting
///   right now (within ±5 min of `now`), auto-start fires immediately on the
///   event boundary regardless of how long the call window has been visible.
/// - **Weak path — fallback:** call window must be FRONTMOST, FULLSCREEN, and
///   have AUDIO ACTIVITY for 10 seconds STRAIGHT before we even propose
///   auto-starting. Once that 10-sec sustained signal is reached, the caller
///   shows a 5-sec countdown plashka and finally a 2-sec audio sniff before
///   actually starting the recording.
///
/// The gate is a pure state holder — the AppDelegate runs a 1-second tick
/// loop that calls `evaluate(...)` with current signals. Gate returns one of
/// `Decision` cases; AppDelegate acts on it.
///
/// spec://iterations/ITER-026-v2-meeting-auto-start
@MainActor
final class MeetingAutoStartGate {
    static let shared = MeetingAutoStartGate()

    /// User explicit spec — 10 sec of sustained `frontmost + fullscreen + audio`.
    private let sustainedSecondsRequired: Int = 10

    /// Calendar look-ahead window — events starting within next 5 min counted.
    private let calendarLookaheadSeconds: TimeInterval = 5 * 60

    /// Sliding 10-sec audio history. Each tick we append `audioActive` (bool).
    /// Gate fires when ≥ 8 of last 10 ticks are active — covers normal speech
    /// pauses (breath, "uh-uh", brief silence between sentences) without
    /// requiring uninterrupted speech.
    private var audioHistory: [Bool] = []

    /// Counter for "frontmost + fullscreen sustained" — reset on any signal drop.
    private var fullscreenStreak: Int = 0

    /// Snapshot of the call name we've been tracking so the consumer knows
    /// what to start ("Google Meet" / "Zoom" / etc).
    private var currentCallName: String?

    /// Set when `decideStrongCalendar` already fired for this event so the
    /// next tick doesn't double-fire on the same calendar boundary.
    private var lastCalendarEventID: String?

    private init() {}

    /// Reset all internal state. Call when caller knows the gate should
    /// forget everything (e.g. recording started, user manually declined,
    /// session reset).
    func reset() {
        audioHistory.removeAll()
        fullscreenStreak = 0
        currentCallName = nil
    }

    /// What the caller should do this tick.
    enum Decision {
        /// No call signal at all — nothing to do.
        case idle
        /// Signal present but not yet sustained — keep monitoring.
        case tracking(name: String, secondsLeft: Int)
        /// 10-sec sustained signal reached. Caller should show plashka and
        /// run countdown + audio-sniff before starting recording.
        case fallbackReady(name: String)
        /// A calendar event JUST became active. Caller should show plashka
        /// immediately for THAT event regardless of fallback state.
        case calendarReady(name: String, eventID: String)
    }

    /// Called every ~1 second by the AppDelegate fast-tick loop.
    ///
    /// - parameter callName: name returned by `SystemAudioCaptureService.detectCallContext`
    ///   for the FRONTMOST window only. nil if the user isn't looking at a
    ///   call window right now.
    /// - parameter isFullscreen: whether the frontmost window covers the
    ///   entire screen (no menu bar / dock visible).
    /// - parameter audioActive: any audio (mic OR system) above the speech
    ///   threshold during the last second.
    /// - parameter calendarEventNow: any non-allday EKEvent whose
    ///   `startDate <= now <= startDate + 30s` (just-fired). Caller resolves.
    func evaluate(
        callName: String?,
        isFullscreen: Bool,
        audioActive: Bool,
        calendarEventNow: (id: String, title: String)?
    ) -> Decision {
        // Calendar trumps everything. Fire once per event.
        if let ev = calendarEventNow, ev.id != lastCalendarEventID {
            lastCalendarEventID = ev.id
            // Caller will show plashka for THIS event, run countdown + sniff.
            return .calendarReady(name: ev.title, eventID: ev.id)
        }

        // No call window in front + no audio history → idle.
        guard let name = callName else {
            // Reset the streak immediately when call window disappears.
            // Audio history we don't reset — it's a sliding window already.
            fullscreenStreak = 0
            currentCallName = nil
            audioHistory.append(audioActive)
            trimAudioHistory()
            return .idle
        }

        // Track current call name. If it changed mid-stream (rare — would mean
        // user opened a different Meet room) reset the streak.
        if currentCallName != name {
            currentCallName = name
            fullscreenStreak = 0
            audioHistory.removeAll()
        }

        // Append this tick's audio sample.
        audioHistory.append(audioActive)
        trimAudioHistory()

        // ITER-002 — fullscreen-OR-call-app rule. Native call apps
        // (Zoom / Teams / FaceTime / Meet etc.) are sufficient signal that
        // a real call is happening REGARDLESS of window size — Zoom's
        // default "floating video window" is a small PiP that's frontmost
        // but NOT fullscreen (user report 2026-05-15: «я на созвоне в зуме,
        // запись не началась»). Before this change the streak only advanced
        // when the window was fullscreen, so PiP-style calls never crossed
        // the 10s threshold. The browser-tab cases (Meet/Teams in a browser
        // tab) still need fullscreen because a background browser tab is a
        // common false-positive source.
        //
        // `SystemAudioCaptureService.detectCallContext` only returns a
        // non-nil `callName` when the frontmost window is already filtered
        // for legitimate call indicators (always-call bundles, dual-mode
        // with Huddle/VoiceConnected suffix, or browser+call-keyword
        // matches). So `callName != nil` AND user is FRONTMOST is enough
        // confidence to start the streak.
        if isFullscreen || isNativeCallApp(name) {
            fullscreenStreak += 1
        } else {
            fullscreenStreak = 0
        }

        // 2026-05-15 — audio requirement REMOVED from fallback fire.
        // Before this change the gate required BOTH
        // `fullscreenStreak >= 10` AND `speechSustained` (≥80% of last 10
        // ticks with audioActive). But the caller in `AppDelegate.swift`
        // (`startMeetingAutoStartTickLoop`) hardcodes `audioActive: false`
        // because it can't probe system audio without a running recorder.
        // Net effect: `speechSustained` was ALWAYS false → fallback fire
        // NEVER triggered → recording only started via `.calendarReady`
        // (calendar event). User without a calendar event was silently
        // missed (today's report: «на созвоне в зуме, запись не началась»).
        //
        // Safety: `detectCallContext` already filters strictly upstream
        // (always-call bundles, Huddle/VoiceConnected suffixes, or
        // browser+call-keyword matches). 10 seconds of sustained
        // frontmost-OR-native-call-app is sufficient confidence; the audio
        // sniff was a vestige of an earlier design where the gate ran
        // before window-fullscreen-OR-native check was added.
        if fullscreenStreak >= sustainedSecondsRequired {
            let finalName = name
            audioHistory.removeAll()
            fullscreenStreak = 0
            currentCallName = nil
            return .fallbackReady(name: finalName)
        }

        let secondsLeft = max(0, sustainedSecondsRequired - fullscreenStreak)
        return .tracking(name: name, secondsLeft: secondsLeft)
    }

    /// Keep last 10 ticks (matches `sustainedSecondsRequired`).
    private func trimAudioHistory() {
        while audioHistory.count > sustainedSecondsRequired {
            audioHistory.removeFirst()
        }
    }

    /// Native call apps that mean «definitely in a call» whenever they're
    /// frontmost, regardless of window state (fullscreen / floating PiP /
    /// docked panel). For browser-based calls (Meet/Teams-in-tab) we still
    /// require fullscreen because a backgrounded browser tab is a common
    /// false-positive source. Matches `SystemAudioCaptureService.alwaysCallBundleIDs`
    /// + dual-mode (`com.tinyspeck.slackmacgap` Huddle, `com.discord.Discord`
    /// Voice Connected) — these already passed strict title checks upstream
    /// before producing a non-nil `callName`.
    private func isNativeCallApp(_ callName: String) -> Bool {
        switch callName {
        case "Zoom", "Teams", "FaceTime", "Webex", "GoTo Meeting",
             "Slack", "Discord":
            return true
        default:
            // "Google Meet" comes through this path too — but that's a
            // browser tab, NOT a native call app. Leave it requiring
            // fullscreen.
            return false
        }
    }
}
