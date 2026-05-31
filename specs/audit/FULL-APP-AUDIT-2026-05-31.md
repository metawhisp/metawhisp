# Full App Audit - 2026-05-31

## Purpose

Передаваемый backlog дефектов MetaWhisp перед bugfix-итерацией. На этом проходе
исходники приложения не исправляются: сначала фиксируются доказательства,
приоритет, затронутый сценарий и минимальная стратегия проверки.

## Baseline

- Audited commit: `90738e968b40b52d417e43ef43c392b3aa8ce25c`
- Branch: `architecture-phase-1-3`
- Analysis worktree: clean detached `HEAD`
- Excluded local drafts in the main worktree:
  - `CLAUDE.md`
  - `Services/Intelligence/TaskExtractor.swift`
  - `AGENTS.md`
  - `CLAUDE2.md`
- Backend `api/` and marketing `website/` are excluded by project rules.

## Success Criteria

- [x] Every first-party app module is assigned to an audited vertical scenario.
- [x] Findings distinguish proven defects from hypotheses requiring live checks.
- [x] Each proven defect has priority, evidence, user impact and verification path.
- [x] Static checks, `swift build` and `swift test` are recorded for clean `HEAD`.
- [x] Manual-only TCC, AppKit and network scenarios are listed separately.

## User Stories

1. Как владелец продукта, я хочу получить единый приоритизированный backlog,
   чтобы передать Claude последовательность исправлений без потери контекста.
2. Как разработчик, я хочу видеть доказательство и verification path для каждого
   бага, чтобы исправлять по одному дефекту через RED -> GREEN -> REFACTOR.
3. Как пользователь MetaWhisp, я хочу, чтобы критические сценарии диктовки,
   встреч, памяти, задач, чата и экспорта не теряли данные молча.

## Audit Map

- [x] Lifecycle, storage and SwiftData schema
- [x] Dictation, transcription and clipboard insertion
- [x] Meeting capture, auto-start, auto-stop, recap and dual-stream transcript
- [x] Conversations, COPY, PLAN and detail navigation
- [x] Tasks, memories, insights, goals and daily summaries
- [x] MetaChat, tool execution, people/workspace rules and MCP snapshot
- [x] Screen OCR, proactive extraction and privacy boundaries
- [x] Local LLM, BYOK, Pro proxy, model downloads and license routing
- [x] Obsidian export, file index, Apple Notes and Calendar integrations
- [x] UI lifecycle, onboarding, settings and update/release configuration

## Priority Summary

- Proven findings: `64`
- `P1`: `19` - data loss, crash, security/privacy boundary or broken primary path
- `P2`: `39` - incorrect state, stale output, silent degradation or release risk
- `P3`: `6` - lower-severity correctness, copy or UX defects
- Live-verification hypotheses: `3`

## Proven Findings

### AUD-001 - P1 - Dual-stream timestamps lose leading-silence offset

- Scenario: meeting recording -> dual-stream transcript -> chronological merge.
- Evidence:
  - `App/AppDelegate.swift:1366` trims leading silence from each audio chunk.
  - `App/AppDelegate.swift:1463-1465` adds only `chunkStartSec` to Whisper word
    timestamps, although each word timestamp is relative to the trimmed samples.
- Impact: Me/Them lines can be merged in the wrong order when one channel starts
  speaking later than the other.
- Verification path: add a pure regression test where mic and system channels
  have different leading-silence durations; assert absolute ordering after merge.
- Minimal fix direction: return leading trim duration from `trimSilenceEdges` and
  add it to absolute timestamps.

### AUD-002 - P1 - Failed meeting chunks are silently persisted as success

- Scenario: meeting stop -> dual-stream transcription retry -> persistence.
- Evidence:
  - `App/AppDelegate.swift:1298` makes the dual-stream result authoritative.
  - `App/AppDelegate.swift:1468-1470` logs a chunk failure after retry and
    continues.
  - `App/AppDelegate.swift:1303-1309` persists any non-empty partial result.
- Impact: a saved meeting transcript can omit failed chunks without warning.
- Verification path: force one middle chunk to fail twice; assert that the app
  does not silently save an apparently complete transcript.
- Minimal fix direction: propagate failed-chunk metadata and either fall back to
  live text, surface an incomplete state, or refuse silent persistence.

### AUD-003 - P2 - Local PLAN truncates transcript to the first 2000 characters

- Scenario: conversation detail -> PLAN -> local LLM.
- Evidence:
  - `Services/Intelligence/StructuredGenerator.swift:775-776` calls
    `completeBlocking` without overriding `maxUserChars`.
  - `Services/LLM/LocalLLMService.swift:428-434` defaults to 2000 characters and
    truncates the user block.
- Impact: tasks and decisions late in a meeting can be absent from the plan.
- Verification path: generate a plan from a transcript with a unique action
  after character 2000; assert the chosen route preserves or explicitly reports
  the omitted tail.
- Minimal fix direction: chunk long plans, use cloud when available, or surface
  an explicit partial-result state.

### AUD-004 - P2 - PLAN skips configured BYOK fallback

- Scenario: conversation detail -> PLAN with no active local model, no Pro
  subscription and a configured provider key.
- Evidence:
  - `Services/Intelligence/StructuredGenerator.swift:778-780` throws
    `Pro required` immediately after the local route.
  - The standard structured-generation route in the same service supports
    Local -> Pro -> BYOK.
- Impact: BYOK users cannot use PLAN although the application accepts their key.
- Verification path: assert route selection for Local, Pro and BYOK settings.
- Minimal fix direction: mirror the established routing order or gate the UI.

### AUD-005 - P2 - Stale PLAN result can appear under another conversation

- Scenario: open conversation A -> start PLAN -> deep-link to B -> A completes.
- Evidence:
  - `Views/Windows/ConversationsView.swift:43-46` can reuse one detail view while
    its identifier changes.
  - `Views/Windows/ConversationDetailView.swift:47` stores plan in local
    `@State`.
  - `Views/Windows/ConversationDetailView.swift:674-680` writes async completion
    without checking the requested conversation identifier.
- Impact: a generated plan can be displayed under the wrong conversation.
- Verification path: manual deep-link switch during generation; add extracted
  pure request-id guard test if the fix moves the condition out of SwiftUI.
- Minimal fix direction: reset/cancel on id changes and ignore stale completion.

### AUD-006 - P2 - Workspace prompt treats every window title as identity

- Scenario: MetaChat people lookup across generic app titles, channels and DMs.
- Evidence:
  - `Services/Intelligence/ChatService.swift:367-373` says people under different
    window titles belong to different workspaces, then asks for `unclear` when
    workspace evidence is not clear.
  - `specs/iterations/ITER-042-people-workspace-index.md:55-60` documents generic
    titles and DM titles as common inputs.
- Impact: people can be fragmented or bound to the wrong workspace.
- Verification path: fixture prompts for generic title, Telegram DM, same
  workspace across channels and two explicitly named workspaces.
- Minimal fix direction: use title only as evidence when it explicitly names a
  workspace; otherwise return `unclear`.

### AUD-007 - P1 - Persistent-store failure silently falls back to volatile memory

- Scenario: application launch -> SwiftData store initialization -> any saved data.
- Evidence:
  - `Services/Data/HistoryService.swift:18-24` logs a persistent-container error
    and replaces it with `ModelConfiguration(isStoredInMemoryOnly: true)`.
  - `HistoryService` exposes no degraded-storage state to the UI; all downstream
    services receive the volatile container as if persistence were healthy.
- Impact: dictations, meetings, tasks, memories and chat appear to save during
  the session, then disappear after restart.
- Verification path: point the store at an unreadable or incompatible database;
  assert that launch surfaces a blocking degraded-storage warning.
- Minimal fix direction: make degraded mode explicit and visible. Do not silently
  accept writes that the user reasonably expects to survive restart.

### AUD-008 - P1 - STOP during meeting startup can resurrect an orphan recording

- Scenario: click meeting RECORD -> SCStream setup is still pending -> click STOP.
- Evidence:
  - `App/AppDelegate.swift:1031-1033` routes STOP while
    `meetingRecorder.isStarting` through the normal stop path.
  - `Services/Audio/SystemAudioCaptureService.swift:46-76` launches async setup
    without a cancellable generation token.
  - `Services/Audio/SystemAudioCaptureService.swift:91-104` clears current state
    but does not invalidate pending setup or clear `isStarting`.
  - `Services/Audio/MeetingRecorder.swift:150-183` continues polling and can
    start the mic and set `isRecording = true` after the user already stopped.
- Impact: a user-visible STOP can be ignored; capture may restart in the
  background, which is a privacy boundary failure.
- Verification path: inject a delayed system-audio setup, call start then stop
  before setup resolves, and assert both recorders stay stopped afterward.
- Minimal fix direction: cancel or invalidate pending starts in both services
  using a start-generation token checked after every suspension point.

### AUD-009 - P2 - A manual recording can inherit stale call context

- Scenario: stop an auto-detected Zoom/Meet recording -> manually record an
  unrelated note within ten minutes.
- Evidence:
  - `App/AppDelegate.swift:1245-1249` intentionally retains
    `currentMeetingCallContext` after stop.
  - `App/AppDelegate.swift:1038-1045` starts a manual recording without clearing
    that retained value.
  - `App/AppDelegate.swift:1634` passes the retained value into grouping.
  - `Services/Intelligence/ConversationGrouper.swift:132-152` resumes any recent
    meeting with the same call-context label.
- Impact: an unrelated manual note can be appended to the previous meeting,
  contaminating transcript, PLAN, tasks and memories.
- Verification path: create a completed auto Zoom conversation, then assign a
  manual recording within the resume window; assert it creates a fresh row.
- Minimal fix direction: clear context on manual start or pass explicit recording
  metadata so only genuine auto-resume segments are eligible.

### AUD-010 - P1 - Meeting silence protection compares raw-RMS thresholds to boosted UI levels

- Scenario: auto-started meeting ends -> ambient mic noise remains.
- Evidence:
  - `Services/Audio/AudioRecordingService.swift:270-275` converts raw RMS into
    `sqrt(min(rms * 12, 1))` for UI display.
  - `Services/Audio/SystemAudioCaptureService.swift:201-205` does the same.
  - `Services/Audio/MeetingRecorder.swift:310` compares the boosted `audioLevel`
    against `silenceRMSThreshold = 0.025`, documented as an RMS threshold.
  - `App/AppDelegate.swift:1998` and `App/AppDelegate.swift:2065-2074` reuse the
    boosted level as if it were raw RMS for post-start and calendar decisions.
- Impact: typical ambient noise can keep an ended recording alive until the
  max-duration guard, weakening the protection against background capture.
- Verification path: pure-test the conversion boundary and live-test an ended
  auto meeting in a quiet room; assert silence timeout and post-start sniff fire.
- Minimal fix direction: track raw RMS separately from presentation level and
  use raw RMS consistently in all recording decisions.

### AUD-011 - P1 - Dictation discards its sanitized pipeline value

- Scenario: ordinary dictation contains a mid-speech hallucination token or a
  glossary correction.
- Evidence:
  - `Services/System/TranscriptionCoordinator.swift:315-320` computes sanitized
    `trimmed`.
  - `Services/System/TranscriptionCoordinator.swift:340` resets output to the
    original `result.text`.
  - `Services/System/TranscriptionCoordinator.swift:347` also sends the original
    text to post-processing.
  - `Services/System/TranscriptionCoordinator.swift:359-380` saves history before
    glossary and correction-dictionary normalization at `:386-399`.
- Impact: mid-speech toxic artifacts can still reach paste and history. Glossary
  or learned corrections may appear in pasted text but remain stale in Library,
  Obsidian export and downstream AI extraction.
- Verification path: integration-test a long transcript with a toxic token and a
  glossary mangle; assert paste, history and downstream input all use one
  sanitized normalized string.
- Minimal fix direction: establish one normalized transcript value before
  post-processing, persistence and paste; persist the final user-visible value.

### AUD-012 - P2 - Suspect-text recovery bypasses verified clipboard writes

- Scenario: hallucination heuristic flags a possible false positive while
  another process races for NSPasteboard ownership.
- Evidence:
  - `Services/System/TranscriptionCoordinator.swift:466-470` clears and writes
    directly to `NSPasteboard.general`, ignoring the `setString` result.
  - `Services/System/TextInsertionService.swift:87-109` already implements
    verified write plus retries for this exact race.
- Impact: the recovery message can claim text was saved while the clipboard is
  empty.
- Verification path: route suspect recovery through an injectable pasteboard or
  shared helper and test failed-write reporting.
- Minimal fix direction: reuse `writeToClipboardVerified` and surface failure.

### AUD-013 - P2 - REGENERATE can erase a summary while another generation is running

- Scenario: background structuring is active for conversation A -> user clicks
  REGENERATE for conversation B.
- Evidence:
  - `Services/Intelligence/StructuredGenerator.swift:191-209` clears B's title,
    overview and all structured fields, then saves.
  - `Services/Intelligence/StructuredGenerator.swift:210` calls `generate`.
  - `Services/Intelligence/StructuredGenerator.swift:230` immediately returns
    while the singleton-wide `isRunning` flag is true.
- Impact: the explicit user action can replace an existing useful summary with
  blank fields and provide no error.
- Verification path: keep generation A suspended, regenerate B, then assert B's
  previous structured fields remain intact or a retry completes.
- Minimal fix direction: reserve the per-conversation job before destructive
  clearing, or restore previous values when scheduling cannot proceed.

### AUD-014 - P2 - Concurrent conversation structuring is silently dropped

- Scenario: two conversations close while the first structured-generation
  request is still in flight.
- Evidence:
  - `Services/Intelligence/StructuredGenerator.swift:230` rejects every second
    request through one singleton-wide `isRunning` flag.
  - `Services/Intelligence/StructuredGenerator.swift:316-317` holds that flag
    across the remote or local LLM call.
  - `Services/Intelligence/StructuredGenerator.swift:118-123` backfills only
    explicit `"Quick note"` or `"(empty)"` placeholders, not untouched nil rows.
- Impact: the second conversation can remain permanently unstructured without
  a retry, even after restart.
- Verification path: suspend generation A, request generation B, release A and
  assert B is eventually processed exactly once.
- Minimal fix direction: queue or deduplicate work by conversation id instead of
  dropping calls behind one global busy flag.

### AUD-015 - P2 - Structured-generation failures are excluded from launch backfill

- Scenario: structured-generation LLM request fails or returns invalid JSON.
- Evidence:
  - `Services/Intelligence/StructuredGenerator.swift:349-351` returns on parse
    failure without writing placeholders.
  - `Services/Intelligence/StructuredGenerator.swift:421-424` records request
    failure only in memory and logs it.
  - `Services/Intelligence/StructuredGenerator.swift:118-123` launch backfill
    selects only `"Quick note"` or `"(empty)"`, not nil title/overview fields.
- Impact: a transient outage or malformed response can leave a conversation
  stuck as `Untitled` indefinitely.
- Verification path: force proxy failure and malformed JSON separately, restart
  the service and assert both rows become eligible for a bounded retry.
- Minimal fix direction: persist an explicit failed/pending state and include it
  in bounded backfill selection.

### AUD-016 - P2 - “Full transcript” paths silently use inconsistent 200-item slices

- Scenario: a long conversation contains more than 200 linked `HistoryItem`
  fragments -> COPY, PLAN or REGENERATE.
- Evidence:
  - `Views/Windows/ConversationDetailView.swift:51-55` labels its derived text as
    full transcript and feeds both COPY and PLAN.
  - `Views/Windows/ConversationDetailView.swift:632-637` actually loads only the
    oldest 200 linked rows.
  - `Services/Intelligence/StructuredGenerator.swift:84-92` scans only the most
    recent 200 global history rows before filtering by conversation.
- Impact: COPY and PLAN omit the tail, while regenerated structure can omit the
  head or even see no rows when unrelated recent history pushes the target out
  of the global slice.
- Verification path: create a conversation with 201 linked rows plus unrelated
  recent rows; assert all user-facing transcript paths receive the same complete
  ordered content.
- Minimal fix direction: fetch linked rows directly with pagination or a
  conversation-scoped query; make any intentional cap explicit to the user.

### AUD-017 - P2 - Common task mutations leave Obsidian markdown stale

- Scenario: complete, reopen or dismiss a task outside the staged-candidate card.
- Evidence:
  - `Services/Export/ObsidianExporter.swift:567-575` documents that task
    completion updates markdown and dismissal removes it.
  - `Views/Windows/TasksView.swift:312-316` toggles completion without re-export.
  - `Views/Windows/InsightsView.swift:146-175` toggles completion and dismisses
    without re-export or file deletion.
  - `Services/Intelligence/MeetingRecapState.swift:82-96` toggles completion
    without re-export.
- Impact: the vault can contradict the app until a later bulk export; dismissed
  tasks from Insights can remain on disk.
- Verification path: export a task, mutate it through each UI surface and assert
  frontmatter update or deletion immediately.
- Minimal fix direction: centralize task mutation and trigger exporter refresh,
  MCP refresh and persistence error handling from one service.

### AUD-018 - P2 - MCP exposes unreviewed OCR candidates as trusted pending tasks

- Scenario: screen OCR infers a staged candidate -> Claude Desktop calls
  `list_tasks`.
- Evidence:
  - `Services/Intelligence/ScreenExtractor.swift:237-246` and
    `Services/Intelligence/RealtimeScreenReactor.swift:189-198` intentionally
    create weak-signal OCR tasks with `status: "staged"`.
  - `Services/MCP/MCPSnapshotService.swift:93-129` exports every non-dismissed
    task and omits `status` from the DTO.
  - `Sources/MetaWhispMCP/main.swift:315-320` treats every incomplete snapshot
    task as pending.
- Impact: Claude can present OCR guesses, including stale candidates hidden by
  the app after seven days, as the user's real task list.
- Verification path: insert staged and committed tasks, write a snapshot and
  assert default MCP `list_tasks` returns committed tasks only.
- Minimal fix direction: exclude staged rows from the default snapshot or carry
  status through the wire format and expose review candidates separately.

### AUD-019 - P3 - Voice task extraction accepts blank descriptions

- Scenario: the task-extraction LLM emits `{"description": ""}`.
- Evidence:
  - `Services/Intelligence/TaskExtractor.swift:493-498` rejects only descriptions
    longer than 15 words; an empty string has zero words and passes.
  - `Services/Intelligence/TaskExtractor.swift:516-523` constructs the row.
  - `Services/Intelligence/TaskExtractor.swift:160-174` notifies and exports
    every constructed task.
- Impact: blank task cards, notifications and markdown files can be created.
- Verification path: parse an empty and whitespace-only description and assert
  both are rejected.
- Minimal fix direction: trim and require a non-empty description before word
  count validation.

### AUD-020 - P3 - Tasks header counts completed rows as active

- Scenario: mark committed tasks complete and return to the Tasks tab.
- Evidence:
  - `Views/Windows/TasksView.swift:26` defines `committedTasks` without filtering
    `completed`.
  - `Views/Windows/TasksView.swift:100-101` renders
    `"\(committedTasks.count) active"`.
- Impact: the top-level active-task count remains inflated after completion.
- Verification path: create one committed task, complete it and assert the
  displayed active count becomes zero.
- Minimal fix direction: count incomplete committed tasks or rename the label.

### AUD-021 - P1 - Screen Context blacklist and whitelist UI is not wired to capture

- Scenario: add a banking or password app to EXCLUDED APPS, or switch to
  WHITELIST mode -> continue using the app.
- Evidence:
  - `Models/AppSettings.swift:129-130` persists `screenContextMode` and
    `screenContextAppList`.
  - `Views/Windows/MainSettingsView.swift:2260-2274` tells the user excluded
    sensitive apps will be skipped.
  - `App/AppDelegate.swift:605-608` and `App/AppDelegate.swift:859-864` start the
    monitor with only an interval.
  - `Services/Screen/ScreenContextService.swift:71-79` therefore receives the
    default empty custom blacklist and nil whitelist.
- Impact: an explicit privacy choice in Settings has no effect; OCR from an app
  the user excluded can still be persisted and sent into AI features.
- Verification path: exclude a fixture app, focus it, force a monitor tick and
  assert no `ScreenContext` row is created; repeat in whitelist mode.
- Minimal fix direction: parse settings into bundle-id sets and restart the
  monitor when mode or list changes.

### AUD-022 - P1 - Screen OCR captures the whole display, not the active window

- Scenario: focus a safe app while a password manager, private chat or token is
  visible beside or behind it.
- Evidence:
  - `Services/Screen/ScreenContextService.swift:7` and `:251` describe active
    window capture.
  - `Services/Screen/ScreenContextService.swift:283-297` actually creates an
    `SCContentFilter(display:excludingWindows: [])` and screenshots the full
    display.
  - `Services/Screen/ScreenContextService.swift:265-273` labels all OCR with only
    the front app and front window title.
- Impact: sensitive text from unrelated visible windows can bypass front-app
  blacklist checks, enter SwiftData and later reach cloud prompts.
- Verification path: show a unique secret string in a second visible window,
  focus a safe fixture app and assert that string never appears in persisted OCR.
- Minimal fix direction: capture the selected active window only, or apply a
  correctly-scoped window filter and redact before persistence.

### AUD-023 - P1 - Voice MetaChat captures screen OCR even when Screen Context is off

- Scenario: disable Screen Context -> invoke a voice question while Screen
  Recording permission is already available.
- Evidence:
  - `Services/Intelligence/ChatService.swift:85-93` always calls
    `screenContext.captureNow()` for voice messages.
  - `Services/Screen/ScreenContextService.swift:168-170` performs capture with
    the default blacklist and does not check `screenContextEnabled`.
  - The same path bypasses the custom list from AUD-021 and uses the full-display
    screenshot from AUD-022.
- Impact: turning OCR collection off does not prevent ad-hoc OCR from being sent
  into a voice-question LLM prompt.
- Verification path: disable Screen Context, mock `captureNow`, send a voice
  chat message and assert capture is not invoked without explicit opt-in.
- Minimal fix direction: gate current-screen voice OCR behind a dedicated,
  visible consent setting and apply the configured capture policy.

### AUD-024 - P1 - API and license secrets are stored outside macOS Keychain

- Scenario: configure BYOK credentials or activate Pro -> inspect application
  support files from another process running as the same user.
- Evidence:
  - `Models/AppSettings.swift:317-334` routes OpenAI, Cerebras and Groq keys
    through `KeychainHelper`.
  - `Services/License/LicenseService.swift:32-35` stores session and license
    tokens through the same helper.
  - `Models/AppSettings.swift:355-393` implements that helper as JSON written to
    `~/Library/Application Support/MetaWhisp/.secrets`; it does not call Security
    framework Keychain APIs despite importing `Security`.
- Impact: same-user processes can read API, session and license credentials from
  one predictable file while the account is logged in. The helper comment
  overstates protection.
- Verification path: save fixture credentials, read and decode `.secrets`, then
  migrate to Keychain and assert the file no longer contains tokens.
- Minimal fix direction: use Keychain Services with an explicit migration that
  deletes the legacy file after successful import.

### AUD-025 - P1 - Session token is placed in URL query strings and logged

- Scenario: website deep-link activation or startup session verification.
- Evidence:
  - `App/AppDelegate.swift:2305` logs the first eight characters of the incoming
    token.
  - `Services/License/LicenseService.swift:55` logs the prefix again.
  - `Services/License/LicenseService.swift:58` and `:117` send the full session
    token as a GET query parameter.
- Impact: token material can leak to unified logs and full tokens can leak to
  server, proxy or observability URL logs.
- Verification path: activate with a fixture token and assert logs and captured
  request URLs contain no token material.
- Minimal fix direction: use a POST body or authorization header and never log
  any credential prefix.

### AUD-026 - P2 - Inactive-license responses leave cached Pro credentials on disk

- Scenario: a previously active subscription expires -> verification returns no
  active license -> app launches offline later.
- Evidence:
  - `Services/License/LicenseService.swift:32-46` restores cached license key and
    marks Pro before asynchronous verification.
  - `Services/License/LicenseService.swift:141-147` clears only in-memory state
    for an inactive verification response.
  - `Services/License/LicenseService.swift:150-153` intentionally preserves the
    restored state when a later verification attempt is offline.
- Impact: a stale credential can restore a false Pro UI and feature gates on a
  later offline launch; proxy calls then fail inconsistently.
- Verification path: seed a cached key, mock inactive verification, relaunch
  offline and assert Pro remains disabled.
- Minimal fix direction: clear persisted license key and plan on authoritative
  inactive responses; separate offline grace policy from stale cache.

### AUD-027 - P2 - MetaChat mutations report success when persistence fails

- Scenario: confirm any MetaChat mutation while SwiftData save fails.
- Evidence:
  - `Services/Intelligence/ChatToolExecutor.swift:233-255`, `:269-273`,
    `:309-313` and `:340-367` use `try? ctx.save()` then set `ok = true`.
  - `Services/Intelligence/ChatToolExecutor.swift:621-623` does the same for undo.
  - `Services/Intelligence/ChatService.swift:542-549` renders the executor result
    as a successful chat action.
- Impact: chat can claim a task, memory or goal changed when the write was lost;
  undo can also claim a revert that was not persisted.
- Verification path: inject a failing persistence layer and assert every
  mutation and undo returns `ok = false` with a surfaced error.
- Minimal fix direction: handle save errors before producing success, and move
  mutation persistence behind a testable repository.

### AUD-028 - P2 - MCP snapshot refresh-on-write contract is not implemented

- Scenario: create or complete a task -> immediately ask Claude Desktop for
  tasks.
- Evidence:
  - `Services/MCP/MCPSnapshotService.swift:70-75` documents `snapshotNow()` for
    key writes.
  - Repository search finds no caller of `snapshotNow()`.
  - `Services/MCP/MCPSnapshotService.swift:29-31` leaves periodic refresh as the
    only update path, every five minutes.
- Impact: MCP responses can be stale for up to five minutes after user-visible
  mutations.
- Verification path: mutate a task and assert snapshot content updates without
  advancing the timer.
- Minimal fix direction: centralize writes and trigger a debounced snapshot
  refresh after committed mutations.

### AUD-029 - P2 - MCP snapshot is always emitted without an enable/disable gate

- Scenario: launch MetaWhisp without configuring MCP or Claude Desktop.
- Evidence:
  - `App/AppDelegate.swift:634-639` configures and starts snapshot export on
    every launch.
  - `Services/MCP/MCPSnapshotService.swift:108-148` serializes memories, tasks
    and conversation summaries.
  - `Services/MCP/MCPSnapshotService.swift:155` writes JSON without explicit
    owner-only permissions. A local reproduction of the same atomic `Data.write`
    call under standard umask `022` created mode `0644`.
- Impact: the app creates a durable plaintext duplicate of private data even
  for users who never opted into MCP.
- Verification path: launch with a clean support directory and assert no
  snapshot is written until MCP is enabled; verify owner-only permissions.
- Minimal fix direction: add explicit opt-in, delete snapshots on opt-out and
  set restrictive permissions after every atomic replacement.

### AUD-030 - P2 - Editing or deleting a memory leaves its Obsidian copy stale

- Scenario: sync a memory -> edit or delete it in Library.
- Evidence:
  - `Views/Windows/MemoriesView.swift:200-204` soft-deletes without an exporter
    call.
  - `Views/Windows/MemoriesView.swift:303-307` edits without re-export.
  - `Services/Export/ObsidianExporter.swift:398-403` returns early for dismissed
    memories and exposes no delete-memory path.
- Impact: outdated or intentionally deleted personal facts can remain in the
  user's vault indefinitely.
- Verification path: export, edit and delete a fixture memory; assert markdown
  updates on edit and disappears on delete.
- Minimal fix direction: add stable memory-file deletion and route all memory
  mutations through one sync-aware service.

### AUD-031 - P2 - Daily Summary regeneration deletes the old recap before replacement is viable

- Scenario: regenerate an existing recap while generation is busy, offline,
  non-Pro or missing activity.
- Evidence:
  - `Services/Intelligence/DailySummaryService.swift:95-104` deletes and saves
    the existing row first.
  - `Services/Intelligence/DailySummaryService.swift:118-157` can then return nil
    for busy state, no LLM access, empty day or missing Pro license.
- Impact: a user can lose a previously useful daily recap by pressing GENERATE.
- Verification path: persist a recap, force each early-return branch and assert
  the old recap remains.
- Minimal fix direction: generate replacement first, then swap rows atomically
  only after successful persistence.

### AUD-032 - P1 - Inverted goal rating bounds can crash the Goals screen

- Scenario: create or edit a Rating goal with MIN greater than MAX.
- Evidence:
  - `Views/Windows/GoalsView.swift:390-410` accepts numeric bounds without
    validating order.
  - `Views/Windows/GoalsView.swift:187-203` forms `lo...hi` for `Slider`.
- Impact: reopening or rendering the goal can hit Swift's invalid closed-range
  precondition and terminate the app.
- Verification path: save MIN `10`, MAX `1`, render Goals and assert validation
  prevents the invalid range.
- Minimal fix direction: validate finite values and require `min < max` before
  save.

### AUD-033 - P2 - Rating goals initialize and reset outside their declared range

- Scenario: create a default Rating `1-10` goal or open one the day after an
  update.
- Evidence:
  - `Views/Windows/GoalsView.swift:400-408` creates every goal with
    `currentValue: 0`.
  - `Models/Goal.swift:126-134` also resets Rating goals to zero.
  - `Models/Goal.swift:87-90` otherwise models Rating progress as
    `minValue...maxValue`.
- Impact: UI and AI context can report `0/10` for a `1-10` rating and feed an
  out-of-range value into the slider.
- Verification path: create and daily-reset a `1-10` rating; assert progress is
  initialized to its minimum or an explicit unset state.
- Minimal fix direction: choose a valid initial/reset representation for rating
  goals.

### AUD-034 - P2 - Task and memory extraction silently drop concurrent conversations

- Scenario: close conversation B while extraction for A is still waiting on its
  LLM response.
- Evidence:
  - `Services/Intelligence/TaskExtractor.swift:38-42` and
    `Services/Intelligence/MemoryExtractor.swift:45-49` fire independent tasks.
  - `Services/Intelligence/TaskExtractor.swift:67-69` and
    `Services/Intelligence/MemoryExtractor.swift:73-75` silently return behind
    singleton-wide `isRunning` flags.
- Impact: B permanently misses automatic task or memory extraction; there is no
  queue or backfill.
- Verification path: suspend extraction A, trigger B, release A and assert both
  conversation ids are processed once.
- Minimal fix direction: queue or deduplicate pending ids instead of dropping
  work.

### AUD-035 - P2 - “Full conversation” task and memory extraction is truncated

- Scenario: a long conversation has more than 100 fragments or uses local LLM.
- Evidence:
  - `Services/Intelligence/TaskExtractor.swift:4-10` and
    `Services/Intelligence/MemoryExtractor.swift:4-9` promise full closed
    conversation context.
  - `Services/Intelligence/TaskExtractor.swift:74-80` and
    `Services/Intelligence/MemoryExtractor.swift:80-85` load only 100 rows.
  - Both local routes call `LocalLLMService.completeBlocking`; its default at
    `Services/LLM/LocalLLMService.swift:425-434` keeps only the first 2000 user
    characters.
- Impact: late reversals, completions, tasks and facts can be missed, producing
  incorrect extractions.
- Verification path: place a unique action and a cancellation after the cap;
  assert the extractor sees the complete ordered conversation or reports a
  partial-result state.
- Minimal fix direction: paginate, summarize or chunk explicitly; never silently
  label a prefix as full context.

### AUD-036 - P2 - Several feature toggles do not activate services until relaunch

- Scenario: launch with a feature off -> enable it in Settings.
- Evidence:
  - `App/AppDelegate.swift:718-797` starts Daily Summary, Weekly Patterns, Screen
    Extraction, File Indexing, Apple Notes and Calendar periodic services only
    during launch when their stored flag is already true.
  - `App/AppDelegate.swift:844-899` observes only Screen Context, Advice, Meeting
    and Memories toggles.
- Impact: enabling affected features can appear successful in UI but periodic
  behavior remains inactive until app restart. Disabling leaves sleeping timers
  allocated until restart.
- Verification path: toggle every periodic feature on and off after launch and
  assert service scheduler state changes immediately.
- Minimal fix direction: centralize runtime reconciliation for every toggle and
  interval setting.

### AUD-037 - P2 - Weekly Patterns digest has no reachable UI

- Scenario: generate a weekly digest or tap its notification.
- Evidence:
  - Repository search finds `PatternDigest` consumption only in its model and
    generator; no mounted view queries or renders stored digests.
  - `Views/Windows/MainSettingsView.swift:2030` instructs the user to use
    `Insights tab -> GENERATE WEEKLY DIGEST`, but the current sidebar has no
    Insights tab (`Views/Windows/MainWindowView.swift:38-47`).
  - `Services/Intelligence/WeeklyPatternDetector.swift:358-364` sends its
    notification tap to the Tasks tab.
- Impact: generated cross-conversation insights are persisted but cannot be
  read in the application.
- Verification path: generate a fixture digest and prove a mounted screen can
  render it and notification navigation lands there.
- Minimal fix direction: add a reachable digest surface and route notification
  navigation to it, or remove the unfinished setting.

### AUD-038 - P2 - Malformed Weekly Patterns output suppresses retry for six days

- Scenario: proxy returns malformed JSON for a scheduled digest.
- Evidence:
  - `Services/Intelligence/WeeklyPatternDetector.swift:282-301` turns parse
    failure into four empty arrays.
  - `Services/Intelligence/WeeklyPatternDetector.swift:150-162` persists that
    empty digest as success.
  - `Services/Intelligence/WeeklyPatternDetector.swift:80-83` blocks another
    scheduled attempt for six days.
- Impact: a transient model-format error silently becomes a “quiet week” and
  prevents recovery until the next weekly cycle.
- Verification path: return invalid JSON and assert no success row is persisted
  and retry remains eligible.
- Minimal fix direction: distinguish parse failure from an explicit empty
  result.

### AUD-039 - P2 - MetaChat ignores an active local LLM

- Scenario: free user activates a downloaded local model without a BYOK key ->
  opens MetaChat.
- Evidence:
  - `Services/LLM/LocalLLMService.swift:405-408` lists ChatService among intended
    `completeBlocking` users.
  - `Services/Intelligence/ChatService.swift:1773-1775` grants access only for
    BYOK or Pro.
  - `Services/Intelligence/ChatService.swift:148-178` routes only Pro proxy or
    direct BYOK and has no local branch.
- Impact: the app can show an active local model while MetaChat still refuses to
  send messages.
- Verification path: activate local-only settings and assert chat completes
  locally or the UI explicitly states the limitation.
- Minimal fix direction: add the intended local route or gate the surface
  honestly.

### AUD-040 - P3 - Memory extractors accept blank model output as a memory

- Scenario: an LLM returns `{"content":"   ","category":"system"}` with confidence
  above the acceptance threshold.
- Evidence:
  - `Services/Intelligence/MemoryExtractor.swift:424-435` checks only the word
    cap and category before constructing a memory.
  - `Services/Indexing/FileMemoryExtractor.swift:91-107`, `:212-215`,
    `Services/Indexing/AppleNotesReaderService.swift:112-126`, `:381-387` and
    `Services/Indexing/CalendarReaderService.swift:380-395`, `:485-491` use the
    same shape: trim after parsing, but never reject an empty result.
- Impact: malformed model output can create empty memory rows and blank Library
  items.
- Verification path: feed whitespace-only content to every parser and assert it
  is rejected.
- Minimal fix direction: normalize first and require non-empty content before
  persistence.

### AUD-041 - P2 - Obsidian scoped exports cap global rows before filtering

- Scenario: export a meeting, conversation hub or daily summary after the
  database grows beyond the fixed cap.
- Evidence:
  - `Services/Export/ObsidianExporter.swift:121-126`, `:153-178` and `:217-244`
    fetch global pages and only then filter by conversation id.
  - `Services/Export/ObsidianExporter.swift:288-342` does the same for daily
    summaries: global rows are capped before the day filter.
- Impact: a valid conversation or day can silently lose transcript fragments,
  tasks, memories or links in the vault.
- Verification path: insert unrelated rows beyond each cap and export an older
  target fixture; assert the complete target scope is rendered.
- Minimal fix direction: filter in the `FetchDescriptor` predicate and paginate
  explicitly when a real output cap is required.

### AUD-042 - P1 - Obsidian Sync OFF does not stop the v2 exporter

- Scenario: pick a vault, enable Obsidian Sync, disable it again, then dictate or
  finish a meeting.
- Evidence:
  - `Services/Export/ObsidianExporter.swift:693-705` validates only the stored
    vault path; it never checks `obsidianSyncEnabled`.
  - `Services/System/TranscriptionCoordinator.swift:369-377` and
    `App/AppDelegate.swift:1184-1194` invoke v2 exports without checking the
    toggle.
  - The legacy services do check the toggle
    (`Services/Indexing/MeetingObsidianWriter.swift:33`,
    `Services/Indexing/ObsidianSyncService.swift:43`).
- Impact: private transcripts continue to be written to the vault after the
  user explicitly turns sync off.
- Verification path: disable sync while leaving a valid vault path, create a
  dictation and assert no file is written.
- Minimal fix direction: make the v2 exporter enforce the toggle at its public
  boundary.

### AUD-043 - P1 - Obsidian paths can overwrite unrelated records

- Scenario: create two dictations for the same project during one minute.
- Evidence:
  - `Services/Export/ObsidianPath.swift:298-307` builds voice paths from only
    date, minute and project.
  - `Services/Export/ObsidianPath.swift:232-258`, `:326-350` use similarly
    collision-prone mutable slugs for meetings, conversation hubs, memories and
    insights.
  - `Services/Export/ObsidianExporter.swift:710-717` atomically writes to that
    path, replacing an existing file.
- Impact: the vault can silently lose earlier exported content.
- Verification path: export two distinct fixtures that resolve to the same path
  and assert both remain addressable.
- Minimal fix direction: include a stable short id in every entity filename.

### AUD-044 - P2 - Obsidian renames leave orphan markdown files

- Scenario: export an entity, then change a title, project, headline or content
  and export again.
- Evidence:
  - `Services/Export/ObsidianPath.swift:232-350` derives most paths from mutable
    values.
  - `Services/Export/ObsidianExporter.swift:204-205`, `:267-268`, `:619-624`
    and `:643-648` write the new path without deleting a previous path for the
    same id.
  - Only tasks expose a stable-id cleanup path
    (`Services/Export/ObsidianExporter.swift:411-441`).
- Impact: stale private content remains in the vault and bulk export accumulates
  misleading duplicates.
- Verification path: export, rename and re-export one fixture of every entity
  type; assert exactly one current file remains per id.
- Minimal fix direction: store or discover the prior stable-id file and remove
  obsolete paths during replacement.

### AUD-045 - P1 - File index serves stale content after edits, deletes and folder removal

- Scenario: index a note, then edit or delete it, or remove its indexed folder;
  ask MetaChat about the old text.
- Evidence:
  - `Services/Indexing/FileIndexerService.swift:121-129` resets
    `contentExtractedAt` on modification but leaves `contentText` unchanged.
  - `Services/Indexing/FileIndexerService.swift:111-157` discovers and updates
    files but never removes rows for missing paths.
  - `Models/AppSettings.swift:241-244` removes only the configured folder string.
  - `Services/Intelligence/ChatService.swift:1098-1135` searches every
    `IndexedFile` with stored content, without checking current folders or disk
    existence.
- Impact: MetaChat can quote content the user changed, deleted or explicitly
  removed from indexing.
- Verification path: cover edit, filesystem delete and settings removal; assert
  the old phrase is no longer searchable.
- Minimal fix direction: clear and refill changed content, reconcile missing
  rows, purge removed folders and scope chat search to active records.

### AUD-046 - P2 - Client-side extension filtering can starve file backfill forever

- Scenario: index more than 1000 recent non-text files and an older Markdown
  note.
- Evidence:
  - `Services/Indexing/FileIndexerService.swift:211-217` fetches only the newest
    1000 nil-content rows before filtering extractable extensions in memory.
  - Non-text rows retain nil content and therefore occupy the same next page on
    every pass.
  - `Services/Indexing/FileMemoryExtractor.swift:41-48` repeats the pattern with
    a 60-row overfetch before its 15-file extraction batch.
- Impact: valid older notes never become searchable and never produce memories.
- Verification path: seed newer image rows ahead of one Markdown row and run
  repeated passes; assert the Markdown row eventually progresses.
- Minimal fix direction: express extractable extensions in the query or paginate
  past filtered-out rows.

### AUD-047 - P1 - Apple Notes scanning can permanently stall after the first 40 notes

- Scenario: the Notes app contains more than 40 notes; run periodic scans after
  the first page has been processed.
- Evidence:
  - `Services/Indexing/AppleNotesReaderService.swift:183-203` always stops its
    AppleScript loop after the first 40 Notes rows.
  - `Services/Indexing/AppleNotesReaderService.swift:79-87` filters already
    processed ids only after that fixed page is returned.
- Impact: notes outside the first page can remain invisible forever.
- Verification path: seed 41 eligible notes, complete one scan and assert a
  later scan reaches note 41.
- Minimal fix direction: sort and paginate deterministically or fetch enough ids
  to select the next unprocessed page.

### AUD-048 - P2 - Apple Notes edits do not refresh extracted memories

- Scenario: scan a note that produces a memory, then correct or delete the note.
- Evidence:
  - `Services/Indexing/AppleNotesReaderService.swift:145` parses `modifiedAt`.
  - `Services/Indexing/AppleNotesReaderService.swift:79-87`, `:350-358` dedup
    solely by presence of `apple-note:<id>` in any memory and never use the
    modification date.
- Impact: stale personal facts survive after the source note changes.
- Verification path: modify and delete a processed fixture note; assert the
  corresponding derived memories are refreshed or retired.
- Minimal fix direction: persist a source revision marker and reconcile derived
  rows when it changes.

### AUD-049 - P2 - Empty Apple Notes results are repeatedly sent to the LLM

- Scenario: an eligible Apple Note correctly yields no durable memory.
- Evidence:
  - `Services/Indexing/AppleNotesReaderService.swift:79-87` treats a note as
    processed only when a `UserMemory.sourceFile` marker exists.
  - `Services/Indexing/AppleNotesReaderService.swift:111-128` creates no marker
    when the model returns an empty list.
- Impact: unchanged notes with no memory value are uploaded again on every scan,
  wasting requests and expanding unnecessary cloud exposure.
- Verification path: mock an empty model response, run two scans and assert the
  second scan skips the unchanged note.
- Minimal fix direction: persist a source scan marker independently of extracted
  memories.

### AUD-050 - P2 - Durable logs contain private user content

- Scenario: dictate text, ask MetaChat a sensitive question or surface a
  proactive insight.
- Evidence:
  - `Services/System/FileLogger.swift:3-29` redirects `NSLog` to the durable
    `~/Library/Logs/MetaWhisp.log`.
  - `Services/System/TranscriptionCoordinator.swift:336-352`, `:388-405` logs
    transcript and processed-text prefixes.
  - `Services/Intelligence/ChatService.swift:112-118` logs question prefixes.
  - `Services/Processing/CorrectionDictionary.swift:112-171` logs input,
    replacements and output prefixes.
  - `Services/Intelligence/ProactiveContextService.swift:143-144` logs surfaced
    insight bodies.
- Impact: private speech, questions and extracted context remain in a plaintext
  diagnostics file after normal use.
- Verification path: run each surface with a unique marker and assert production
  logs contain no marker.
- Minimal fix direction: remove content logging in production and log only
  counts, ids and redacted diagnostics.

### AUD-051 - P2 - Turning Screen Context off does not retire stored OCR from MetaChat

- Scenario: capture screen OCR, disable Screen Context, then ask a typed MetaChat
  question during the next 24 hours.
- Evidence:
  - `App/AppDelegate.swift:857-868` stops monitoring on toggle-off but does not
    delete persisted rows.
  - `Services/Intelligence/ChatService.swift:108`, `:1039-1071` injects recent
    persisted OCR into typed chat without checking `screenContextEnabled`.
  - Repository search finds no ScreenContext purge path.
- Impact: text from screens the user stopped sharing can still be sent with chat
  prompts.
- Verification path: capture a unique OCR marker, switch the feature off and
  assert subsequent chat prompts exclude it.
- Minimal fix direction: define retention semantics explicitly; at minimum gate
  prompt injection on the current toggle and provide a purge path.

### AUD-052 - P2 - Integration save failures are reported as successful runs

- Scenario: force SwiftData save failure during file indexing, Apple Notes
  extraction or Calendar extraction.
- Evidence:
  - `Services/Indexing/FileIndexerService.swift:150-156`, `:240-246`,
    `Services/Indexing/FileMemoryExtractor.swift:119-121`,
    `Services/Indexing/AppleNotesReaderService.swift:133-135` and
    `Services/Indexing/CalendarReaderService.swift:351-353` discard save errors
    with `try?` and still log successful summaries.
- Impact: Settings can tell the user a scan or extraction completed while the
  database lost the write.
- Verification path: inject a failing persistence layer and assert the visible
  run state is failed.
- Minimal fix direction: surface save errors and only publish success after a
  committed save.

### AUD-053 - P3 - Proactive activity duration is not based on the capture cadence

- Scenario: leave one window active while Screen Context polls on its default
  interval.
- Evidence:
  - `Models/AppSettings.swift:127-130` defaults Screen Context to 30-second
    polling.
  - `Services/Screen/ScreenContextService.swift:218-230` persists only when app
    or title changes.
  - `Services/Intelligence/ActivitySummaryBuilder.swift:86-90` nevertheless
    estimates one captured row as one second.
- Impact: proactive LLM prompts present misleading activity durations and can
  distort advice.
- Verification path: aggregate known timestamped visits and assert duration is
  derived from timestamps or explicitly omitted.
- Minimal fix direction: compute durations from observation intervals, or label
  rows only as event counts.

### AUD-054 - P1 - Onboarding reports a local transcription model as ready without downloading it

- Scenario: fresh install -> onboarding -> Local transcription -> DOWNLOAD.
- Evidence:
  - `Views/Windows/Onboarding/OnboardingModelPage.swift:126-155` sends both model
    cards through the same timer-only `startDownload`; the TODO explicitly says
    the real downloader is not wired, then the timer sets `transcriptionEngine`
    to `ondevice`.
  - `Services/Transcription/ModelManagerService.swift:76-128` already provides the
    real model-specific `startDownload(_:)` implementation.
- Impact: a new user sees `Ready`, completes onboarding and reaches dictation with
  no downloaded Whisper model.
- Verification path: in a fresh profile choose each Local card, wait for
  completion, assert `ModelManagerService.isDownloaded(modelID)` and perform one
  dictation.
- Minimal fix direction: call the model manager with the selected model ID and
  derive progress and completion from its observable state.

### AUD-055 - P1 - Onboarding cloud API-key verification is a no-op

- Scenario: fresh install -> onboarding -> Cloud transcription -> enter API key
  -> VERIFY.
- Evidence:
  - `Views/Windows/Onboarding/OnboardingModelPage.swift:165-181` binds the API-key
    field to `.constant("")`; VERIFY only switches `transcriptionEngine`.
  - `Services/Transcription/CloudWhisperEngine.swift:65-80` requires a stored
    provider-specific key for free-user cloud transcription and throws when it is
    blank.
- Impact: onboarding claims cloud setup is available, but it cannot store or
  validate a key; the first transcription fails.
- Verification path: type a key during onboarding, verify it, then assert the
  selected provider key is persisted and a validation request or transcription
  uses it.
- Minimal fix direction: bind editable state, persist the selected provider key
  and make VERIFY perform a real validation before changing the engine.

### AUD-056 - P2 - Onboarding allows NEXT while required permissions are missing

- Scenario: onboarding -> Permissions -> deny microphone and Accessibility ->
  NEXT.
- Evidence:
  - `Views/Windows/Onboarding/OnboardingPermissionsPage.swift:11-17` defines the
    `allGranted` gate and `:31` labels both permissions as required.
  - `Views/Windows/Onboarding/OnboardingContainer.swift:80-89` renders an
    unconditional NEXT action; repository search finds no consumer of
    `OnboardingPermissionsPage.allGranted`.
- Impact: onboarding can finish while the primary dictation flow is unusable,
  without an explicit skip decision.
- Verification path: deny both permissions and assert NEXT is disabled or a
  clearly labeled skip confirmation is required.
- Minimal fix direction: wire the gate into the container, or explicitly design
  and explain a skip path.

### AUD-057 - P2 - Disabling Local AI does not unload the model or stop local routing

- Scenario: load Phi locally -> turn off `Use local model for AI features` ->
  trigger extraction.
- Evidence:
  - `Views/Windows/MainSettingsView.swift:1468-1477` binds the toggle only to
    `localLLMEnabled`; repository search finds no unload observer for that toggle.
  - `App/AppDelegate.swift:246-258` consults `localLLMEnabled` only during launch
    auto-load.
  - `Services/Intelligence/TaskExtractor.swift:118-125`,
    `MemoryExtractor.swift:108-114` and `StructuredGenerator.swift:330-331`
    route locally whenever `LocalLLMService.shared.isReady`, without checking the
    toggle.
- Impact: after opt-out the model remains in RAM and AI work can continue to run
  locally, contrary to the setting.
- Verification path: load the model, turn the toggle off, then assert it is
  unloaded and the next extractor chooses the configured cloud route.
- Minimal fix direction: centralize `localLLMEnabled && isReady` as the routing
  condition and reconcile unload immediately when the toggle changes.

### AUD-058 - P1 - Apple Foundation Models can be activated although no adapter exists

- Scenario: run on macOS Tahoe -> AI Models -> Apple Foundation Models -> Make
  active.
- Evidence:
  - `Services/LLM/ModelRegistry.swift:187-197` marks Foundation Models as
    recommended on macOS 26+.
  - `Views/Windows/MainSettingsView.swift:1716-1728` lets a compatible user set
    the Foundation model as active.
  - `Services/LLM/LocalLLMService.swift:115-118` rejects that same model because
    its adapter is not supported yet.
- Impact: Tahoe users can select an advertised active local model that cannot
  serve any generation. A free user without cloud access is left with inert AI
  features.
- Verification path: exercise the Tahoe compatibility branch and attempt a local
  completion after activation; it must either work or the activation control must
  remain unavailable.
- Minimal fix direction: hide or disable activation until the adapter ships, or
  implement the adapter before exposing the model.

### AUD-059 - P2 - MLX download cancellation can clobber the next download's state

- Scenario: download model A -> cancel -> immediately start model B while A is
  settling.
- Evidence:
  - `Services/LLM/MLXModelManager.swift:277-286` cancels the task and clears
    `activeDownloadID` synchronously, allowing another download to start.
  - `Services/LLM/MLXModelManager.swift:234-248` later handles the old task's
    completion or cancellation and clears the same shared state unconditionally.
- Impact: the completion of A can erase B's active state, lose progress display
  and reopen the UI to overlapping downloads despite the single-flight contract.
- Verification path: delay A's cancellation completion, start B immediately and
  assert B remains the owner of active state after A resolves.
- Minimal fix direction: attach an ownership token to each job and let only the
  current owner clear shared state, or keep the manager busy until cancellation
  has settled.

### AUD-060 - P2 - Local-model load failures are hidden after activation

- Scenario: downloaded local model has corrupt or incomplete tokenizer files ->
  Make active.
- Evidence:
  - `Views/Windows/MainSettingsView.swift:1825-1828` stores the active model ID and
    suppresses `loadModel` errors with `try?`.
  - `Services/LLM/LocalLLMService.swift:111-170` throws load failures but only
    clears `lastError` after success; it does not surface the failure state.
- Impact: settings keep showing an active selection that never becomes ready,
  without an actionable error.
- Verification path: force tokenizer initialization to fail and assert an inline
  error is rendered and the active selection is reconciled.
- Minimal fix direction: catch the error, publish it for the UI and either roll
  back activation or clearly present a retry state.

### AUD-061 - P3 - Calendar permission copy promises task creation that was removed

- Scenario: user reviews Calendar consent or enables Calendar in Settings.
- Evidence:
  - `Resources/Info.plist:50-53` says Calendar access creates tasks for upcoming
    events.
  - `Views/Windows/MainSettingsView.swift:1911-1916` repeats the same promise.
  - `Services/Indexing/CalendarReaderService.swift:335-342` explicitly documents
    that automatic Calendar task creation was removed.
- Impact: consent text and settings misrepresent what access does.
- Verification path: review the shipped permission dialog and Settings copy
  against the enabled Calendar behaviors.
- Minimal fix direction: describe event display, meeting enrichment and routine
  memory extraction without promising automatic tasks.

### AUD-062 - P3 - Released-app integration help buttons cannot find their setup docs

- Scenario: install the packaged app outside the source checkout -> Settings ->
  Integrations -> open Claude, Cursor or ChatGPT setup help.
- Evidence:
  - `Views/Windows/MainSettingsView.swift:1422-1436` expects docs at
    `Contents/Resources/integrations/`, then falls back to a developer checkout
    under `/Users/<name>/Code/MetaWhisp/specs/integrations/`.
  - `build.sh:59-91` copies sounds, video and SPM resources, but not integration
    docs.
  - `Package.swift:44-53` excludes `Resources` and only adds sound, icon and movie
    resources; the setup docs live only under `specs/integrations/`.
- Impact: the packaged-app help buttons silently do nothing except log a missing
  file.
- Verification path: package the app, move it to a clean account without a source
  checkout and click all three help buttons.
- Minimal fix direction: copy the docs into the release resources or open stable
  hosted documentation URLs.

### AUD-063 - P2 - Release readiness does not enforce Sparkle feed publication

- Scenario: build a signed release DMG -> complete `release.sh` -> forget the
  website deploy step.
- Evidence:
  - `release.sh:183-194` prints `RELEASE READY` before listing appcast update and
    website deploy as manual next steps.
  - `Resources/Info.plist:64-69` enables automatic Sparkle checks against
    `https://metawhisp.com/appcast.xml`.
- Impact: a release can be called ready and published while existing users remain
  on the previous version because the update feed was omitted or stale.
- Verification path: run the release workflow with an older feed and assert the
  gate fails until feed version, build number, enclosure and signature match the
  DMG.
- Minimal fix direction: validate or publish the appcast before the script reports
  success. Live check on 2026-05-31: the public feed is currently synchronized at
  `1.3.9` build `14`.

### AUD-064 - P2 - Release smoke test ends before local-model auto-load finishes

- Scenario: release build starts with an active local model in preferences.
- Evidence:
  - `App/AppDelegate.swift:241-258` documents that local-model auto-load completes
    in roughly 12 seconds after launch.
  - `release.sh:156-181` keeps the smoke-launched process alive for only 5 seconds
    before killing it and reporting success.
- Impact: tokenizer, weight-load and delayed local-AI failures can escape the
  release smoke gate.
- Verification path: smoke-launch with an active downloaded Phi fixture, wait for
  readiness and run a minimal completion before accepting the release.
- Minimal fix direction: add a readiness-aware local-AI smoke branch and wait for
  its terminal result rather than using a fixed 5-second process-survival check.

## Hypotheses Requiring Live Verification

- HYP-001 - P3 - `TextInsertionService.insertResult` returns `.autoPasted`
  before the delayed CGEvent is created and posted (`Services/System/TextInsertionService.swift:63-77`).
  Clipboard recovery is still available, but the success signal can be optimistic.
- HYP-002 - P3 - Apple Notes bodies containing the literal delimiters `|||`
  or `<<<END>>>` can be split incorrectly by the AppleScript bridge
  (`Services/Indexing/AppleNotesReaderService.swift:181-216`). Exercise this
  against live Notes; if reproduced, replace the delimiter protocol with a
  structured encoding.
- HYP-003 - P1 - Loading or unloading a local model while a generation is in
  flight may overlap process-wide MLX work. `LocalLLMService.generate` serializes
  generations behind `pendingGeneration` (`Services/LLM/LocalLLMService.swift:290-328`),
  but `loadModel` starts separate GCD work without waiting for that queue
  (`:141-150`). Stress this on a real MLX host; if reproduced, serialize model
  lifecycle and generation under one owner.

## Manual-Only Verification Matrix

- TCC onboarding: deny, grant and revoke Microphone, Accessibility, Screen
  Recording and Calendar access; verify explicit UI state and recovery paths.
- Dictation insertion: exercise delayed CGEvent auto-paste, clipboard fallback,
  suspect-text recovery and clipboard-content restoration in multiple target apps.
- Meeting lifecycle: start and stop during recorder startup, dual-stream chunks
  with asymmetric silence, one-channel transcription failure, manual recordings
  after a matched calendar call and calendar-end silence decisions.
- Screen privacy: capture an overlapping-window desktop, blacklist and whitelist
  apps, turn Screen Context off after stored OCR exists, then test typed and voice
  MetaChat prompts plus proactive extraction.
- License and network: activate, verify, deactivate, go offline and inspect logs;
  confirm secrets never enter URLs, logs or plaintext preferences.
- Local transcription onboarding: select Large and Tiny independently, interrupt
  downloads, relaunch, complete setup and perform a real dictation.
- Local AI: download Phi, activate, generate, toggle off, relaunch, corrupt a
  tokenizer fixture, cancel and restart a download, and stress load or unload
  during generation. On Tahoe, verify Foundation Models is unavailable until its
  adapter exists.
- Integrations: exercise Obsidian OFF, rename and path collisions; file edit,
  delete and folder removal; Apple Notes with more than 40 rows, edited notes,
  empty notes and delimiter text; Calendar permission copy and memory extraction.
- MCP: verify explicit opt-in, filesystem permissions, refresh after every
  supported mutation and the distinction between staged OCR candidates and
  accepted tasks.
- Packaging: install a signed DMG into a clean account, click integration help,
  smoke local-AI startup past readiness and compare Sparkle feed metadata with the
  packaged DMG.

## Verification Log

- [x] `git diff --check origin/architecture-phase-1-3...HEAD`
- [x] clean committed `HEAD`: `swift build`
- [x] clean committed `HEAD`: `swift test` - 375 tests, 0 failures
- [x] tracked-file scan for common committed secret formats and secret filenames
- [x] live `https://metawhisp.com/appcast.xml`: version `1.3.9`, build `14`
- [x] Full-app static audit complete
- [x] Manual-only matrix documented

## Notes For Bugfix Handoff

- Fix one finding per TDD iteration and atomic commit.
- Do not include the local `TaskExtractor.swift` draft unless the owner explicitly
  chooses to promote it.
- Existing green tests do not cover the proven findings above.
- Static review cannot prove the absence of all runtime defects. Run the
  manual-only matrix as part of the bugfix campaign and release gate.
