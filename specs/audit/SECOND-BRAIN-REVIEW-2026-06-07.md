# MetaWhisp Second Brain Review

Date: 2026-06-07

## Scope

Report-only code review of the current Second Brain surface:

- conversations and post-close processing;
- memory and task extraction;
- MetaChat mutations;
- Obsidian export;
- MCP snapshot;
- file indexing, Apple Notes and calendar-backed memory sources;
- daily and weekly synthesis.

No application code was edited.

## Goal

Identify product risks that can make Second Brain forget data, show stale data,
leak stale context into assistants, or tell the user an action succeeded when it
did not.

## Confirmed Improvements Since The Full App Audit

- MCP snapshot is now behind `mcpEnabled` and purges the plaintext file when
  disabled.
- MCP no longer exposes staged screen-OCR task candidates as committed tasks.
- Task and memory extractors now fetch the full conversation through
  `StructuredGenerator.fetchHistoryItems(...)`, so the previous 100-row prefix
  bug is fixed for those two paths.
- Obsidian path generation includes stable id suffixes for voices, tasks,
  meetings, memories and insights.
- Some task surfaces now re-export or delete Obsidian task files after staged
  candidate actions.

## Findings

### SB-001 - P1 - Concurrent conversation close can permanently skip structure, tasks and memories

Evidence:

- `Services/Intelligence/ConversationGrouper.swift:225-234` fires
  `StructuredGenerator`, `MemoryExtractor` and `TaskExtractor` after a close.
- `Services/Intelligence/StructuredGenerator.swift:231-233` returns immediately
  when another structuring job is running.
- `Services/Intelligence/TaskExtractor.swift:71-74` returns immediately when
  another extraction is running.
- `Services/Intelligence/MemoryExtractor.swift:73-75` returns immediately when
  another extraction is running.

Impact:

If two conversations close close together - for example a stale dictation closes
while a meeting stop is already being processed - the later conversation can
miss title/overview, tasks and memories. There is no queue, retry marker or
backfill for task/memory extraction.

Fix direction:

- Replace global `isRunning` drops with a per-conversation queue or persistent
  job table.
- Mark each conversation with extraction state (`pending`, `running`,
  `succeeded`, `failed`) for structure, tasks and memories.
- Add launch backfill for failed/pending task and memory jobs.

Acceptance:

- closing N conversations in quick succession processes each conversation once;
- failed extraction is visible and retried, not silently skipped.

### SB-002 - P1 - MetaChat mutations report success even if persistence fails

Evidence:

- `Services/Intelligence/ChatToolExecutor.swift:230-255` mutates/dismisses or
  completes tasks, calls `try? ctx.save()`, then sets `ok = true`.
- `Services/Intelligence/ChatToolExecutor.swift:269-273` forgets a memory with
  `try? ctx.save()` and still reports success.
- `Services/Intelligence/ChatToolExecutor.swift:334-367` creates tasks/memories
  with `try? ctx.save()` and still reports success.
- `Services/Intelligence/ChatToolExecutor.swift:621-623` undo also swallows
  save failure.

Impact:

The chat can say "Marked done", "Forgot" or "Stored memory" while the SwiftData
write failed. It also does not refresh MCP or Obsidian after these mutations, so
external Second Brain surfaces can remain stale even when the DB write succeeds.

Fix direction:

- Replace `try? ctx.save()` in mutation paths with throwing saves.
- Return `ok = false` if persistence fails.
- Route mutations through one service that also triggers Obsidian refresh and
  `MCPSnapshotService.snapshotNow()`.

Acceptance:

- injected save failure produces a visible failed action, no success message;
- successful mutation updates DB, Obsidian and MCP snapshot.

### SB-003 - P2 - MCP snapshot refresh-on-write is still not wired

Evidence:

- `Services/MCP/MCPSnapshotService.swift:91-95` exposes `snapshotNow()` for key
  writes.
- Repository search finds no call sites outside the method definition.
- Mutations in `ChatToolExecutor`, `TasksView` and `MemoriesView` save data but
  never call `snapshotNow()`.

Impact:

After creating/completing/forgetting a task or memory, Claude Desktop can read
stale Second Brain data for up to the 5-minute timer interval.

Fix direction:

- Call `snapshotNow()` from the same central mutation service that handles
  saves and export hooks.
- Add tests for create, complete, dismiss, edit and undo.

Acceptance:

- MCP snapshot changes immediately after a user-visible mutation when MCP is
  enabled.

### SB-004 - P2 - Obsidian files go stale or orphaned after common task/memory mutations

Evidence:

- `Views/Windows/TasksView.swift:312-316` toggles a committed task completion
  without re-exporting the task file.
- `Views/Windows/TasksView.swift:247-249` promotes a staged task to committed
  without exporting it.
- `Views/Windows/MemoriesView.swift:200-204` soft-deletes a memory without
  deleting or updating its Obsidian file.
- `Views/Windows/MemoriesView.swift:303-307` edits memory content without
  re-exporting.
- `Services/Export/ObsidianExporter.swift:398-403` simply returns for dismissed
  memories and has no delete-memory file path.

Impact:

The vault can disagree with the app: completed tasks remain open, saved
candidates never appear, edited memories keep old content, and deleted memories
remain searchable in Obsidian.

Fix direction:

- Centralize task/memory mutation side effects.
- Add `deleteMemoryFile(_:)` using the same stable-id scan pattern as
  `deleteTaskFile(_:)`.
- Re-export on edit/complete/promote/reopen.

Acceptance:

- every UI and chat mutation changes the corresponding Obsidian markdown state
  in the same way.

### SB-005 - P2 - File RAG can serve deleted or removed local files

Evidence:

- `Services/Indexing/FileIndexerService.swift:111-157` adds and updates records
  under a configured folder, but never deletes `IndexedFile` rows for paths that
  disappeared from disk.
- `Services/Indexing/FileIndexerService.swift:186-192` fetches existing rows by
  folder but only uses that map to update matching paths.
- `Services/Intelligence/ChatService.swift:1097-1110` fetches every
  `IndexedFile` with `contentText != nil` and does not verify file existence or
  current folder membership before injecting content into chat.

Impact:

If the user deletes a note, removes an indexed folder, or edits a sensitive file
out of scope, old content can remain in SwiftData and continue being returned to
MetaChat.

Fix direction:

- Reconcile scanned paths against DB paths on every scan and tombstone or delete
  missing records.
- Purge rows for folders removed from settings.
- Make chat RAG skip rows whose file no longer exists.

Acceptance:

- deleted files and removed folders disappear from Files UI and MetaChat context
  after the next scan.

### SB-006 - P2 - Apple Notes scan can stall at the first 40 notes

Evidence:

- `Services/Indexing/AppleNotesReaderService.swift:20-21` caps a scan at 40
  notes.
- `Services/Indexing/AppleNotesReaderService.swift:183-203` stops the
  AppleScript loop after that count.
- `Services/Indexing/AppleNotesReaderService.swift:79-87` filters processed ids
  only after fetching those 40 notes.

Impact:

If the first 40 notes are already processed, later notes are never fetched. A
large Notes library can permanently stop contributing new memories.

Fix direction:

- Fetch notes sorted by modification date and include a stable cursor or larger
  paged scan.
- Filter processed ids inside the AppleScript or fetch more than one page until
  pending work is found.

Acceptance:

- with 100 notes and the first 40 already processed, scan still processes note
  41+.

### SB-007 - P2 - Apple Notes processing state is coupled to created memories

Evidence:

- `Services/Indexing/AppleNotesReaderService.swift:350-358` considers a note
  processed only if a `UserMemory.sourceFile == "apple-note:<id>"` row exists.
- `Services/Indexing/AppleNotesReaderService.swift:111-128` creates no marker
  when a note correctly yields zero memories.
- `Services/Indexing/AppleNotesReaderService.swift:145` parses `modifiedAt`,
  but the dedup logic does not use it.

Impact:

Notes that have no durable memory value are sent back to the LLM on every scan.
Notes that did create a memory are never refreshed when edited or deleted.

Fix direction:

- Add a separate `IndexedExternalDocument` or `AppleNoteProcessingState` record
  with id, modifiedAt, processedAt, lastResult and error.
- Reprocess when modifiedAt changes.

Acceptance:

- empty-result notes are marked processed;
- edited notes are reprocessed exactly once per modification.

### SB-008 - P2 - Weekly Patterns are generated but not reachable

Evidence:

- `Models/PatternDigest.swift` stores weekly pattern rows.
- Repository search shows no `PatternDigest` reads in Views.
- `Services/Intelligence/WeeklyPatternDetector.swift:346-364` posts a
  "Weekly patterns ready" notification but routes the tap to
  `MainWindowView.SidebarTab.tasks`.
- `Views/Windows/MainSettingsView.swift:2053` promises
  "Insights tab -> GENERATE WEEKLY DIGEST", but there is no matching
  PatternDigest UI consumer.

Impact:

The app spends LLM budget and persists a digest the user cannot browse from the
Second Brain UI.

Fix direction:

- Add a weekly patterns section to the intended destination tab.
- Route notification tap to that section.
- Add manual generate button only where the digest is actually rendered.

Acceptance:

- after generation, the user can open the digest and see themes, people, stuck
  loops and insights.

### SB-009 - P2 - Malformed weekly pattern output suppresses retry for six days

Evidence:

- `Services/Intelligence/WeeklyPatternDetector.swift:282-301` converts parse
  failure into empty arrays.
- `Services/Intelligence/WeeklyPatternDetector.swift:151-162` persists the empty
  digest.
- `Services/Intelligence/WeeklyPatternDetector.swift:80-83` then suppresses
  another weekly run for six days based on the most recent digest.

Impact:

A malformed model response creates a "quiet week" style persisted row and blocks
retry for almost a week.

Fix direction:

- Make parse failure throw or return `nil`.
- Persist only valid model output or an explicit failed-attempt row that does
  not satisfy the anti-spam check.

Acceptance:

- malformed JSON does not create a successful digest and the next tick/manual
  trigger can retry.

### SB-010 - P2 - Daily summary regeneration deletes the old recap before a replacement is guaranteed

Evidence:

- `Services/Intelligence/DailySummaryService.swift:90-105` deletes any existing
  row before calling `generate(...)`.
- `Services/Intelligence/DailySummaryService.swift:118-157` can then return nil
  because another generation is running, LLM access is missing, the day is now
  considered empty, or the user is non-Pro.

Impact:

Clicking regenerate can remove a good daily recap and leave no replacement.

Fix direction:

- Generate into a temporary object/result first.
- Replace the old row only after the new summary is fully built and saved.

Acceptance:

- failed regeneration leaves the previous recap intact.

### SB-011 - P2 - Several Second Brain toggles do not start/stop services until relaunch

Evidence:

- `App/AppDelegate.swift:729-792` starts Daily Summary, Weekly Patterns, File
  Indexing, Apple Notes and Calendar only during launch.
- `App/AppDelegate.swift:855-910` observes settings changes only for screen
  context, advice, meeting recording and memories.
- `Views/Windows/MainSettingsView.swift:1323-1343`,
  `Views/Windows/MainSettingsView.swift:1934-1939`,
  `Views/Windows/MainSettingsView.swift:1981-2005` and
  `Views/Windows/MainSettingsView.swift:2025-2045` show toggles but do not
  consistently start or stop the corresponding scheduler when the toggle itself
  changes.

Impact:

The UI can say that a Second Brain source is enabled while its periodic service
is not running until the next app launch. Disabling may also leave an existing
timer alive.

Fix direction:

- Add explicit `onChange` or a single settings observer for each scheduler.
- On enable: configure/start immediately. On disable: stop immediately.

Acceptance:

- toggling each source at runtime changes service state without relaunch.

### SB-012 - P3 - Extractors can persist blank tasks or memories

Evidence:

- `Services/Intelligence/TaskExtractor.swift:510-540` accepts a task when word
  count is <= 15 but does not trim and reject empty descriptions.
- `Services/Intelligence/MemoryExtractor.swift:423-441` accepts a memory when
  word count is <= 15 and category is valid, but does not reject empty content.
- `Services/Indexing/FileMemoryExtractor.swift:212-215` and
  `Services/Indexing/AppleNotesReaderService.swift:381-387` have the same
  issue.

Impact:

Malformed model output can create blank task cards, blank memory rows,
notifications and markdown files.

Fix direction:

- Trim content/description before validation and require non-empty values.
- Keep the existing word cap after trimming.

Acceptance:

- empty and whitespace-only model output is rejected in all extraction paths.

### SB-013 - P3 - Tasks header counts completed tasks as active

Evidence:

- `Views/Windows/TasksView.swift:24-26` defines `committedTasks` without
  filtering `completed == false`.
- `Views/Windows/TasksView.swift:100-101` renders
  `"\(committedTasks.count) active"`.

Impact:

The task list can report completed tasks as active, which makes the user's
Second Brain feel less trustworthy.

Fix direction:

- Count incomplete committed tasks or rename the label.

Acceptance:

- after completing a task, the active count decrements.

## Suggested Fix Order

1. Add queued/per-conversation extraction state for structure, tasks and
   memories.
2. Centralize task/memory mutation side effects and stop swallowing save
   failures.
3. Wire Obsidian and MCP refresh hooks through that same mutation layer.
4. Reconcile file index deletes and Apple Notes processing state.
5. Make weekly/daily synthesis transactional and reachable in UI.
6. Add runtime start/stop observers for all Second Brain schedulers.
7. Add parser validation tests for blank tasks/memories.

## Test Gaps To Add

- two conversations close while extractors are busy -> both get processed;
- ChatToolExecutor save failure -> user sees failure and DB is unchanged;
- task/memory edit/delete/complete/promote -> DB, Obsidian and MCP all update;
- deleted indexed file is absent from MetaChat context after scan;
- Apple Notes page 2 is processed and empty-result notes are not re-sent;
- malformed weekly JSON does not create a successful digest;
- failed daily regeneration keeps old summary;
- toggling each scheduler-backed source starts/stops it without relaunch.

