import Foundation

/// Every finished errand, kept as one JSON file of its own (ITER-074 §5,
/// `AgentRecordStore`): its record, its outcome and where it was asked for,
/// under `Application Support/MetaWhisp/Agent/`, written atomically. A plain
/// file like `ExtractionQueueStore`'s — no SwiftData schema to migrate.
///
/// B2c (Codex round 2, P1-3) — owner-only on disk:
/// - the `Agent` folder itself is 0700 (rwx------) so other accounts on the
///   Mac cannot list it,
/// - every record file is 0600 (rw-------) so other accounts cannot read
///   what the user asked MetaChat to do,
/// - at most `maxRecords` (100) are kept; the oldest beyond that are deleted
///   after every save (by modification date),
/// - any record older than `maxAge` (30 days) is deleted after every save.
/// `deleteAll()` clears every record; `ChatService.clearHistory` reaches
/// this store through `AgentService.shared.deleteAllRecords()` — there is
/// no second store for the app.
@MainActor
final class ErrandRecordStore {
    /// What one file holds.
    struct Saved: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let origin: ErrandOrigin
        let record: ErrandRecord
        let outcome: ErrandOutcome
    }

    /// Hard caps the store enforces after every save.
    static let maxRecords = 100
    /// 30 days, in seconds. Records older than this are removed on save.
    static let maxAge: TimeInterval = 30 * 86_400

    let directory: URL

    /// `directory`: for tests; the app's `Agent` folder otherwise.
    init(directory: URL? = nil) {
        self.directory = directory ?? AppIdentity.current.supportDirectory
            .appendingPathComponent("Agent", isDirectory: true)
    }

    /// `<directory>/<errand id>.json`.
    func fileURL(for errandID: UUID) -> URL {
        directory.appendingPathComponent("\(errandID.uuidString).json")
    }

    /// Keeps errand `id`'s file, whatever id its record carries — the file is
    /// the service's errand's. False when the file could not be written. That
    /// is logged by its error code — never the goal, a row or an answer — and
    /// the errand goes on. After the write, the folder and the new file get
    /// owner-only permissions, and stale records are pruned.
    @discardableResult
    func save(id: UUID, origin: ErrandOrigin, record: ErrandRecord, outcome: ErrandOutcome) -> Bool {
        do {
            try ensureDirectory()
            let saved = Saved(version: Saved.currentVersion, origin: origin, record: record, outcome: outcome)
            let fileURL = fileURL(for: id)
            try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
            // `.atomic` writes a fresh inode under the default umask (0644);
            // re-apply owner-only on every save so a copied-in file keeps the
            // right mode.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: fileURL.path)
            pruneOldRecords()
            return true
        } catch {
            NSLog("[ErrandRecordStore] ❌ errand %@ not saved — error %d", id.uuidString.prefix(8) as CVarArg,
                  (error as NSError).code)
            return false
        }
    }

    /// What was kept of errand `id`; nil when nothing was, or it cannot be
    /// read (ITER-076 I-05, review round 2).
    func load(id: UUID) -> Saved? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// The errands kept as they were admitted and never ended — their record
    /// has no ending (ITER-076 stage 9d, № 21): a crash, a Force Quit or a
    /// power loss left them so. Every other save ends its record first.
    func unended() -> [(id: UUID, saved: Saved)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let saved = load(id: id), saved.record.ending == nil else { return nil }
            return (id, saved)
        }
    }

    /// Removes every record file under `directory`. `ChatService.clearHistory`
    /// reaches this through `AgentService.shared.deleteAllRecords()`. The
    /// folder itself stays — the app will write the next errand into it.
    func deleteAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Internal: permissions + pruning

    /// Creates the directory with owner-only permissions if missing, and
    /// re-asserts 0700 if it already existed — a pre-existing / copied-in /
    /// beta-installed directory may have been chmod 0755 in the past.
    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Drops records past the cap (100) by modification date, then any record
    /// older than `maxAge` (30 days). Run after every successful save.
    private func pruneOldRecords() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var dated: [(url: URL, modified: Date)] = []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            dated.append((file, modified))
        }
        // Stale first — older than 30 days, no matter how many we keep overall.
        for entry in dated where entry.modified < cutoff {
            try? fm.removeItem(at: entry.url)
        }
        let survivors = dated.filter { $0.modified >= cutoff }
            .sorted { $0.modified < $1.modified }
        if survivors.count > Self.maxRecords {
            for entry in survivors.prefix(survivors.count - Self.maxRecords) {
                try? fm.removeItem(at: entry.url)
            }
        }
    }
}
