import Foundation

/// ITER-075 step 0, US-0.3 — what the app does when a permission changes.
/// Plain closures, so the reactions are testable without System Settings.
@MainActor
struct PermissionReactions {
    /// Installs every global key monitor again: Right ⌘ / Right ⌥ and ⌘⌥O. A
    /// monitor installed before the grant stays dead after it otherwise.
    var rearmGlobalKeys: @MainActor () -> Void
    /// Re-runs the layout fix's start, which checks the permission itself and
    /// stops the fix on a revocation. Returns its state for the log.
    var rearmLayoutFix: @MainActor () -> String
    /// Refreshes the permission rows in Settings.
    var refreshSettings: @MainActor () -> Void
    /// Whether screen context is wired, enabled and not already running.
    var screenContextShouldStart: @MainActor () -> Bool
    var startScreenContext: @MainActor () -> Void

    func accessibility(_ change: PermissionMonitor.Change) {
        if change == .granted { rearmGlobalKeys() }
        let layout = rearmLayoutFix()
        NSLog("[PermissionReactions] Accessibility %@ — layout fix %@", change == .granted ? "granted" : "revoked", layout)
        refreshSettings()
    }

    func screenRecording(_ change: PermissionMonitor.Change) {
        refreshSettings()
        guard change == .granted, screenContextShouldStart() else { return }
        NSLog("[PermissionReactions] Screen Recording granted — restarting screen context")
        startScreenContext()
    }
}
