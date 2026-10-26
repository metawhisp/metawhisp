# ITER-075 — One assistant core: complete data, one search, chat and voice, errands

**Status:** draft plan, 2026-09-25 — awaiting the owner's decisions (see the end).
**Reviewed:** by Codex, 2026-09-25: 13 findings, 2 of them critical. Each was checked against the code,
all 13 hold, and each is folded into its step, marked "Codex review Fn". Record:
`evidence/ITER-075/codex-plan-review.md`.
**Input:** three read-only audits run in parallel on 2026-09-25 (Codex: the chat's retrieval; Claude:
the meeting pipeline; Claude: capabilities and one agent core), each checked against the code by the
orchestrator before it was written here.

## The owner's goal
"The chat is not connected to the base and does not search it properly. This must be built into the
agent's core. I want to run the agent from the chat and by voice, and the agent must do every popular
command." — owner, 2026-09-25.

## Foundation: Jev (owner, 2026-09-25)
"Jev — это основа нашей архитектуры." Jev, the decision engine of ITER-074 (decision 12; phase 2 adds
Laya on the Mac), is the core's decision-maker:
- **At the entry:** for every request — voice or chat — Jev decides what it is: a question, a command, or
  an errand for the browser (ITER-074 §3.1, the router).
- **Inside an errand:** Jev chooses every action in the browser and answers whether it is irreversible.
- An LLM only writes text — answers, table rows, drafts — and never decides a step.
`JevEngine` is not built yet (ITER-074 I-0.5): it needs an accuracy check on the owner's own phrases
before the core can route through it. Jev's documentation and the key are settled (2026-09-26): Jev is
reached through OpenRouter with the owner's OpenRouter key (`evidence/ITER-075/3.0-jev-live-check.txt`).

## What the audits found — causes, not symptoms

### 1. The data the chat reads is incomplete (the meeting pipeline) — Confirmed
- **Meetings stuck unfinished (45 in total; 12 of 115 in the last 30 days — store, 2026-09-25).**
  `ConversationGrouper.assign` reopens a meeting
  saved within 600 s of another with the same `callContext` — `status = "inProgress"`, `finishedAt = nil`
  (`Services/Intelligence/ConversationGrouper.swift:132-153`) — and nothing ever closes it again:
  `closeConversation(id:)` has no callers, `closeStaleConversations` skips meetings, reopened rows are
  never processed.
- **What drives meetings into that path:**
  - a recurring calendar event is looked up with `store.event(withIdentifier:)`
    (`Services/Indexing/CalendarReaderService.swift:108-112`), which returns the series' first
    occurrence: its end time is in the past, so the end check fires about 1 s into the meeting, the
    meeting is stopped early, restarted by the 60 s retry, and the short retry is merged back;
  - back-to-back meetings: the call label is read when the transcript is saved, not when recording
    started, and is never cleared on stop (`App/AppDelegate.swift:2577`, `:1908-1912`, `:2956`).
- **To-dos and decisions missing.** Structured fields are made once, 2 s after a new row
  (`ConversationGrouper.swift:225-236`); a second run while one is in flight is silently dropped (the log
  line saying "dropped" prints on every run, dropped or not — `StructuredGenerator.swift:235-236`); a run
  without LLM access exits and nothing re-queues it, which is why today's recaps are blank; reopened
  rows are never processed; the per-launch project backfill re-runs the same 200 rows every launch and
  clears title and overview before its call — a relaunch mid-pass leaves the row blank
  (`Services/Intelligence/ProjectAggregator.swift:587-597`, `:316-321`, `StructuredGenerator.swift:149-154`).
- **Reminder spam.** The same wrong end time fires the "still recording" card 1 s after start, then every
  5 minutes, up to 3 per recording, reset for every retry (`AppDelegate.swift:3040-3147`): 28 cards in
  about 3 days of logs.
- **Lost recordings.** Quitting while recording leaves audio in Recovery WAVs that are never imported and
  are deleted after 7 days; quitting during transcription loses the meeting (`AppDelegate.swift:2654-2686`,
  `MeetingShutdown.swift:35`).

### 2. The chat cannot find what is there (retrieval) — Confirmed
- The chat IS connected to the store; its search is the problem.
- No tool searches or returns a full transcript. The prompt holds 3 meetings × 1,500 characters
  (`Services/Intelligence/ChatService.swift:105`); conversation embeddings cover the first 1,200
  characters only.
- `searchConversations` matches title and overview only, has no date filter, and returns neither the
  transcript nor action items or decisions (`Services/Intelligence/ChatToolExecutor.swift:501-527`).
- Relative dates ("last Friday") are left to the model; only the Pro path is given today's date.
- Names are matched as plain substrings: a company spelled five ways across calendar, transcript,
  tasks and memories is not one entity. Transliteration exists for projects only
  (`ProjectAliasNormalizer.swift`).
- Semantic search has no relevance threshold; a failed fetch is reported as an empty result; a search
  made on the last tool round never reaches the model.

### 3. There is no single core — Confirmed
- Voice questions already go through the chat service (`Services/System/TranscriptionCoordinator.swift:458`),
  but there is no intent router, the ITER-074 browser agent has no production caller, and the chat's tool
  names are kept by hand in six lists and four switches. Today the chat's LLM picks the tool — against the
  foundation rule below.
- Popular commands today: tasks and memories (yes); what was said or decided in a meeting, what I promised,
  summarise a call (partial — the data is not read); calendar, reminders, create an event, open an app or
  site, timers (missing); web research into a table (fixtures only); fill a web form from my data (not
  planned in ITER-074).

### 4. Code check of every step (2026-09-25) — Confirmed
Five read-only checks of the code, the log and the store. The file-by-file changes and the tests to
write first are in `evidence/ITER-075/`: `step0-code-check.md`, `step1-code-check.md`,
`step2-code-check.md`, `steps3-4-code-check.md`, `steps5-6-code-check.md`. These facts were not in the
audits above:
- **Installs:** `hot-swap.sh` deletes `/Applications/MetaWhisp.app` with no backup and sends codesign's
  output to /dev/null. A signing failure stops it silently, with the app dead. `build.sh` falls back to
  ad-hoc signing and kills the working app (`pkill -f MetaWhisp.app`). The app has no SIGTERM handler,
  so a kill skips the meeting rescue.
- **Recording:** the 10-minute floor never applies on the first arm, because the start time is not set
  yet. A stop that kept audio is retried anyway: one occurrence today gave 3 recordings and 4 cards.
  The gate keeps its state in memory, per series: a relaunch restarts a meeting the owner stopped by
  hand, and a hand stop on one day blocks the next. "Recording saved" is posted before a discard.
  Quitting during transcription loses the audio.
- **Chat:** it sees the newest 50 meetings, about a week. The average transcript is 14,237 characters,
  and the chat reads 1,500 of them. 149 completed meetings have no title, and the conversation search
  never sees them. The path with the user's own key sends `{{CURRENT_UTC}}` unreplaced, and the local
  path has no clock. MCP matches only the whole query, verbatim.
- **Voice:** a voice question is saved as a dictation, with summary and extraction, before it reaches the
  chat. The popup can hang on "thinking": four early returns in `send` never close it (no Pro is one).
- **Open for the owner:**
  - Jev's API documentation (step 3).
  - Chrome or Dia: ITER-074 says Dia, this plan says Chrome (step 5).
  - Where form facts come from: there is no structured email or phone, only free-text memories
    (step 6).

## How it fits together

```
voice (Right ⌘) ─┐
                 ├─► AssistantCore.handle(request) ──► Jev: route ──┬─ question ─► Retrieval ─► LLM writes the answer (text only)
chat window  ────┘        (step 4)                    (steps 3–4)  ├─ command ──► ToolRegistry ─► Yes/No by safety class
                                                                    └─ errand ───► AgentQueue ─► AgentRun: Jev picks each step,
                                                                                    LLM writes rows ─► Chrome ─► Google Sheets (step 5)

meetings ─► meeting pipeline (step 1) ─► store ─► Retrieval (step 2) ◄── chat, voice, screen agent, MCP, errands, forms (step 6)
```

- **Jev decides; LLMs write.** Jev answers typed questions — which route, which candidate action, is it
  irreversible. An LLM writes answers, table rows and drafts, and never picks a step (ITER-074 decision 12).
- **One search.** Every consumer asks one `Retrieval` service; nothing keeps its own copy of a search.
- **Data first.** A search is only as good as what is stored, so the meeting pipeline is fixed before the
  search is built on it.
- **Every change keeps the working app safe.** Test builds run as a separate app (step 0); the owner's
  MetaWhisp only gets released builds.

## How every step runs
The same loop as ITER-074: detailed instructions → GLM-5.3-Flash writes tests first (red) → the code
(green) → `bash scripts/regression.sh` PASS → Codex review, every finding checked against the code and
fixed test-first → live check in **MetaWhisp Dev** → a Sparkle release to users → `PROGRESS.md` updated.
New prompt text is never invented: ported from references and approved by the owner before commit.
Tests are English-only (owner rule, 2026-09-23); Russian phrase coverage waits for the owner's decision.
Estimates below are rough, from today's pace, and are corrected after each step.

---

## Step 0 — A safe install, and permissions that stay

**Why.** On 2026-09-25 a test build replaced the working app: signing failed after the app had been
killed, an ad-hoc signature brought it back, and macOS then treated MetaWhisp as a stranger — the
Accessibility, Screen Recording and Automation grants no longer matched, global hotkeys and the layout
fix stopped, a call went unrecorded, and the Pro session was lost. Permissions are keyed to the code
signature; any build with another signature breaks them.

**User stories**
- **US-0.1 — test builds never touch my app.** As the owner, I want test builds to run as a separate
  app, so that my calls, dictation and permissions keep working while the agent is built.
  - Test builds run as "MetaWhisp Dev": its own bundle id, name and icon, its own data store, keychain
    service, preferences domain and logs.
  - Installing or running a Dev build changes nothing of `/Applications/MetaWhisp.app`: not its store,
    keychain items, preferences or permission entries.
- **US-0.2 — an install that cannot break my app.** As the owner, I want a failed install to leave my
  app as it was, so that a signing problem never costs me a call.
  - The install test-signs a throwaway file with the Developer ID identity before anything else and
    stops, touching nothing, if that fails.
  - It refuses while a recording or a transcription is running.
  - It never signs ad-hoc, and it verifies the Developer ID signature before it relaunches.
  - The release smoke test never touches the owner's data (Codex review F1). Today it launches the
    notarized copy with the production identity (`release.sh:168-176`), which opens the owner's store
    (`HistoryService.swift:29`), keychain items and log. It runs isolated instead.
    - Proposed: a self-check launch with an in-memory store, no keychain, no network and no capture,
      which exits by itself. A test proves the store, the keychain items and the log unchanged afterwards.
    - Built in 0.6b: `MetaWhisp --self-check` exits before the app exists, which is stronger than an
      in-memory store: no store, keychain, log, network or capture code runs at all.
    - The proof is two tests:
      - an end-to-end test runs the app binary the tests are built with, outside a bundle (so with the
        Dev identity), with `--self-check` in a throwaway home, and finds that home empty afterwards;
      - a source guard pins `Launch` as the only entry point, with the self-check as its first
        statement, and keeps the store, keychain, log, network and singletons out of both files.
    - What has actually run so far (2026-09-26): only that unbundled debug binary. It printed its three
      check lines and exited by itself, and the owner's log gained no line from it. It has no metallib, so
      the MLX check was skipped. The self-check has not yet run on a real bundle; that is part of 0.7.
- **US-0.3 — a permission works the moment I grant it.** As the owner, I want MetaWhisp to pick up
  a permission as soon as I grant it, so that I never have to restart it.
  - Hotkeys, the layout fix and screen capture re-arm when Accessibility or Screen Recording is granted.
    Today the watcher gives up after 600 s and waits for the next launch
    (`HotkeyService`: "still not trusted after 602s").
  - The watcher has no give-up: it re-checks on every app switch and on a timer — MetaWhisp is a menu-bar
    app, so its own activation is rare — and a grant made any time later still takes effect (every gate
    needs a release).
- **US-0.4 — Pro never silently disappears.** As the owner, I want a keychain that cannot be read to be
  reported as an error, not as "signed out", so that my Pro session is never lost.
  - `KeychainHelper` tells "no item" (`errSecItemNotFound`) from "cannot read it" (an access error).
  - An access error never clears the session and shows the owner what to do.
  - *Found in the code check:* the Pro items were lost on the write path. `activate()` deletes an item,
    then adds it, and throws the add's status away (`AppSettings.swift:526-530`, `:501`). At 10:58 the
    keychain refused access, so the add failed after the delete, while the log said "Pro activated".
    None of the five items exists now (checked with `security`, attributes only). Writes become
    update-or-add and report their failures.
- **US-0.5 — (owner) sign in to Pro again.** One action; nothing that needs an LLM works until then.

**How (technical).** Details are in `evidence/ITER-075/step0-code-check.md`.
1. `AppIdentity` (new, `Services/System/`) is the one source for:
   - the store URL, the support folder, the keychain service, the log file and the URL scheme;
   - the updater default and the global-input default.

   Production values equal today's literals, and the Dev flavour gets its own. Every hardcoded literal
   (nine-plus places) reads from it.
2. The Dev build's Info.plist is generated from `Resources/Info.plist`:
   - bundle id `com.metawhisp.app.dev`, name "MetaWhisp Dev", its own URL scheme and icon;
   - no Sparkle feed;
   - installed at `~/Applications/MetaWhisp Dev.app`;
   - global hotkeys and the layout fix off by default.
3. `hot-swap.sh` installs only the Dev app. It runs:
   - a preflight test-sign;
   - a busy check, through `ActivityLease` and a new `activity.json`;
   - build and sign in a temp dir;
   - backup → install → verify → relaunch.

   It restores the backup on any failure and never touches `/Applications/MetaWhisp.app`.
   - `build.sh`: no ad-hoc fallback, and no `pkill` of the working app.
   - `release.sh`: an isolated smoke test (F1). Built as a self-check, it lets `release.sh` stop
     stopping the working app altogether, so it needs no busy gate (0.6b).
4. `KeychainHelper`:
   - `read` returns value / not found / failed(status);
   - `write` is update-or-add, never delete-first;
   - failures are logged by account and status.

   `LicenseService`: an unreadable item never signs the owner out, and a failed write is reported.
5. `PermissionMonitor` (new) is the only owner of the Accessibility and Screen Recording state.
   - It re-checks on every app switch, on activation and on a timer, and never gives up.
   - On a grant it re-arms the hotkeys, the layout fix and screen capture.
6. SIGTERM is handled, so a kill becomes a normal quit and the meeting rescue runs.

**Checklist (each item: GLM tests first → code → gate → review → commit)**
- [x] 0.1 `AppIdentity` (`6d4d494`) — one address book for the store, the support folder, the keychain service,
  the log and the URL scheme; production values unchanged (US-0.1).
- [x] 0.2 (`318e556`) The keychain tells "missing" from "unreadable"; writes never delete first; Pro is never
  lost silently (US-0.4).
- [x] 0.3 `PermissionMonitor` (`46ab8ba`) — Accessibility and Screen Recording re-arm when granted, with no
  give-up (US-0.3).
- [x] 0.4 (`40aa9c3`) Dev flavor behaviour: a copy that is not the owner's app behaves as a guest.
  - The updater is off (`AppIdentity.updatesItself`).
  - Global hotkeys, ⌘⌥O and the layout fix are off by default (`globalInputEnabled`, no UI).
  - It never deletes the shared speech and LLM models (`mayDeleteSharedModels`;
    `ModelManagerService.removeBrokenModel`, `MLXModelManager.remove`).
  - Tests stop downloading into the shared model folder: under XCTest a download waits offline.
  - Vault export already counts as off: every vault writer checks `obsidianSyncEnabled`, which defaults to
    false, and a Dev app starts with fresh defaults.
  - Moved to 0.6: the Info.plist's own bundle id, name, icon and scheme, with no Sparkle feed. The scripts
    generate it.
  - Known limit (review of 0.4, F5): a Dev copy's model load or RETRY can rewrite files in the shared
    cache (WhisperKit and the Hugging Face downloader replace files). **Open question Q3 for the owner:**
    should the Dev app share the model caches read-only, or keep its own copies (gigabytes)?
- [x] 0.5 (`5235ed1`) `ActivityLease` (`activity.json`) and a SIGTERM handler (US-0.2).
  - The lease holds pid, executable, state and since. Only the process that wrote it writes idle at quit.
  - The quit starts from a run-loop timer: started from the signal's main-queue block, a quit during a
    meeting would hang (review of 0.5).
  - `hot-swap.sh` is off until 0.6.
  - Known limits for 0.6: an unbundled `swift run` shares the Dev lease file; a quit held up by an open
    dialog is still pending when the script gives up, so the script says so.
- [x] 0.6 Scripts (US-0.2; plan review F1; review of 0.1, F2; Info.plist moved here from 0.4), in two commits:
  - [x] 0.6a (`72d6b88`): `build.sh --dev` builds and installs "MetaWhisp Dev" only. There is no ad-hoc
    fallback and no `pkill`. The release bundle stays in `.build`, and nothing is installed or launched
    from it.
    - What the install does:
      - a signing test before anything else;
      - no install while the Dev app is busy, checked twice;
      - the Dev app quits by SIGTERM only;
      - backup, verify, launch, then 3 s still running;
      - rollback on any failure or interrupt;
      - one install at a time.
    - Review round 1: an interrupted rollback could lose the Dev app. Fixed; round 2 accepted.
    - Owner step still open: `~/Applications/MetaWhisp.app` is an old copy of the working app that the old
      `build.sh` left there. Deleting it is the owner's call.
  - [x] 0.6b (`d6efb80`): the release smoke test runs `MetaWhisp --self-check`, which exits before the
    app opens any data. With that, `release.sh` no longer stops the working app, so no busy gate is
    needed there. The check never hangs a build or a release.
    - Review round 1 found no proof and a possible hang; both fixed. Round 2 accepted.
    - Not covered, and recorded in release.sh: the app's own startup code, and a dropped entitlement.
      A read-only entitlements comparison is a possible follow-up.
  - Not in 0.6: the Dev app's own icon. It shows the same icon, and its name "MetaWhisp Dev" tells the two
    apart in System Settings and in notifications.
  - `hot-swap.sh` installs the Dev app only, with a preflight, a busy gate and backup/rollback;
  - `build.sh` has no ad-hoc fallback and no `pkill` of the working app;
  - `release.sh` has an isolated smoke test and never stops the working app (0.6b; no busy gate needed);
  - the Dev app is signed with its own `--identifier` (today `hot-swap.sh:83` and `build.sh:259` force
    `com.metawhisp.app`), and its executable is renamed, so `pkill -x MetaWhisp` (`hot-swap.sh:45`,
    `release.sh:60`) can't kill the wrong app.
- [ ] 0.7 Live check, as in the Definition of Done below.
  - The first real `build.sh --dev` must print the self-check's three lines, MLX on the GPU included, and
    `SELF-CHECK OK`. Keep that output as evidence.
  - In the Dev app: start a meeting, then send `kill -TERM`. Expect the log lines "SIGTERM —",
    "quit rescue done" and "Terminating", and the pid gone within 7 s. The lease should read
    "transcribing" during the quit and "idle" after it.

Until 0.4 and 0.6 are done, no Dev app and no unbundled `swift run` runs beside the owner's app. An
unbundled run already takes the Dev identity, and with it the global hotkeys and the model-delete
paths.

**Definition of Done**
- US-0.1 to US-0.4 pass their tests.
- A Dev build is installed and run beside the working app on the owner's Mac, and afterwards the working
  app's log shows `accessibility=yes`, `screen=yes`, `pro=YES`, with no permission re-granted.
- Gate PASS, Codex review clean, released.

**Depends on:** nothing — it is first. **Owner:**
- sign in to Pro;
- re-toggle Accessibility now;
- grant the Dev app its own permissions once;
- allow codesign to use the Developer ID key once (the install's preflight needs it).

**Risks:** a Dev app that shares anything with the working app would carry the same breakage, so the
separation must be complete. **Estimate:** about 2–3 days. It grew with the code check: nine-plus
hardcoded identity values, the permission monitor, and the isolated smoke test.

---

## Step 1 — Every call recorded once, with a summary and to-dos, and no reminder spam

**User stories**
- **US-1.1 — every call recorded once, whole.** As the owner, I want every call recorded once, from its
  start to its end, so that nothing is missing when I ask about it.
  - A recurring calendar meeting is not stopped early: its end time is the current occurrence's
    (`CalendarReaderService.swift:108-112` returns the series' first).
  - Back-to-back calls become separate conversations, each with its own title: the call label is taken
    when recording starts and cleared when it stops (`AppDelegate.swift:2577`, `:2956`, `:1908-1912`).
  - No meeting stays "inProgress" after its recording has ended — relaunches included.
  - All 45 stuck meetings are closed and processed once.
- **US-1.2 — a summary and to-dos for every call.** As the owner, I want a summary, decisions and to-dos
  for every call, so that I know what I promised.
  - Structured generation is attempted for every meeting above a minimum length.
  - It is queued, never dropped while another run is in flight, and runs for reopened meetings too.
  - A failed run is retried at most 3 times with a growing pause, then shown as failed (never silently
    left blank).
  - The project backfill never blanks a title or an overview, and never re-runs a meeting it has checked.
  - Backfill and reclassification pass an explicit regeneration mode. Today they blank the fields to get
    past `generate()`'s "already structured" check (`StructuredGenerator.swift:256`). The old fields
    stay visible until the new result is saved, and "checked" is written only after a successful save
    (Codex review F10).
- **US-1.3 — reminders only when needed.** As the owner, I want a reminder only when something really
  needs me, so that I am not spammed.
  - "Still recording" fires only after the real occurrence end plus the 10-minute floor, and at most 3 times
    per occurrence — not per recording.
  - A prompt I dismissed is not shown again for that occurrence.
  - "Recording saved" is shown only when something was saved; "call started" is not repeated within one
    call.
- **US-1.4 — a cut recording is saved anyway.** As the owner, I want a recording cut by a quit or a crash
  to be saved, so that I never lose a call.
  - Recovery audio is transcribed and saved as a conversation at the next launch, not deleted after 7 days.
  - A quit during transcription finishes it or leaves it for the next launch.
  - Audio is written to disk while recording (Codex review F2):
    - per channel, in short chunks with a manifest, from a writer that runs off the audio thread;
    - a crash loses at most the last chunk (target: 10 s or less);
    - today both channels live only in memory (`AudioRecordingService.swift:636`,
      `SystemAudioCaptureService.swift:311`), so a crash loses the whole call.
  - The Recovery WAVs already on disk have no manifest. They are listed and kept before the cleaner
    changes, and the cleaner never deletes a file that was not imported (F7).
  - Every import runs once. A stable recovery ID is committed with the imported item, or in a receipt
    written after the save, so a crash between the save and the delete never duplicates a call (F7).
  - Tests: a crash during recording, a crash during transcription, save-then-crash, a repeated launch,
    and a missing channel.

**How (technical).** Details are in `evidence/ITER-075/step1-code-check.md`.
1. `CalendarOccurrence` (event id + occurrence date + start/end) is carried from the calendar tick to
   the stop. A fire-time re-read uses `events(matching:)` in a date window, and
   `event(forIdentifier:)` is removed.
2. `CalendarOccurrenceLedger` (JSON on disk) replaces the gate's memory-only state.
   - It records, per occurrence: attempts, declined, captured, cards and dismissed.
   - Each entry expires at end + 1 h.
   - There is no retry after a stop that kept audio.
3. The first end check fires at `max(end + 60 s, start + 10 min)`. Cards are counted per occurrence,
   up to 3, and a dismissed card ends them.
4. `MeetingSession` fixes the label, the occurrence and the start time at start, is cleared at stop,
   and is passed into the save.
5. The grouper appends only for the same occurrence, within 600 s of its end, and a meeting never
   becomes `inProgress`. A one-time repair completes the 45 stuck rows and queues them.
6. The structured queue lives on disk.
   - It waits for Pro, a key or the local model.
   - 3 attempts, 1/5/30 min apart.
   - An explicit regeneration mode; no blank-first writes; "checked" is written after the save.
7. Durable recording:
   - chunked per-channel files and a manifest, written while recording;
   - a recovery importer at launch, with receipts;
   - the cleaner deletes only files that were imported;
   - "Recording saved" is shown after the save.

**Checklist (each item: GLM tests first → code → gate → review → commit)**
- [x] 1.1 (`abf26be`) The occurrence and the first end check (How 1, and the floor from How 3).
  - The start arms its end check with the occurrence's own end.
  - The 10-minute floor counts from the session start, taken before the recorder starts.
  - No live code looks an event up by its identifier; a guard test enforces it.
  - Review round 1: dead code patched, a guard that could pass vacuously, weak test names, two
    parameters for one event, a pick that depended on EventKit's order. All fixed; round 2 accepted.
  - Deferred to 1.2:
    - the fire-time re-read (the end decision already accepts an end edited mid-meeting);
    - `Decision.calendarReady(occurrence:)`;
    - keying on the occurrence date.
- [ ] 1.2 `CalendarOccurrenceLedger` and the gate per occurrence (How 2 and the rest of How 3).
  - Carry the occurrence in `Decision.calendarReady`.
  - Key the ledger on `EKEvent.occurrenceDate`, falling back to the start, so a moved occurrence keeps its
    entry (review of 1.1, F6). `BackToBackTransition`, `recordingCalendarEventID` and `decline` move
    with the gate.
  - A gate answer with no occurrence today leaves the recording with no calendar id at all. That means
    no end check, no back-to-back, and no decline on a hand stop. It cannot happen in 1.1; re-keying
    must keep it impossible (review of 1.1, nit 1).
  - The Dashboard finds a row's conversation by series id only and uses that id as the row id
    (`Views/Windows/DashboardView.swift:922-931`, `:1621`). Match on the occurrence start as well, and
    use `CalendarOccurrence.key` (review of 1.1, F5).
  - Owner decision first (code check Q3): no automatic restart after a stop that kept audio?
- [ ] 1.3 `MeetingSession` and the grouper (How 4–5). Owner decision first (code check Q2): does a
  manual recording during a calendar occurrence take that occurrence?
- [ ] 1.4 The one-time repair of the stuck meetings (How 5).
- [ ] 1.5 The structured queue (How 6).
  - [x] 1.5a (`da06c54`) Every summary goes through a queue on disk, and runs take turns.
    - The causes:
      - a summary ran once, at the close; without access or on a failure, nothing ran it again (the blank recaps
        of 2026-09-25);
      - a run handed in while another was going was dropped;
      - 522 completed conversations had no title (149 meetings, 373 dictations; store count, 2026-09-26);
      - a history item's link to its conversation was saved only by its caller's context;
      - the Pro proxy answered 502 for every failure, so an outage looked like a bad conversation.
    - Built:
      - runs take turns (`RunTurns`);
      - the close links the calendar, runs its own summary, then starts memories and tasks;
      - the queue waits for access, and is released at launch, when the local model is ready, and when the cloud
        setup changes;
      - a failed run is retried after 1, 5 and 30 minutes: four runs in all, as US-1.2 asks;
      - a run the service turned away is not counted. The cloud rests 1, 5, then 30 minutes, and that conversation
        waits twice as long at its own count, so the others go first;
      - two failed runs in a row stop a drain, and a drain that stopped early always leaves a timer;
      - the 522 untitled conversations are queued once, newest first;
      - the link is saved where it is written.
    - The proxy, a Cloudflare worker, was changed with the owner's OK and deployed on 2026-09-26:
      - 503 when it cannot take a run (an outage, a spend block, or a deadline);
      - a provider's refusal of the request passes through as 4xx;
      - 422 for an empty answer;
      - an optional `deadline_ms`; the summary asks for 25 s.
    - Review:
      - round 1: a retry timer that could spin, outages that dropped conversations, a close that waited for the
        whole backlog;
      - round 2: an unsaved link that could lose a meeting's tasks, and 502s still dropping conversations;
      - round 3: I stopped and asked the owner, who approved the worker fix;
      - round 4: the spend block and the missing deadline, fixed in the worker;
      - round 5: accepted. Its follow-up delta was rejected and rolled back (see 1.5b).
  - [ ] 1.5b:
    - the failed set, and the Library states "waiting for Pro" and "summary failed";
    - Regenerate through the queue, first, with feedback for the button;
    - the placeholder and project backfills through the queue;
    - after an outage, a conversation turned away during it still waits out its own pause, up to an hour.
      Release those pauses without letting two conversations that keep failing on their own hold the others back
      (review of 1.5a, round 5 and its follow-up).
  - Recorded for later (review of 1.5a):
    - each run of an older conversation loads every history row on the main actor (9,868 rows, 2026-09-26);
    - a run that never returns blocks every later summary, and the local path has no deadline;
    - the project backfill may regenerate a swept conversation from before 2026-04-25; this is tied to the owner
      decision on that pass;
    - `RunTurns` repeats `LocalLLMService`'s chain;
    - the memory and task queues still count a refused key or an outage as a failure;
    - in the worker:
      - one deadline covers both providers;
      - the account-block match knows one wording;
      - the Cerebras fallback's model ids are stale.
  - Owner decisions:
    - may older conversations use the local model, one at a time and capped? Until then they wait for Pro or a key;
    - a conversation that the service keeps turning away on its own (an unknown case; BYOK only now) is retried
      at a pause that grows to an hour and never counted: keep that, or count it after a while?
- [x] 1.6 (`2d5eaa3`) The backfills without blank-first writes (How 6; code check C9).
  - `generate()` returns an outcome, and `written` means saved. The three backfills ask for a regeneration and
    clear nothing.
  - A short transcript keeps a real title. The project backfill checks each conversation once (a list on disk).
  - Review: round 1 found an unsaved result counted as written, a history-wide re-run and tests that proved
    too little; round 2 raised four follow-ups. All fixed and accepted.
  - **Owner decision before the release:** the project backfill now takes only conversations from before
    2026-04-25 (when PROJECT joined the prompt). Each is regenerated once.
    - Its title can change, for example to the calendar event's name.
    - Keep this one-time pass, or turn the project backfill off? (About 52 conversations existed then:
      WAL.md:1615.)
  - Recorded for later:
    - the Regenerate button says nothing when a short transcript keeps the title (a view change);
    - "until the transcript grows" is not done: appended meetings belong to 1.3 and 1.5;
    - `generate()`'s own branches get a test seam with the queue in 1.5;
    - the row blanked on 2026-09-22 is untitled, so no backfill selects it: 1.5 must enqueue untitled rows,
      dictations included.
- [ ] 1.7 Durable recording and the recovery importer (How 7).
- Owner step: `Services/Indexing/MeetingObsidianWriter.swift` has been dead since 2026-05-12 and still holds an
  identifier lookup. The guard allows it only while no code refers to it, and it is keyed on the type
  name. Delete it?

**Definition of Done**
- US-1.1 to US-1.4 pass their tests (occurrence choice, grouper, queue, backfill convergence, reminder
  decisions — calendars pinned to UTC in tests).
- Gate PASS, Codex review clean, released.
- After a week of the owner's real calls, the store shows no stuck meeting, structured generation
  attempted for every meeting, and at most one "still recording" card per real overrun.

**Depends on:** step 0 (safe installs), Pro (for generation). **Owner:** nothing beyond using it for a
week. **Risks:** meeting recording is the owner's daily tool — every change is tried in MetaWhisp Dev
before release. **Estimate:** about 3–5 days, which includes recording to disk (added by the Codex review),
then a week of observation.

---

## Step 2 — One search over everything

**User stories**
- **US-2.1 — the answer, with its source.** As the owner, I want to ask by chat or voice "what did I
  promise on Friday's call with X" and get the answer with the call's date and time, so that I don't dig
  through notes.
  - On a labelled set of at least 20 of the owner's real questions, the right conversation is in the top 3
    for at least 90%.
  - Every answer cites its sources: the call, date and time.
- **US-2.2 — names, however they were spelled.** As the owner, I want a name found however it was spelled
  or recognised — Cyrillic or Latin, a speech-recognition variant — so that one company is one company.
  - An alias index is built from calendar titles and attendees, the transcript of the same meeting,
    projects, and transliteration.
  - The owner can confirm or merge an alias.
- **US-2.3 — dates understood exactly.** As the owner, I want "last Friday", "yesterday", "on Tuesday"
  understood in my time zone on every engine, so that the right day is searched.
  - A deterministic date parser, English and Russian (the Russian tests wait for the owner's decision).
  - Every model path receives today's date and the resolved range — not only the Pro path.
- **US-2.4 — "not found" only after a real search.** As the owner, I want the assistant to say "not
  found" only when it has searched everything, so that I can trust it.
  - Full transcripts are searched (chunked, full-text and semantic), with to-dos and decisions and done
    tasks.
  - A failed search is reported as an error, never as an empty result; semantic results need a relevance
    floor; a search made on the last tool round reaches the model.

**How (technical).** Details are in `evidence/ITER-075/step2-code-check.md`. The new code lives in
`Services/Intelligence/Retrieval/`.
1. `QueryFrame` and `RelativeDateResolver` (pure, time zone injected): code resolves relative dates,
   never the model. A follow-up question inherits the previous turn's name and date.
2. `SideIndex` is an SQLite FTS5 file next to the store; the system SQLite has FTS5, confirmed. It is
   rebuilt from the store, never the other way round. It holds:
   - every transcript, in chunks of at most 1,200 characters;
   - tasks (open and done), decisions, memories and files.
3. `AliasIndex` collects name variants from the calendar, attendees, transcripts, projects and
   transliteration. It merges two variants only on the owner's Yes.
4. `RetrievalService.search(frame)`:
   - It combines text (bm25), meaning (with a floor, and only with consent) and names; the date is a
     hard filter.
   - Each hit carries its id, local date, decisions, to-dos and a quote.
   - A failure is an error.
   - `readConversation(id)` returns a full transcript.
5. Consumers switch to it: the chat's context fetchers (`ChatService.swift:1036-1557`), the chat's
   search tools (`ChatToolExecutor.swift:448-716`), AdviceService's memory ranking and MCP. The screen
   agent's own in-memory scan stays.
6. `PromptClock` gives every engine one local date, weekday and zone. The last tool round always ends
   in an answer.

**Also required (Codex review, 2026-09-25):**
- **Schema V10 (F3).**
  - Today V1, V2, V3 and V8 list the live `ChatMessage` and `Conversation`, and V9 inherits V8
    (`MetaWhispSchema.swift:30`, `:91`, `:155`, `:366`).
  - Before a field is added, the V9 shapes are frozen as copies in every historical schema that lists
    them.
  - A V9 → V10 stage is added, and both containers move to V10: the normal one and the degraded one
    (`HistoryService.swift:29`, `:52`).
  - A migration test runs on a copy of the owner's store with its WAL and checks IDs, fields and
    relationships.
- **Consent (F4).**
  - Embedding whole transcripts sends them to `api.metawhisp.com/api/pro/embed`
    (`EmbeddingService.swift:47`) and on to its provider.
  - That needs, first: disclosure, the provider named, and the owner's opt-in.
  - A test proves no embedding request goes out before consent or after it is withdrawn.
  - Without consent, the search runs on text, names and dates only.
- **Index freshness (F11).**
  - The index is invalidated from the store's own save notifications, so every writer counts —
    including the History window's direct deletes (`HistoryView.swift:165-173`).
  - Each chunk carries its source revision.
  - Tests: delete one item, and clear all, without a restart.

**Definition of Done**
- US-2.1 to US-2.4 pass their tests and the labelled question set reaches its target.
- Gate PASS, Codex review clean, released.
- The owner asks 5 real questions of their own choice, by chat and by voice, and gets the right answers.
- The V10 migration test passes on a copy of the owner's store; no embedding request leaves the Mac
  before the owner's consent.

**Depends on:** step 1 (complete data), Pro for embeddings (no local embedding model exists; without
Pro, text, name and date matching still run). **Owner:** the question set
(20+ real questions with the right answers); the decision on Russian test cases. **Risks:** the side
index must stay in step with the store — rebuilt from the store, never the other way round.
**Estimate:** about 4–6 days, which includes the schema freeze and the consent step (added by the Codex
review).

---

## Step 3 — The Jev engine

**User stories**
- **US-3.1 — every request understood.** As the owner, I want Jev to tell a question from a command from
  an errand, fast and cheaply, so that the right thing happens.
  - On a labelled set of at least 100 of the owner's phrases, the routing accuracy reaches the agreed
    threshold.
  - The answer comes within the router's 2 s deadline at the 95th percentile, with its cost measured.
  - A missing, malformed or late answer is its own outcome — unavailable, invalid or timed out — and is
    logged and shown. The core may still answer such a request as a question, but only with a visible
    note, never silently. Today `AgentRouter.decide` turns all three into "question"
    (`AgentRouter.swift:48`). ITER-074 §3.1 is updated to match (Codex review F9).
- **US-3.2 — no invented instructions.** As the owner, I want to approve every instruction text Jev and
  the writer get, so that nothing is invented.
  - The questions' wording is ported from references and approved by the owner before commit (ITER-074
    I-0.4).

**How (technical).** Details are in `evidence/ITER-075/steps3-4-code-check.md`.
1. `DecisionEngine` (`Services/Agent/AgentInterfaces.swift`) gains `route(sentence)`. `Route` gains
   `.command` and explicit failure outcomes (F9).
2. `JevWire` (pure) encodes the router, choose and risk questions and validates the answers. The wire
   shape is copied from OpenRouter's Jev documentation, found and checked live on 2026-09-26
   (`evidence/ITER-075/3.0-jev-live-check.txt`): `POST https://openrouter.ai/api/alpha/decisions`, a
   Bearer OpenRouter key, `typesafe/jev-1.13`, questions of type choice, noul or score.
3. `JevEngine`:
   - calls `POST https://openrouter.ai/api/alpha/decisions` (owner, 2026-09-26: OpenRouter);
   - takes the owner's OpenRouter key from the keychain;
   - never lets its timeout run past the caller's deadline;
   - logs numbers only.
4. An eval harness in the test target measures accuracy, errand recall, p95 and cost, split by
   language.
   - The live run needs the key and a labelled file kept outside the repo.
   - Only the totals are committed.
   - It follows the routing rules of ITER-074 §3.1 and the pass bars of §17.1(5).
5. The thresholds are set from the report after the owner's Yes. Today they are placeholders:
   `AgentPolicy.swift:13-20`, `AgentRouter.swift:24`.

**Definition of Done**
- US-3.1 and US-3.2 pass; the eval report is committed and the thresholds are set.
- Gate PASS, Codex review clean.

**Depends on:** step 0. **Owner:** the Jev key; the labelled phrases (from the owner's own use, with
consent; the labelled file stays on the Mac and out of the repo, but each phrase is sent to Jev's API
during the evaluation — Codex review F4); the prompt approval — one session of about an hour. **Risks:** accuracy on
Russian phrases is unknown until measured. **Estimate:** about 1–2 days, plus the owner session.

---

## Step 4 — One assistant for chat and voice, routed by Jev, with the popular commands

**User stories**
- **US-4.1 — one assistant.** As the owner, I want to say or type anything to one assistant, so that I
  never think about which feature to use.
  - Chat and voice enter one core, and Jev routes each request:
    - question → search and answer;
    - command → a tool;
    - errand → the queue, from step 5. Until then an errand gets a clear "not yet" answer, never a
      silent question (Codex review F9).
  - Voice questions are no longer saved as dictations; the voice popup never hangs on "thinking".
- **US-4.2 — the popular commands.** As the owner, I want these by voice and by chat: what's on my
  calendar, create an event, remind me, create or complete a task, open an app or a site, a timer, a
  note, and insert the answer at the cursor.
  - Each command has a test and works live in MetaWhisp Dev.
- **US-4.3 — a Yes for every change.** As the owner, I want to confirm anything that changes something,
  wherever I asked — the chat bubble or the voice popup — so that nothing happens behind my back.
  - Every tool has a safety class — read, local change, external — and the confirmation follows it.
  - Silence is a No after the answer window.

**How (technical).** Details are in `evidence/ITER-075/steps3-4-code-check.md`.
1. `AssistantCore.handle(request)` grows from `ChatService.send`. Jev routes first, before any save,
   embedding or screen capture. The chat window and voice call only this.
2. `TranscriptDisposition` splits a voice question off before the history save.
   - Each path has one final outcome and one deadline, so the popup never hangs.
   - `VoiceQuestionState` gains a confirming state with Yes/No buttons.
3. `ToolRegistry` holds one spec per tool, each with a safety class: read, local change or external. It
   replaces six hand-kept lists and four switches.
4. Commands: Jev picks the command from the registry, dates come from step 2's parser, and LLMs write
   text only.
5. New tools:
   - calendar read and create event (EventKit);
   - reminders (`EKReminder`, plus a new usage string);
   - open an app or a site (`NSWorkspace`, http/https only);
   - a timer;
   - a note (Notes, via osascript);
   - insert at the cursor (the fixed clipboard transaction, under the input lease).
6. `ConfirmationPolicy`:
   - a read runs at once;
   - a change waits for a Yes, in the chat bubble or the popup;
   - silence is a No.

**Also required (Codex review, 2026-09-25):**
- **The Yes path goes through the core (F8).**
  - Today a Yes in the chat (`ChatView.swift:187` → `confirmTool`) starts a continuation that gives the
    LLM the full tool list and saves the LLM's next tool call as a new pending command
    (`ChatService.swift:607-687`).
  - This moves into the core. After a confirmed command, Jev decides any next step, and the writer
    gets no tools.
  - Pending commands already in the store are expired at the migration, never executed.
- **Clipboard (F6).**
  - Today `PasteboardReplacementTransaction.prepare` can clear the clipboard, fail, and never take
    ownership, so the user's clipboard is not given back (`TextInsertionService.swift:36-41`,
    `:207-215`, `:79-86`). And `insertResult` reports "pasted" before its delayed ⌘V runs (`:181-191`).
  - The fix is at the owner: the transaction owns the clipboard from the first clear and restores it on
    every failure, and the paste is awaited and cancellable.
  - Insert-at-cursor uses it; the layout fix and the selection translator get the fix too.
  - Separate owner decision: should plain dictation also give the old clipboard back after pasting?
    Today the dictated text stays on the clipboard.

**Definition of Done**
- US-4.1 to US-4.3 pass; routing is measured live on the owner's requests for a few days.
- Gate PASS, Codex review clean, released.

**Depends on:** steps 2 and 3; the input lease (ITER-074 I-1.5) for inserting at the cursor. **Owner:**
approval of new prompt text; new permissions (Reminders; Automation for Notes) granted once.
**Risks:** a wrong route is the owner's most visible failure. An uncertain or failed route is shown to
the owner, never hidden (F9). **Estimate:** about 3–5 days.

---

## Step 5 — Browser errands from chat and voice, Jev choosing every step

**User stories** — ITER-074 US-1 to US-9 hold, and:
- **US-5.1 — research into a table.** As the owner, I want to say or type "collect 10 competitors into a
  table" and get a new Sheet with a source on every row, so that the research is done for me.
  - ITER-074 §17.2: J1 three times and J2 once, live.
- **US-5.2 — nothing irreversible without me.** As the owner, I want nothing irreversible done without my
  Yes, and Stop to stop everything, so that the agent is safe in my browser.
  - ITER-074 §7, with the whole-layer review's safety points S1–S5 fixed.
- **US-5.3 — my tab stays mine.** As the owner, I want the agent never to take over the tab I am looking
  at, so that it never interrupts me.
  - Errand tabs open without becoming active (the first live check found that a new tab takes focus).

**How (technical).** Details are in `evidence/ITER-075/steps5-6-code-check.md`.
1. `ChromeBridge` sends Apple Events off the main thread, each with a 5 s deadline. A new tab is opened
   and the user's active tab restored in the same script.
2. The 16 findings of the whole-layer review (`evidence/ITER-074/whole-review.md`) are fixed; all 16
   are still in the code today. Among them:
   - back goes only to addresses the agent opened itself;
   - a select's option passes the risk check;
   - cookie banners are declined without a question, and unknown overlays mean leaving the site;
   - a sign-in page pauses with Continue/Stop;
   - the table is read back even after Stop.
3. `GoogleSheet` opens `sheets.new` in a background tab, pastes once with ⌘V, returns the clipboard,
   then reads the table back.
4. The errand card stays up while the agent works, with Stop, Yes/No and Open table. Also added:
   Settings → Agent, the writer, and a record store.
5. `AgentService` owns `AgentQueue`, and the core's errand route submits to it.

**Definition of Done**
- ITER-074 §17.2 met; US-5.1 to US-5.3 pass.
- Gate PASS, Codex review clean, released.

**Depends on:** steps 3 and 4; the owner session (the Sheets check, prompt approval). **Owner:** the
Sheet's header row and the name of its source column (L1); the login-pause card (L4); decision 16
(sleep). **Risks:** a real page can do what fixtures cannot — every run is watched and Stop is always one
click. **Estimate:** about 5–8 days.

---

## Step 6 — Fill a web form from my data

**User stories**
- **US-6.1 — forms filled from what MetaWhisp knows.** As the owner, I want the agent to fill a form from
  what MetaWhisp knows about me, so that I never type it again.
  - Fields are matched to facts from the search (name, email, company, role…); free text is written by
    the writer; Jev decides which fact fits which field.
  - A preview shows every field and its value before anything is sent.
- **US-6.2 — I decide the Submit.** As the owner, I want to decide the Submit, so that nothing is sent
  without me.
  - Submit only after a Yes bound to that form and those values.
  - Passwords, one-time codes and card data are never filled (the observer never reports them).
  - The secret filter must know the owner's languages before this step ships; a confidence threshold is
    no substitute (Codex review F5). Today its words are English only (`ObserverScript.swift:508-518`),
    and a text field's value is reported (`:653`). Until the owner decides how Russian cases are tested,
    a form whose field names the filter cannot read is refused, visibly.
  - The observer reports a form identity and each field's form; today `ObservedElement` has neither
    (`ObservedPage.swift:28`). The Yes binds that identity and the chosen submit button's own destination,
    which can differ from the form's (`formaction`, `ObserverScript.swift:630-636`). Tests: two forms
    sharing an endpoint, and a button with its own `formaction` (F12).

**How (technical).** Details are in `evidence/ITER-075/steps5-6-code-check.md`. ITER-074 lists form
filling as "not planned"; this step plans it.
1. `FormFillJob` runs on the errand loop.
   - Facts come from step 2's search.
   - Jev decides which fact fits which field, and the values never go to Jev.
   - Below the threshold, a field stays empty.
2. `type` carries its text (whole-layer review L2) and reports, in the page, that the value holds.
   - `ActionOutcome`, dispatch and verification change together (`ActionScript.swift:17`,
     `AgentRun.swift:379`, `:425`).
   - Tests: a multiline and a long textarea through the whole loop, and a lost reply (Codex review F13).
3. The preview card shows field → value → source. The owner answers Fill/No, then Send/No, and silence
   is a No.
4. The Yes binds the form's identity and its values. The values are re-checked in the page right before
   the click, and any change voids the Yes.

**Definition of Done**
- The owner's first form is filled live, checked by the owner in the preview, and sent only after the
  owner's Yes.
- US-6.1 and US-6.2 pass; gate PASS, Codex review clean, released.

**Depends on:** steps 2 and 5; prompt approval. **Owner:** which form first. **Risks:** a form may ask
for something MetaWhisp does not know — the field stays empty and the preview says so; nothing is
guessed. **Estimate:** about 3–5 days.

---

## Dependencies at a glance

| Step | Needs steps | Needs from the owner | External |
|---|---|---|---|
| 0 | — | Pro sign-in; Accessibility re-toggle; Dev app permissions once; allow codesign to use the Developer ID key once | — |
| 1 | 0 | a week of normal use | Pro (LLM) |
| 2 | 1 (soft) | 20+ real questions; the Russian-tests decision; consent to embed whole transcripts | Pro, for embeddings (only with consent) |
| 3 | 0 | labelled phrases; prompt approval (documentation and key settled 2026-09-26) | Jev through OpenRouter |
| 4 | 2, 3 | prompt approval; Reminders and Automation permissions | — |
| 5 | 3, 4 | Chrome or Dia; Sheets check; header-row, login-pause and sleep decisions | the browser, Google Sheets |
| 6 | 2, 5 | which form first; where email and phone come from; prompt approval | the form's site |

Steps 1 and 3 can run side by side once step 0 is done; everything after follows the table. Rough total:
about 4–7 weeks of work (21–34 working days, the sum of the step estimates), plus the week of
observation in step 1.

## Decisions for the owner (one at a time)
1. The order above — the causes (1, 2) before the new abilities (3–6)?
2. ~~Who routes a request~~ — **decided 2026-09-25: Jev routes every request, voice and chat** ("Jev —
   это основа нашей архитектуры"); the draft's alternative (the chat model proposing errands) is dropped.
3. How Russian phrases are tested, since tests are English-only (steps 2, 3 and 6).
4. At step 2: consent to send whole transcripts for embedding, with the provider named (Codex review F4).
5. ~~At step 3: Jev's API documentation and key~~ — **settled 2026-09-26:** the owner pointed to the
   public documentation and the OpenRouter key; a live call answered in 0.48 s for $0.00002.
6. At step 5: Chrome or Dia (ITER-074 says Dia); the Sheet's header row and source column name; the
   login-pause card; decision 16 (sleep).
7. At step 6: which form first; where email and phone come from (today only free-text memories).
8. Outside this plan: should plain dictation give the old clipboard back after pasting (Codex review F6)?
