import Foundation

/// Preserves an unopenable SwiftData store so a failed open never silently loses
/// the user's data (AUD-007 / ITER-049 A1).
///
/// On store-open failure we COPY — never move — the `.store` and its `-wal` /
/// `-shm` sidecars to a timestamped sibling directory, leaving the originals
/// exactly where they are for later recovery. A WAL store is only consistent
/// with its sidecars, so all three must travel together.
enum StoreBackup {

    /// Copy the store + present WAL sidecars to `<store>.unopenable-<ts>/`.
    /// All-or-nothing: returns the backup directory only when the main store AND
    /// every sidecar that exists on disk copied successfully — a WAL store is
    /// only consistent with its sidecars, so a partial copy must not be passed
    /// off as a preserved backup. Returns nil (and removes the partial dir) when
    /// the store is absent or any present file fails to copy. Originals are never
    /// modified or removed, so they remain the source of truth on failure.
    @discardableResult
    static func preserveUnopenableStore(
        storeURL: URL,
        now: Date,
        fileManager: FileManager = .default
    ) -> URL? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        // Uniquify so two preserves within the same second don't reuse a dir —
        // reusing it would make copyItem fail on existing files and the cleanup
        // below would then delete the EARLIER good backup.
        let parent = storeURL.deletingLastPathComponent()
        let baseName = "\(storeURL.lastPathComponent).unopenable-\(timestamp(now))"
        var backupDir = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: backupDir.path) {
            backupDir = parent.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var copiedMain = false
        var allComplete = true
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }   // missing sidecar is fine
            let dst = backupDir.appendingPathComponent(src.lastPathComponent)
            do {
                try fileManager.copyItem(at: src, to: dst)
                if suffix.isEmpty { copiedMain = true }
            } catch {
                allComplete = false   // a file that EXISTS on disk failed to copy → backup is partial
            }
        }
        guard copiedMain, allComplete else {
            try? fileManager.removeItem(at: backupDir)   // don't leave a misleading partial copy
            return nil
        }
        return backupDir
    }

    private static func timestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: date)
    }
}
