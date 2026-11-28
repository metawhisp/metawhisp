import Foundation
import MetaWhispTrackerKit
import SwiftData

/// FEAT-0006 §9b P7 (owner, 2026-11-26) — the app no longer makes "waiting on <person>" tasks (what someone else
/// promised the user). The ones a user already has are put away once, at the first launch of this build: an open
/// task goes to Archive (restorable there), a suggestion of that kind is dropped. Done once, so a task the user
/// restores stays restored.
@MainActor
enum WaitingOnCleanup {

    static let doneKey = "waitingOnTasksArchived.v1"
    static let attemptsKey = "waitingOnTasksArchived.attempts"
    /// A store that refuses writes is tried again at the next launches, at most this many times in all.
    static let maxAttempts = 3

    /// Runs the cleanup unless it ran before; returns how many tasks went to Archive. One pass over every row: a row
    /// that fails is logged and the others still go. A store refusing writes throws; the flag stays unset until the
    /// third such launch, which gives up (every gate needs a ceiling).
    @discardableResult
    static func runOnce(service: TrackerService, defaults: UserDefaults = .standard) throws -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let attempt = defaults.integer(forKey: attemptsKey) + 1
        defaults.set(attempt, forKey: attemptsKey)
        do {
            let archived = try service.putAwayWaitingOnTasks()
            defaults.set(true, forKey: doneKey)
            return archived
        } catch {
            if attempt >= maxAttempts { defaults.set(true, forKey: doneKey) }
            throw error
        }
    }
}

extension TrackerService {

    /// Open waiting-on tasks to Archive, waiting-on suggestions dropped. Returns the number archived.
    func putAwayWaitingOnTasks() throws -> Int {
        try requireHealthy()
        let rows = try Self.freshContext(main).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            !$0.isDismissed && !$0.completed && $0.assignee != nil
        })).filter { !($0.assignee?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        var archived = 0, dropped = 0, failed = 0
        for row in rows {
            if row.effectiveStatus == "staged" {
                if TaskDrafts.drop(row.id, in: main, mutations: mutations) == .dropped { dropped += 1 } else { failed += 1 }
            } else if row.isTask {
                do {
                    try archive(taskId: row.id, by: "MetaWhisp")
                    archived += 1
                } catch {
                    failed += 1
                    NSLog("[Tracker] waiting-on task %@ not archived: %@", row.id.uuidString, error.localizedDescription)
                }
            }
        }
        NSLog("[Tracker] waiting-on tasks put away: %d archived, %d suggestions dropped, %d failed",
              archived, dropped, failed)
        // Not done while a row is left: the next launch tries again, within runOnce's ceiling (Codex review P1-1).
        if failed > 0 { throw TrackerFailure(.internalError, "\(failed) waiting-on task(s) were not put away.") }
        return archived
    }
}
