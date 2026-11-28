import Foundation
import MetaWhispTrackerKit
import SwiftData

/// Owner 2026-11-27 (Q4) — putting a project away and bringing it back. An archived project leaves the Projects grid
/// and every project picker ("+ add project", New task, the summary step's list of projects); its tasks stay in Tasks
/// with its name. It comes back when the user restores it or puts a task in it, or an agent writes in its folder.
extension TrackerService {

    func archivedProjectIds() -> Set<UUID> {
        Set(((try? Self.freshContext(tracker).fetch(FetchDescriptor<ArchivedProject>())) ?? []).map(\.projectId))
    }

    func archiveProject(_ projectId: UUID) throws {
        try requireHealthy()
        let tctx = Self.freshContext(tracker)
        guard try tctx.fetch(FetchDescriptor<ArchivedProject>(predicate: #Predicate { $0.projectId == projectId }))
            .isEmpty else { return }
        tctx.insert(ArchivedProject(projectId: projectId, archivedAt: now()))
        try tctx.save()
        revision &+= 1
    }

    func restoreProject(_ projectId: UUID) throws {
        try requireHealthy()
        let tctx = Self.freshContext(tracker)
        if try bringBack(projectId, tctx: tctx) {
            try tctx.save()
            revision &+= 1
        }
    }

    /// Takes the project out of the archive in `tctx` (the caller saves). True when it was archived.
    @discardableResult
    func bringBack(_ projectId: UUID, tctx: ModelContext) throws -> Bool {
        let rows = try tctx.fetch(FetchDescriptor<ArchivedProject>(predicate: #Predicate { $0.projectId == projectId }))
        rows.forEach(tctx.delete)
        return !rows.isEmpty
    }
}
