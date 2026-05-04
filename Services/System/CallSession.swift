import Foundation

/// In-memory state for the *current* detected call session. Replaces the
/// scattered `didAutoStartRecording` / `autoRecordCountdownTask` /
/// `lastCallContext` flags with one source of truth.
///
/// Lifecycle (driven by `CallSessionMachine`):
///   - `onDetect(name)` fires when window-title detection sees a call app.
///     First detect of a name → fire notify, optionally arm countdown.
///     Re-detect of the same name → suppress (dedup).
///     Detect of a different name (Zoom → Teams) → close old, start new.
///   - `onUserStopped()` flips `userDeclinedRecording=true`. Subsequent
///     re-detects of the SAME session won't re-announce or re-arm a countdown.
///   - `onSessionEnd()` clears the session entirely. Called by the 180s
///     callContext-nil debounce. After clear, the next detect of the same
///     name is treated as a brand-new call.
struct CallSession: Equatable {
    let name: String
    var didAnnounce: Bool
    var userDeclinedRecording: Bool
}

/// What the caller (AppDelegate.handleCallContext) should do after running
/// the state-machine on a detect event.
enum CallSessionDecision: Equatable {
    /// Fire `postCallDetected` notification. `armCountdown` says whether to
    /// also start the 5s auto-record countdown (driven by `callsAutoStartEnabled`
    /// AND `!userDeclinedRecording`).
    case fireNotify(name: String, armCountdown: Bool)
    /// Already announced this session — do nothing.
    case suppressDuplicate
    /// User stopped recording mid-session — block any further start attempts
    /// for this session.
    case suppressBecauseDeclined
}

enum CallSessionMachine {
    /// Decide what to do on a callContext detect event.
    /// - Same name as current session + not declined → suppressDuplicate.
    /// - Same name + declined → suppressBecauseDeclined.
    /// - Different name OR no current session → new session, fire notify.
    static func onDetect(
        name: String,
        current: CallSession?,
        autoStartEnabled: Bool
    ) -> (session: CallSession, decision: CallSessionDecision) {
        if let cur = current, cur.name == name {
            if cur.userDeclinedRecording {
                return (cur, .suppressBecauseDeclined)
            }
            return (cur, .suppressDuplicate)
        }
        // New call session.
        let new = CallSession(
            name: name,
            didAnnounce: true,
            userDeclinedRecording: false
        )
        return (new, .fireNotify(name: name, armCountdown: autoStartEnabled))
    }

    /// Mark "user explicitly stopped recording for this call". The session
    /// stays alive (so re-detects of same name still hit suppress paths)
    /// until the 180s nil-debounce clears it via `onSessionEnd`.
    static func onUserStopped(_ session: CallSession?) -> CallSession? {
        guard var s = session else { return nil }
        s.userDeclinedRecording = true
        return s
    }

    /// Clear the session (after 180s nil-debounce expires). Next detect of
    /// the same name will be treated as a brand-new call.
    static func onSessionEnd(_ session: CallSession?) -> CallSession? {
        return nil
    }
}
