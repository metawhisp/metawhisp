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

/// Process-wide store-health signal for components that can't reach the
/// `HistoryService` instance directly — specifically the `MutationService.shared`
/// and `MCPSnapshotService.shared` singletons, whose post-commit hooks write
/// EXTERNAL files (Obsidian vault, `mcp-snapshot.json`). Set once by HistoryService
/// at init; defaults healthy. Thread-safe so any actor can read it.
final class StoreHealthSignal: @unchecked Sendable {
    static let shared = StoreHealthSignal()
    private let lock = NSLock()
    private var _healthy = true

    private init() {}

    var isHealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        return _healthy
    }

    func set(healthy: Bool) {
        lock.lock(); _healthy = healthy; lock.unlock()
    }
}
