import AppKit
import Foundation
import ServiceManagement

/// Manages the app's launch-at-login status via `SMAppService.mainApp` (macOS 13+).
///
/// Single source of truth — we deliberately do NOT mirror the on/off flag into
/// `@AppStorage`. The system can flip the registration from System Settings →
/// General → Login Items, and a local mirror would silently drift from reality.
/// The view binds to `isEnabled` directly; tapping the toggle calls
/// `setEnabled(_:)` which round-trips through `SMAppService` and re-reads the
/// status, so UI stays consistent with the system.
///
/// Pattern copied from reference desktop client (`LaunchAtLoginManager.swift`,
/// 63 lines) verbatim, only adapting `log()` → `NSLog`.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDescription: String = "Checking..."

    /// Token for `didBecomeActiveNotification` observer. Held to prevent the
    /// observer from being garbage-collected (singleton never deinits, but
    /// storing the token is the documented pattern).
    private var didBecomeActiveObserver: NSObjectProtocol?

    private init() {
        updateStatus()
        // CC-13: the user can flip the Login Item registration from System
        // Settings → General → Login Items while our app is in the background.
        // When we re-foreground, re-read SMAppService status so the toggle in
        // Settings reflects reality instead of our last cached value.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor explicitly — NotificationCenter's closure is
            // @Sendable, our updateStatus() is MainActor-isolated.
            Task { @MainActor [weak self] in
                self?.updateStatus()
            }
        }
    }

    /// Reads the current registration status from `SMAppService` off the main
    /// thread, then publishes the result back. Call on app launch and after
    /// every `setEnabled(_:)` so a System-Settings-driven change is reflected.
    func updateStatus() {
        Task.detached {
            let status = SMAppService.mainApp.status
            let enabled = status == .enabled
            let description: String
            switch status {
            case .enabled:
                description = "MetaWhisp will start when you log in"
            case .notRegistered:
                description = "MetaWhisp won't start automatically"
            case .notFound:
                description = "Login item not found"
            case .requiresApproval:
                description = "Requires approval in System Settings → General → Login Items"
            @unknown default:
                description = "Unknown status"
            }
            await MainActor.run {
                self.isEnabled = enabled
                self.statusDescription = description
            }
        }
    }

    /// Register or unregister the main app as a login item.
    ///
    /// - Returns: `true` on success. On failure logs the system error and
    ///   re-reads status so the UI snaps back to whatever the system actually
    ///   thinks (avoids stale "ON" toggle when registration silently failed).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                NSLog("[LaunchAtLogin] registered for login")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("[LaunchAtLogin] unregistered from login")
            }
            updateStatus()
            return true
        } catch {
            NSLog("[LaunchAtLogin] failed to %@: %@",
                  enabled ? "register" : "unregister",
                  error.localizedDescription)
            updateStatus()
            return false
        }
    }
}
