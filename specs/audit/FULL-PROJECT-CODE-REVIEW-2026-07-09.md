# MetaWhisp Full Project Code Review — 2026-07-09

## Summary

Intent: full static review of the current MetaWhisp macOS app, not a single PR.

Overall assessment: the project has made real progress since the older audits
(Keychain migration, SwiftData degraded-store handling, durable extraction
queues, MCP opt-in snapshot, local LLM memory bounds, many focused tests), but I
would still request changes before treating this branch as release-safe.

Verdict: Request Changes.

Scope:
- Read current project rules in `AGENTS.md` and existing audit progress.
- Reviewed persistence, privacy/security, cloud/LLM paths, transcription,
  Second Brain extraction, file/Notes/Obsidian/MCP integrations, release hygiene,
  and test layout.
- Did not run `swift build` / `swift test`: `specs/HANDOFF.md` explicitly says
  not to run those without the user's direct request.

## Critical Issues

### CR-2026-07-001 — Privacy contract says screen context is local, but OCR text is sent to cloud LLMs

Evidence:
- `Resources/Info.plist:62-63` says screenshots are processed locally and never
  sent to the cloud.
- `Views/Windows/MainSettingsView.swift:1315-1318` says "OCR via Apple Vision —
  fully on-device. Screenshots are never saved."
- `Services/Intelligence/AdviceService.swift:111-127` sends `contextBlock`
  built from screen contexts to `GateClient` and `/api/pro/advice` when local LLM
  is not ready and Pro is active.
- `Services/Intelligence/RealtimeScreenReactor.swift:80-115` builds a prompt
  from `appName`, `windowTitle`, `ocrText`, gates it, then calls Pro proxy.
- `Services/Intelligence/ChatService.swift:85-132` captures fresh screen OCR for
  voice questions and includes screen snippets/current screen in `userPrompt`;
  `ChatService.swift:172-180` sends that prompt to Pro chat.

Impact:
This is a product/privacy mismatch, not just wording. The screenshot pixels may
stay local, but OCR text is the sensitive payload users care about. Current copy
can mislead users into enabling Screen Context under the belief that screen
contents never leave the device.

Recommended fix:
- Pick one explicit product contract:
  - strict local-only: never include OCR/window titles in cloud prompts; require
    LocalLLM/FM for screen-aware features; or
  - cloud-assisted: change permission/settings copy and add explicit per-feature
    consent that OCR text/window titles may be sent to MetaWhisp Pro or BYOK
    providers.
- Add a guard test that cloud-bound prompt builders either strip screen OCR when
  the setting says local-only, or require an explicit cloud consent flag.

### CR-2026-07-002 — Durable diagnostic logs still contain private user content

Evidence:
- `Services/System/FileLogger.swift:3-30` redirects `NSLog`/stderr to
  `~/Library/Logs/MetaWhisp.log`.
- `App/AppDelegate.swift:1534-1540` logs filtered transcript text prefixes.
- `App/AppDelegate.swift:1597-1605` logs dropped utterance text prefixes.
- `Services/Intelligence/AdviceService.swift:150-165` logs raw/parsed advice
  response/content.
- `Services/Intelligence/MemoryExtractor.swift:482-494` logs extracted JSON or
  rejected memory content.
- `Services/Intelligence/RealtimeScreenReactor.swift:157-173` logs screen-derived
  task descriptions.

Impact:
`suspect-transcripts.log` is intentionally user data and chmods to `0600`, but
`MetaWhisp.log` is a diagnostics log users may attach to bug reports. It can
contain transcripts, memories, OCR-derived tasks, LLM responses, and advice.
`FileLogger` also does not harden the log file permissions after creation.

Recommended fix:
- Default diagnostic logs to metadata only: counts, IDs, lengths, reason codes.
- Gate raw text logging behind an explicit local debug mode with expiry.
- Set `MetaWhisp.log` permissions to owner-only after every create/truncate.
- Add a grep-style regression test for banned patterns like `String(...prefix(`
  inside `NSLog` calls outside deliberate user-data logs.

### CR-2026-07-003 — `metawhisp://auth` accepts bearer tokens without state/nonce validation

Evidence:
- URL scheme is registered in `Resources/Info.plist:29-37`.
- Settings opens the account page directly in `Views/Windows/MainSettingsView.swift:641-642`.
- `App/AppDelegate.swift:2452-2467` accepts any `metawhisp://auth?token=...`
  callback and immediately calls `LicenseService.activate(token:)`.
- `Services/License/LicenseService.swift:65-78` sends that token as bearer auth
  with `activate=1`.

Impact:
Any website or local process that can open the custom URL scheme can attempt a
login/session injection. Even if the token must be valid, the desktop app has no
pending-login state to distinguish a user-initiated return from an unsolicited
callback. Worst case: account confusion, unwanted license binding to this
machine, or future user data associated with the wrong account.

Recommended fix:
- Generate a short-lived random `state`/nonce when opening the account page.
- Store it in memory/Keychain with an expiry.
- Include it in the web URL and require the callback to return it.
- Reject callbacks with missing/expired/mismatched state before calling
  `activate`.

### CR-2026-07-004 — Pro transcription sends ASR prompt/glossary in the URL query string

Evidence:
- `Services/Transcription/CloudWhisperEngine.swift:91-95` builds
  `/api/pro/transcribe?language=...&prompt=...`.
- `Services/System/TranscriptionCoordinator.swift:278-285` includes
  user-defined correction dictionary values in `promptWords`.
- Direct BYOK transcription sends the prompt in multipart body instead:
  `Services/Transcription/CloudWhisperEngine.swift:162-164`.

Impact:
Prompt terms can include private product/client/person names. URL query strings
are routinely captured by server access logs, reverse proxies, analytics, and
error tooling. This also risks URL length issues as prompt hints grow.

Recommended fix:
- Move `language` and `promptWords` into the POST body for the Pro endpoint
  (multipart form fields or JSON sidecar), matching the direct provider path.
- If query params remain temporarily, use `URLComponents` and cap/strip
  user-defined prompt terms.

## Major Issues

### CR-2026-07-005 — Local LLM readiness globally preempts Pro/BYOK cloud, with no quality fallback

Evidence:
- `App/AppDelegate.swift:247-251` states that any service seeing
  `LocalLLMService.isReady` will use local Phi-4 instead of cloud.
- `Services/Intelligence/MemoryExtractor.swift:131-162` uses local first, then
  treats unparseable JSON as a failed attempt; `MemoryExtractor.swift:196-199`
  counts thrown failures.
- `Services/Intelligence/TaskExtractor.swift:146-179` does the same for tasks;
  `TaskExtractor.swift:213-216` counts thrown failures.
- `Services/Indexing/FileMemoryExtractor.swift:75-99` local-first behavior also
  leaves files unprocessed on unparseable local output.

Impact:
This is great for Free/on-device mode, but risky for Pro/BYOK users. A loaded
local model can silently become the lower-quality path for structured JSON
extraction. If it returns malformed output, the app counts failures or retries
later instead of falling back to cloud where credentials already exist.

Recommended fix:
- Add an explicit policy flag: `localOnly`, `preferLocalWithCloudFallback`,
  `preferCloud`.
- For structured JSON services, retry cloud once on local empty/unparseable
  output when Pro/BYOK is available.
- Track local-vs-cloud parse failure rates per service.

### CR-2026-07-006 — Extraction queues drop conversations after five content failures without a dead-letter path

Evidence:
- `Services/Intelligence/ExtractionQueueStore.swift:95-100` removes the queued ID
  after `maxFailedAttempts`.
- `Tests/MetaWhispTests/Services/Intelligence/ExtractionQueueStoreTests.swift:153-159`
  pins that drop behavior.

Impact:
The cap prevents infinite local generations, but the current failure mode is
still silent product loss: a conversation may never produce tasks/memories and
the user gets no way to see or retry the failed item.

Recommended fix:
- Move exhausted items to a dead-letter store with `conversationId`,
  extractor type, attempts, last error, and timestamp.
- Surface a "Second Brain extraction failed / retry with cloud" control in the
  app.
- Keep the queue cap, but do not make the terminal state only an `NSLog`.

### CR-2026-07-007 — Save failures are still swallowed in user-visible and derived-data flows

Evidence:
- `Services/Intelligence/ChatService.swift:574-578` executes a confirmed tool,
  updates the chat bubble, then `try? ctx.save()` swallows failure. If the domain
  mutation succeeded but the bubble save failed, the UI can remain pending and
  allow duplicate execution.
- `Services/Intelligence/ScreenExtractor.swift:260-261` swallows save failure
  and still stamps `lastRun`.
- `Services/Intelligence/RealtimeScreenReactor.swift:199-203` swallows save
  failure and still updates cooldown state.
- `Services/Indexing/FileIndexerService.swift:240-246` swallows content-backfill
  saves and reports success counts.
- `Services/Indexing/AppleNotesReaderService.swift:139-141` swallows save after
  inserting memories and reports processed counts.

Impact:
The new `MutationService` fixes the most dangerous Task/UserMemory mutation
path, but surrounding UI/audit/derived pipelines can still report success after
a failed save. This produces duplicate actions, lost staged tasks, stale RAG
content, or misleading status lines.

Recommended fix:
- For any path that advances UI state, cooldowns, `lastRun`, or "processed"
  markers, replace `try? save()` with `do/catch`.
- Only advance success state after a successful commit.
- Reuse the `MutationService` style for other user-visible domain writes, or add
  smaller commit helpers per subsystem.

### CR-2026-07-008 — SwiftData V1 schema is not actually frozen

Evidence:
- `Models/MetaWhispSchema.swift:18-21` documents the rule to freeze V1 when the
  first real schema change lands.
- `Models/MetaWhispSchema.swift:22-31` currently defines V1 by referencing the
  live model classes directly.
- `Models/MetaWhispSchema.swift:35-40` has only the V1 baseline, no stages yet.

Impact:
The migration plan is a big improvement over the old no-plan state. The
remaining risk is future: if someone edits a live `@Model` while V1 still points
at that class, the V1 baseline mutates in place. Existing stores can then fail
or migrate incorrectly despite the presence of a migration plan.

Recommended fix:
- Before the first schema-changing release, snapshot V1 model shapes into a
  frozen namespace and move live models to V2.
- Add a test/guard that fails when `MetaWhispMigrationPlan.schemas.count > 1`
  and V1 still references live model types.

### CR-2026-07-009 — Vague-verb task validator branch is unreachable, and the test suite pins the bug

Evidence:
- `Services/Intelligence/TaskExtractionFilters.swift:117-120` returns
  `.tooShort` for every title with fewer than four words.
- `TaskExtractionFilters.swift:123-135` then checks `wordCount <= 3` for
  `vagueVerb`, which is unreachable.
- `Tests/MetaWhispTests/Services/Intelligence/TaskExtractionFiltersTests.swift:106-121`
  explicitly documents that "Check the auth logs now" currently passes.
- The validator is used before DB insert in
  `Services/Intelligence/RealtimeScreenReactor.swift:162-168` and
  `Services/Intelligence/ScreenExtractor.swift:224-231`.

Impact:
This lets vague screen-derived tasks through exactly where the product has had
noise problems.

Recommended fix:
- Decide whether to remove `vagueVerb` or make it fire on 4+ word titles that
  start with a banned vague verb and lack a concrete object.
- Change the test from "pins current buggy behavior" to expected rejection.

### CR-2026-07-010 — Indexed folder paths are persisted as CSV, so valid macOS paths with commas break

Evidence:
- `Models/AppSettings.swift:170-171` stores absolute folders as comma-separated
  text.
- `Models/AppSettings.swift:237-250` splits and joins by comma.
- The UI adds user-picked folders through
  `Views/Windows/MainSettingsView.swift:2322-2337`.

Impact:
macOS paths can contain commas. A folder like
`/Users/me/Clients/ACME, Inc/Notes` will be split into two invalid folders.
Removal also becomes unreliable because the stored path no longer round-trips.

Recommended fix:
- Store a JSON array in `UserDefaults` instead of CSV.
- Add a migration from the old CSV format and tests for comma-containing paths.

### CR-2026-07-011 — Apple Notes bridge uses raw delimiters that can appear in user note content

Evidence:
- `Services/Indexing/AppleNotesReaderService.swift:187-206` serializes notes as
  `id|||title|||body|||folder|||modDate<<<END>>>`.
- `AppleNotesReaderService.swift:215-227` splits on those delimiters and assumes
  fixed positions.
- No Apple Notes parser tests are present (`rg AppleNotes Tests` returned no
  matches).

Impact:
Any note body/title containing `|||` or `<<<END>>>` can corrupt parsing,
associate body/folder/date incorrectly, or drop the note. This is low-frequency,
but it is user-controlled input crossing a serialization boundary.

Recommended fix:
- Emit JSON from AppleScript if practical, or base64/percent-encode each field
  before joining.
- Add tests for delimiters, multiline bodies, empty folders, and attachment-only
  notes.

### CR-2026-07-012 — File Indexing copy understates that raw file text is stored and may feed cloud extraction

Evidence:
- Settings copy in `Views/Windows/MainSettingsView.swift:1347-1354` says local
  folders are scanned and durable facts are extracted into Memories.
- `Services/Indexing/FileIndexerService.swift:4-5` still says the indexer does
  not read content.
- `FileIndexerService.swift:197-246` does read `.md/.txt/.rtf/.markdown` files
  and stores up to `IndexedFile.maxContentBytes` in SwiftData.
- `Models/IndexedFile.swift:24-29` confirms raw `contentText` is retained for
  substring search and chat RAG.
- `Services/Indexing/FileMemoryExtractor.swift:72-93` can send file content
  prompts to local, Pro proxy, or direct BYOK LLMs.

Impact:
This is another privacy-contract mismatch. The feature is opt-in, but the app
does not clearly say that raw note/file excerpts are stored in MetaWhisp's DB
and can be used in cloud prompts when local LLM is not active.

Recommended fix:
- Update settings copy and docs to say: "stores text excerpts locally; may send
  excerpts to your selected cloud/Pro LLM unless local-only mode is active."
- Rename/update stale comments in `FileIndexerService`.
- Consider a per-source "local-only indexing" option.

## Minor Issues

### CR-2026-07-013 — Main ownership classes are too large for the current risk profile

Evidence:
- `App/AppDelegate.swift` is 2,481 lines.
- It owns service construction (`App/AppDelegate.swift:37-90`), app launch and
  observers, meeting recording, dual-stream chunked transcription
  (`App/AppDelegate.swift:1337-1806`), meeting auto-start/calendar hard-stop, WAV
  recovery cleanup, migrations, and auth URL handling (`App/AppDelegate.swift:2450-2480`).
- `Services/Intelligence/ChatService.swift` is 1,951 lines.
- `Views/Windows/MainSettingsView.swift` is 2,675 lines.

Impact:
This is not a style nit. These files combine independent state machines and
production-risk flows, making regressions harder to isolate and tests harder to
target.

Recommended fix:
- Extract narrow coordinators without changing behavior:
  `AuthDeepLinkHandler`, `MeetingTranscriptionPipeline`,
  `MeetingAutoStartController`, `CalendarHardStopController`,
  `RecoveryCleaner`, and smaller Settings subviews.
- Keep extractions surgical and test public/pure decisions first.

### CR-2026-07-014 — Working tree has accidental root artifacts

Evidence:
- `git status --short` shows untracked root files: `"$OUT"`, `Local`, `Plugin`,
  `AGENTS.md`, `CLAUDE2.md`, plus multiple untracked specs/audits.
- The literal `"$OUT"` file contains `(eval):17: command not found: "$CODEX"`.
- `Local` and `Plugin` are empty files.
- `MetaWhisp.dmg` is present in the root but ignored by `.gitignore`.

Impact:
This is release hygiene, not runtime behavior. Accidental root artifacts make it
easier to commit junk, confuse automation, or hide real source changes in a
dirty tree.

Recommended fix:
- Delete accidental files or add intentional local-only patterns to `.gitignore`.
- Before releases, require `git status --short --ignored` review and a clean
  tracked diff.

## Positive Feedback

- Keychain migration is much stronger than the old plaintext `.secrets` flow:
  `Models/AppSettings.swift:366-488` removes permanent plaintext fallback and
  verifies migration before deleting the legacy file.
- Store-open failure is no longer silently hidden behind an in-memory store:
  `Services/Data/HistoryService.swift:35-54`, `StoreBackup.swift`, and
  `StoreHealth.swift` preserve the failed store and expose degraded state.
- MCP snapshot now has opt-in gating, purge-on-disable, `completeFileProtection`,
  and owner-only permissions in `Services/MCP/MCPSnapshotService.swift:70-199`.
- Second Brain extraction queues are substantially improved versus the old
  silent `isRunning` drop: durable FIFO, degraded-store guard, and retry
  semantics are all present.
- Test inventory is meaningfully broad: 73 test files across data, transcription,
  intelligence, LLM, license, system guards, and UI readiness.

## Questions For Author

1. Is cloud use of screen OCR an intended product promise or an accidental
   implementation side effect? The code and copy currently disagree.
2. Should Pro/BYOK users prefer local LLM when it is active, or should local be
   a Free/local-only mode with cloud fallback for structured JSON?
3. Does the web account flow already support `state` on the server side? If not,
   desktop and website need to change together.
4. Do you want File Indexing to be "local RAG only" by default, or is cloud
   extraction acceptable after explicit copy/consent?

## Test Coverage Assessment

- Existing tests cover many previously fragile areas: schema baseline, degraded
  store behavior, MCP/MutationService contracts, extraction queue semantics,
  hallucination stripping, task filters, local LLM guards, license verification
  policy, and Cloud key validation.
- Gaps for this review:
  - no privacy guard test for screen OCR in cloud-bound prompts;
  - no auth state/nonce test for deep links;
  - no test that Pro transcription prompt is absent from URL query;
  - no save-failure tests for `ChatService.confirmTool`, screen extraction,
    FileIndexer, and Apple Notes;
  - no Apple Notes delimiter parser tests;
  - no JSON-array persistence tests for indexed folders.

## Recommended Fix Order

1. Fix the privacy contract first: screen OCR cloud behavior, diagnostic log
   redaction, Pro transcription query prompt.
2. Add auth `state`/nonce before the next public Pro activation release.
3. Fix swallowed-save success states in `ChatService.confirmTool`,
   `ScreenExtractor`, `RealtimeScreenReactor`, FileIndexer, and Apple Notes.
4. Decide local/cloud fallback policy for structured JSON services.
5. Add dead-letter UX for exhausted Second Brain extraction items.
6. Clean smaller correctness issues: task validator dead branch, indexed folder
   JSON persistence, Apple Notes serialization.
