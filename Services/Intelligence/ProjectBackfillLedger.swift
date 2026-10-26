import Foundation

/// ITER-075 step 1 (1.6) — the conversations the project backfill has already
/// checked, kept on disk so a launch doesn't send the same 200 conversations to
/// the LLM again (a 5.5-minute pass at every launch before).
///
/// A conversation is marked only when its run wrote a result or found nothing
/// to change (Codex review F10). One that got no answer is tried again at the
/// next launch.
struct ProjectBackfillLedger {
    let fileURL: URL
    private(set) var checked: Set<UUID>

    /// `<support folder>/project-backfill-checked.json`.
    static func fileURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("project-backfill-checked.json")
    }

    /// No list yet starts empty. An unreadable one also starts empty, but is
    /// moved aside for a look rather than overwritten by the next save.
    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            checked = []
            return
        }
        do {
            checked = try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: fileURL))
        } catch {
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("[ProjectBackfill] the checked list could not be read (%@) — moved aside to %@",
                  error.localizedDescription, aside.lastPathComponent)
            checked = []
        }
    }

    /// The first `limit` rows not yet checked, in the order given. Checked rows
    /// are dropped before the limit is taken, so older rows are reached.
    static func pending<Row>(_ rows: [Row], id: (Row) -> UUID, checked: Set<UUID>, limit: Int) -> [Row] {
        Array(rows.filter { !checked.contains(id($0)) }.prefix(limit))
    }

    static func marksChecked(_ outcome: StructuredOutcome) -> Bool {
        outcome == .written || outcome == .unchanged
    }

    /// Marks the conversation and saves the list when the outcome counts.
    mutating func record(_ id: UUID, outcome: StructuredOutcome) throws {
        guard Self.marksChecked(outcome) else { return }
        checked.insert(id)
        try save()
    }

    /// Marks conversations without a run: the owner took their project away,
    /// and the backfill must not give it back.
    mutating func mark(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        checked.formUnion(ids)
        try save()
    }

    /// Marks only ever grow, so the list on disk is merged in first: another
    /// writer's marks (a project deleted during a pass) are never lost.
    private mutating func save() throws {
        if let data = try? Data(contentsOf: fileURL),
           let onDisk = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            checked.formUnion(onDisk)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(checked).write(to: fileURL, options: .atomic)
    }
}
