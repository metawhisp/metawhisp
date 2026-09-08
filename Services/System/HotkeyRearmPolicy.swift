import Foundation

/// When the global hotkey monitors have to be installed again.
///
/// macOS delivers global key events only to a trusted process, and a monitor
/// installed before the Accessibility grant does not begin working when the
/// grant arrives — it has to be installed again. `register()` installed four
/// monitors, never asked whether it was trusted, and logged "registered"
/// either way; granting permission mid-session left Right ⌘ dead until the
/// next launch (audit, 2026-09-06, P1).
///
/// Pure, so the rule is arguable without a permission dialog.
enum HotkeyRearmPolicy {

    /// The watch is a poll, so it needs an end. Granted is the ordinary one;
    /// this is the ceiling for a person who never grants it — after it, the
    /// hotkeys wait for the next launch, and the log says so.
    static let watchCeilingSeconds: Double = 600

    /// Only the moment permission ARRIVES. Re-installing monitors that already
    /// work would drop whatever keystroke is in flight, and losing permission
    /// leaves nothing to install.
    static func shouldRearm(wasTrusted: Bool, isTrusted: Bool) -> Bool {
        !wasTrusted && isTrusted
    }

    static func keepWatching(isTrusted: Bool, elapsedSeconds: Double) -> Bool {
        !isTrusted && elapsedSeconds <= watchCeilingSeconds
    }
}
