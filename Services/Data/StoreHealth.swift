import Foundation

/// Health of the persistent SwiftData store (AUD-007 / ITER-049 A1).
///
/// `.degraded` means the on-disk store could NOT be opened. The original files
/// are preserved untouched; `backupPath`, when non-nil, is a timestamped copy.
/// The app keeps running on a volatile in-memory shell until relaunch, so this
/// must be surfaced loudly — writes in this state do not persist.
enum StoreHealth: Equatable {
    case healthy
    case degraded(reason: String, backupPath: String?)

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}
