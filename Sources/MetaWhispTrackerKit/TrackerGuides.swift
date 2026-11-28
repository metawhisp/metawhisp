import Foundation

/// FEAT-0006 §6, §8 — what agents read: the workflow guides (tool, resource and CLI), the MCP handshake
/// instruction, and the block the Connect button puts into the agent's global instructions.
public enum TrackerGuides {

    public struct Guide: Equatable, Sendable {
        public let name: String
        public let title: String
        public let summary: String
        public let text: String

        public var uri: String { "metawhisp://workflow/\(name)" }
    }

    public static func guide(named name: String) -> Guide? { all.first { $0.name == name } }

    public static let all: [Guide] = [overview, creation, execution, finalization]

    public static let initializeInstructions = """
    MetaWhisp keeps the tasks and backlog of the project in your working folder. At the start of a session read \
    metawhisp://workflow/overview (or call get_metawhisp_instructions); read the matching guide before creating, \
    working on or finishing tasks.
    """

    // MARK: - Agent instructions block (Connect button)

    public static let blockStart = "<!-- METAWHISP TASKS START -->"
    public static let blockEnd = "<!-- METAWHISP TASKS END -->"
    public static let blockVersion = 1

    /// One rule in the agent's global instructions (T9).
    public static let agentBlock = """
    \(blockStart)
    <!-- metawhisp-tasks-version: \(blockVersion) -->
    ## Tasks live in MetaWhisp

    Keep every task and the backlog of the project you work in inside MetaWhisp, never in files or your own lists. \
    The project is your working folder (its repository, or the folder itself): MetaWhisp finds it by the folder, or \
    creates it named after the folder with the first task.

    - Use the `metawhisp` MCP tools: `task_list`, `task_search`, `task_view`, `task_create`, `task_edit`, \
    `task_archive`, `task_restore`.
    - At the start of a session call `get_metawhisp_instructions` (or read `metawhisp://workflow/overview`) and follow \
    it; read the matching guide before creating, starting or finishing a task.
    - When the user dictates or lists tasks, put them in MetaWhisp right away.
    - Archive what is cancelled or a duplicate. Delete forever only an archived task, only after the user said yes to \
    deleting it forever.
    \(blockEnd)
    """

    // MARK: - Guides

    static let overview = Guide(name: "overview", title: "MetaWhisp tasks: overview",
                                summary: "When to track work and the basic workflow", text: """
    ## MetaWhisp tasks: overview

    MetaWhisp holds the user's projects: their tasks, and the memory of their calls and dictations. Your working \
    folder is the project. The user sees the same tasks on a board and in a list in the MetaWhisp app, so what you \
    write there is what they review.

    ### When to create a task

    Track work that needs planning, a decision, or a handoff: features, fixes, changes. Skip questions, exploration \
    and obvious one-line edits. When the user dictates or lists tasks, create them at once.

    Search before creating (`task_search` with a query, or `task_list` with a status) and read matches with \
    `task_view`. Extend an existing task instead of making a duplicate.

    ### Columns

    - **To Do** — agreed, not started.
    - **In Progress** — someone is on it now.
    - **Done** — finished and verified.
    - **Archive** — off the board (cancelled, duplicate, or finished work at cleanup); restorable with \
    `task_restore`, read-only until then.

    Suggestions MetaWhisp made from the user's calls are drafts; they belong to the user, who accepts them in the \
    app. You do not see or change drafts.

    ### Guides

    Read the matching guide before acting:
    - `task-creation` — before creating or splitting tasks
    - `task-execution` — before planning, changing a column or assignee, adding notes, or implementing
    - `task-finalization` — before ticking criteria, writing the final summary, or moving to Done

    ### Tools

    - `task_list` — the board, grouped by column; filter by status, assignee, labels, `ready`, `limit`. \
    `ready: true, limit: 1` is the next task to pick up
    - `task_search` — words, type, priority, modified files; includes archived tasks
    - `task_view` — one task in full
    - `task_create` — title, the why in `description`, `acceptanceCriteria`, labels, priority, dependencies, parent
    - `task_edit` — column, plan, notes, comments, criteria, summary, dependencies
    - `task_archive` / `task_restore` — off the board and back
    - `task_delete` — forever, archived tasks only, only after the user's explicit yes (`userConfirmed: true`)
    - `search_memories`, `search_conversations`, `recent_conversations` — what the user said in calls and dictations

    Always change tasks through these tools.
    """)

    static let creation = Guide(name: "task-creation", title: "Creating tasks",
                                summary: "How to search, scope and create tasks", text: """
    ## Creating tasks

    1. **Search first.** `task_search` with a query, or `task_list` filtered by status. Never list everything without \
    a filter unless the user asks. Read related tasks with `task_view`.
    2. **Size it.** One task is one focused change a reviewer can read in one sitting. If the request spans several \
    parts or natural steps, split it: subtasks (`parentTaskId`) for steps of one goal in one area; separate tasks with \
    `dependencies` for independent parts. Say what you created and why.
    3. **Write it for a stranger.** The agent who does the task may not be you and will not have this conversation. \
    Put the why in `description` (the problem, trigger or value, and context the code cannot give); keep how-to and \
    implementation detail out. Use `references` for issues, PRs and URLs, `documentation` for specs and design docs.
    4. **Acceptance criteria** (`acceptanceCriteria`): one line each, specific and testable, including edge cases, \
    tests and docs that belong to the task. They say what will be true, not the steps.
    5. **No plan yet.** The plan is written by whoever starts the task, after looking at the code as it is then.
    6. **Report.** Show the user each new task's ID, title and criteria so they can correct them.

    Follow-up work on an existing task is a subtask of it. Ask when the request is unclear.
    """)

    static let execution = Guide(name: "task-execution", title: "Working on a task",
                                 summary: "How to plan, update and work through tasks", text: """
    ## Working on a task

    1. `task_view` the task: description, criteria, dependencies (everything in `Depends on` must be Done or \
    archived), references, and its `History`: a task the user moved back from Done was not accepted — read why in its \
    comments or ask. Keep its `Revision`.
    2. Move it to **In Progress** with `task_edit` (`status: "In Progress"`) and set yourself in `assignee`. That \
    takes it: another agent session can neither take nor move it. If a task is already In Progress with someone \
    else, pick another (`task_list` with `ready: true`); the user frees it by moving it back to To Do.
    3. Look at the code, tests and recent changes as they are now.
    4. Write the plan into the task (`planSet`, later `planAppend`) before writing code. If the plan holds a product, \
    architecture or workflow decision, or the user asked to review plans, show it and wait for their yes.
    5. Work in short loops: change, run the tests, record progress with `notesAppend` (decisions, blockers, what you \
    learned). Use `commentsAppend` for questions and review notes.
    6. **Scope.** If new work turns up that the criteria do not cover, stop and ask the user: add criteria to this \
    task, or create a follow-up task? Never widen the scope or create tasks on your own.
    7. Keep the column true at every moment. You can be interrupted: the task must hold everything the next agent \
    needs.

    Subtasks: if the user gave you a parent "and all subtasks", go through them in order; otherwise finish one, \
    report, and ask before the next.

    When the work is done, follow `task-finalization`.
    """)

    static let finalization = Guide(name: "task-finalization", title: "Finishing a task",
                                    summary: "How to verify, summarize and finish work", text: """
    ## Finishing a task

    1. `task_view` the task and find evidence for every acceptance criterion and definition-of-done item.
    2. Run the tests and checks. For UI or interactive work, exercise the behaviour itself. Code that exists, grep \
    output or intent is not evidence.
    3. Tick only what you proved (`acceptanceCriteriaCheck`, `definitionOfDoneCheck`), with the `expectedRevision` \
    from your last `task_view`: if the task changed since, view it again. Fix what fails first.
    4. Make the plan match what you actually did (`planSet` / `planAppend`); keep useful decisions and results in \
    the notes.
    5. Write `finalSummary`: what changed, why, how it was verified, risks and follow-ups.
    6. Move it to **Done** with `task_edit`. Done is refused while a subtask or a dependency is still open: finish \
    them, or ask the user and pass `force: true` with the reason in `commentsAppend`. Leave Done tasks on the board; \
    the user archives them.

    Archive (`task_archive`) also takes cancelled, duplicate or invalid work off the board; finish its notes first, \
    since archived tasks are read-only. To delete a task forever: archive it, ask the user, and only after their \
    explicit yes call `task_delete` with `userConfirmed: true`.

    Do not create or start follow-up tasks without the user's approval.
    """)
}

/// FEAT-0006 §8 — puts the MetaWhisp block into an agent's global instructions file, or takes it out, and touches
/// nothing else. A start marker without its end leaves the file alone.
public enum AgentInstructionsFile {

    public enum Outcome: Equatable, Sendable {
        case written(String)
        case unchanged
        case refused(String)
    }

    static let unmatched = "The instructions file has a MetaWhisp block start without its end; it was left as it is."

    public static func install(_ text: String?) -> Outcome {
        let block = TrackerGuides.agentBlock
        guard let text, !text.isEmpty else { return .written(block + "\n") }
        guard let blocks = ranges(in: text) else { return .refused(unmatched) }
        var out: String
        if let first = blocks.first {
            // The first block is replaced where it stands; any later copy goes.
            out = String(text[..<first.lowerBound]) + block + stripAll(String(text[first.upperBound...]))
        } else if text.hasSuffix("\n\n") {
            out = text + block + "\n"
        } else if text.hasSuffix("\n") {
            out = text + "\n" + block + "\n"
        } else {
            out = text + "\n\n" + block + "\n"
        }
        return out == text ? .unchanged : .written(out)
    }

    public static func remove(_ text: String) -> Outcome {
        guard let blocks = ranges(in: text) else { return .refused(unmatched) }
        guard !blocks.isEmpty else { return .unchanged }
        return .written(stripAll(text))
    }

    /// Removes every complete block, each recomputed on the text as it is now.
    static func stripAll(_ text: String) -> String {
        var out = text
        while let r = ranges(in: out)?.first { out.removeSubrange(widened(r, in: out)) }
        return out
    }

    /// Each complete block, start marker to end marker; nil when a start has no end.
    static func ranges(in text: String) -> [Range<String.Index>]? {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let start = text.range(of: TrackerGuides.blockStart, range: from..<text.endIndex) {
            guard let end = text.range(of: TrackerGuides.blockEnd, range: start.upperBound..<text.endIndex) else {
                return nil
            }
            // A second start before this block's end: the first block is unfinished, and what lies between may be
            // the user's own text. Unmatched: the file is left alone (Codex review P1-2).
            if text.range(of: TrackerGuides.blockStart, range: start.upperBound..<end.lowerBound) != nil { return nil }
            found.append(start.lowerBound..<end.upperBound)
            from = end.upperBound
        }
        return found
    }

    /// The block plus the line break after it and the blank line before it, so removal gives the text back.
    static func widened(_ r: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = r.lowerBound, upper = r.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        let before = text[text.startIndex..<lower]
        if before.hasSuffix("\n\n") { lower = text.index(before: lower) }
        return lower..<upper
    }
}
