import Foundation
import SwiftData

/// FEAT-0006 §9b (owner, 2026-11-26: projects and tasks are one) — the one rule for a task's project. The board, the
/// list, the Projects cards and a project's page all read it, so a task is in the same project wherever it shows.
///
/// A task's project is its tracker record's project when the record has one that still exists; else the project of
/// the conversation it came from (that conversation's `primaryProject`, by its name or one of its spellings). Before
/// this, the board read only the record and Projects only the conversation: a call's task showed "no project" on the
/// board and counted under its project in Projects.
enum TaskProjects {

    /// Every task that has a project, mapped to the project's id (`ProjectAlias.id`). Tasks of no project are absent.
    static func map(main: ModelContext, tracker: ModelContext?) -> [UUID: UUID] {
        let projects = (try? main.fetch(FetchDescriptor<ProjectAlias>())) ?? []
        guard !projects.isEmpty else { return [:] }
        let existing = Set(projects.map(\.id))
        let byName = nameIndex(projects).mapValues(\.id)

        var result: [UUID: UUID] = [:]

        // The conversation's project, for tasks that came from one.
        var conversations = FetchDescriptor<Conversation>(predicate: #Predicate { !$0.discarded && $0.primaryProject != nil })
        conversations.propertiesToFetch = [\.id, \.primaryProject]
        var projectOfConversation: [UUID: UUID] = [:]
        for c in (try? main.fetch(conversations)) ?? [] {
            if let name = c.primaryProject?.lowercased(), let id = byName[name] { projectOfConversation[c.id] = id }
        }
        if !projectOfConversation.isEmpty {
            var tasks = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.conversationId != nil })
            tasks.propertiesToFetch = [\.id, \.conversationId]
            for t in (try? main.fetch(tasks)) ?? [] {
                if let cid = t.conversationId, let id = projectOfConversation[cid] { result[t.id] = id }
            }
        }

        // The record's project wins: the user or an agent put the task there. (Deleting a project clears its records'
        // project, so their tasks go back to their conversation's project, or to none.)
        for r in (try? tracker?.fetch(FetchDescriptor<TaskTrackerRecord>())) ?? [] {
            if let id = r.projectId, existing.contains(id) { result[r.taskId] = id }
        }
        return result
    }

    /// Which project a name points to, lower-cased: a project's own name first, then its spellings; a spelling never
    /// takes a name another project already holds. The one index the board and the Projects list both read, so a
    /// conversation and its tasks never land in two different projects (review 2026-11-27, #9).
    static func nameIndex(_ projects: [ProjectAlias]) -> [String: ProjectAlias] {
        var index: [String: ProjectAlias] = [:]
        for p in projects.sorted(by: { $0.createdAt < $1.createdAt }) {
            index[p.canonicalName.lowercased()] = index[p.canonicalName.lowercased()] ?? p
        }
        for p in projects.sorted(by: { $0.createdAt < $1.createdAt }) {
            for spelling in p.aliases where index[spelling.lowercased()] == nil { index[spelling.lowercased()] = p }
        }
        return index
    }
}
