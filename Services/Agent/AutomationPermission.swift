import Foundation
import CoreServices

/// What macOS says about MetaWhisp sending Apple Events to another app
/// (ITER-074 §9). Checked before any event is sent, so a refusal never costs
/// the user a half-finished errand.
enum AutomationPermission: Equatable {
    case allowed
    /// macOS would have to ask the user first (−1744).
    case needsConsent
    /// The user said no, or took the permission back later (−1743).
    case denied
    /// The target app is not running (−600).
    case targetNotRunning
    /// Anything else, kept with its status so the log shows what happened.
    case failed(OSStatus)

    /// Maps the raw `AEDeterminePermissionToAutomateTarget` status onto the
    /// outcome callers act on (ITER-074 §9). The status numbers are pinned by
    /// `AutomationPermissionTests`, because a wrong mapping would either send
    /// events after a refusal or never ask the user at all.
    static func classify(_ status: OSStatus) -> AutomationPermission {
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .failed(status)
        }
    }

    /// Asks macOS whether MetaWhisp may automate `bundleID` without sending
    /// that app anything. Never runs on the main thread: the SDK header says
    /// the call may block while the user is being asked for consent, and a
    /// blocked main thread would freeze the UI (ITER-074 §9).
    static func check(bundleID: String, askUserIfNeeded: Bool) async -> AutomationPermission {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded)
            return classify(status)
        }.value
    }
}
