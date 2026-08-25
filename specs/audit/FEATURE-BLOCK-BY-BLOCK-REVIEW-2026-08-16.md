# MetaWhisp -- Feature and Product-Block Code Review -- 2026-08-16

## Purpose and Verdict

Intent: review the current product feature by feature, trace each important user-data path, and record only findings backed by the code currently in the workspace. This is a report-only review; no application source was changed.

Verdict: **Request Changes** before a release that markets privacy, Pro sign-in, or Second Brain reliability as production-ready.

This review does **not** claim to enumerate every possible defect. A static review can prove reachable code defects and missing safeguards; it cannot prove hardware capture behavior, TCC dialogs, provider behavior, or a release build without a controlled runtime pass.

## Scope and Verification

- Baseline: b4c511a (fix(audio): don't cry "dead mic" at a headset that merely went quiet).
- Reviewed: 52,706 lines in 192 Swift source files; 93 XCTest files; current product guide, Settings copy, privacy-sensitive data flows, persistence, LLM routing, integrations, licensing, audio/transcription, and release state.
- Static parse: swiftc -frontend -parse over App, Models, Services, Views, Sources, and Tests completed successfully.
- Runtime build and XCTest suite were not run. specs/HANDOFF.md expressly forbids swift build and swift test without the user's direct request.
- Automated SAST/secrets tools (semgrep, gitleaks, trivy, osv-scanner, swiftlint) are not installed in this workspace. A basic static token scan found no high-confidence credential literal; this is not a substitute for a real secret scan in CI.
- Existing uncommitted/untracked work was preserved. It is documentation and workspace state, not application source; no user changes were reverted.

Severity definition: Critical is a privacy/security/data-integrity blocker; Major is a user-visible reliability or product-contract defect; Minor is a maintainability or correctness issue with limited immediate blast radius.

## Product Coverage Matrix

| Product block | Main code reviewed | Static status | Current result |
|---|---|---|---|
| Dictation capture and hotkeys | HotkeyService, AudioRecordingService, TranscriptionCoordinator | Risk | Pasting reports success before delivery is knowable; see FBR-011. |
| Text insertion and clipboard recovery | TextInsertionService | Major risk | Clipboard write is verified, destination paste is not; see FBR-011. |
| Translation and text processing | SelectionTranslator, TextProcessor | Needs live verification | Provider paths parse statically; no end-to-end permission/provider test. |
| Correction dictionary and auto-learning | CorrectionDictionary, CorrectionMonitor | Risk | Edited user text reaches durable diagnostics; see FBR-001. |
| Local Whisper transcription | WhisperKitEngine, TranscriptionCoordinator | Needs live verification | Parser and focused unit tests exist; hardware/model behavior remains unverified. |
| Cloud and Pro transcription | CloudWhisperEngine | Major risk | Pro glossary/prompt is sent in the URL; see FBR-004. |
| Audio device handling | AudioRecordingService, DeadMicDetector | No new static blocker | Recent raw-RMS and digital-silence hardening is present and unit tested. |
| Call detection and auto-start | ScreenContextService, AppDelegate, MeetingAutoStartGate | Needs live verification | Timing, TCC, and app-window matching require a real call matrix. |
| Meeting recording and dual streams | MeetingRecorder, SystemAudioCaptureService | Needs live verification | August raw-RMS bug is fixed; sanitizer has focused tests. Real headset/speaker regressions still need testing. |
| Meeting transcript quality | MeetingTranscriptSanitizer, DualStreamMerger | Needs live verification | Echo/repetition/language sanitizer is a material improvement; no fresh production-data validation in this review. |
| Meeting Copilot and Recap | LiveMeetingAdvisor, MeetingCoachService, StructuredGenerator | Needs live verification | LLM/provider and overlay lifecycle are not end-to-end tested. |
| Conversations and history | ConversationGrouper, HistoryService, views | Risk | Store migration remains unsafe; see FBR-006. |
| Tasks | TaskExtractor, TaskExtractionFilters, TaskPromotionService | Major risk | Exhausted queues disappear and title validation has dead code; see FBR-007 and FBR-015. |
| Memories | MemoryExtractor, UserProfileService | Major risk | Same lossy extraction queue; see FBR-007. |
| Goals and Projects | Goal, ProjectAggregator, corresponding views | No new static blocker | Existing pure logic tests cover key bounds/cluster helpers; broad services remain hard to change safely. |
| Daily summary, weekly patterns, insights | DailySummaryService, WeeklyPatternDetector, InsightAssistantService | Risk | Derived saves and external effects still have best-effort failure paths; see FBR-008. |
| MetaChat and tool actions | ChatService, ChatToolExecutor, MutationService | Major risk | Mutation core improved, but chat message/tool UI saves can still be silently lost; see FBR-008. |
| Local LLM and cloud fallback | LocalLLMService, extractors | Major risk | Ready local model preempts cloud; malformed output consumes bounded retries rather than using a quality fallback; see FBR-012. |
| Screen Context, Rewind, proactive assistance | ScreenContextService, AdviceService, RealtimeScreenReactor, ScreenExtractor | Critical risk | UI claims local processing while OCR text can be sent to cloud; see FBR-002. |
| File indexing and file memories | FileIndexerService, FileMemoryExtractor | Major risk | Raw local file text is stored and can go to cloud; path storage corrupts comma-containing paths; see FBR-005 and FBR-010. |
| Apple Notes | AppleNotesReaderService | Major risk | Raw note bodies can go to cloud and the bridge cannot safely encode arbitrary note text; see FBR-005 and FBR-009. |
| Calendar | CalendarReaderService, Settings | Major risk | Calendar details can go to cloud; Settings promises task creation that code intentionally removed; see FBR-005 and FBR-013. |
| Obsidian sync | ObsidianExporter, ObsidianPath | Risk | Hooks are best-effort and export/deletion failures are not surfaced in the originating workflow; see FBR-008. |
| MCP server | MCPSnapshotService, Sources/MetaWhispMCP/main.swift | No new static blocker | Explicit opt-in, purge, atomic write, and 0600 handling are correctly present. |
| Pro authentication and entitlement | LicenseService, deep-link handler | Critical risk | Callback accepts a bearer token without state/nonce validation; see FBR-003. |
| Device identity transport | LicenseService | Major risk | Stable hardware identifier is a query parameter; see FBR-014. |
| Onboarding, TCC, Settings | onboarding views, PermissionsService | Needs live verification | Source compiles, but permissions and provider validation are OS/network flows. |
| Data model and recovery | MetaWhispSchema, HistoryService, backups | Major risk | V1 is not frozen, so migration protection is illusory; see FBR-006. |
| Updates, packaging, repository hygiene | Sparkle setup, Package.swift, root state | Risk | Release checks were not run; root workspace artifacts require release hygiene; see FBR-016. |

## Critical Findings

### FBR-001 -- Diagnostic logs persist private content and are not owner-only

Evidence:

- Services/System/FileLogger.swift:3-30 redirects NSLog/stderr to ~/Library/Logs/MetaWhisp.log, but never applies owner-only permissions.
- Raw or truncated user-derived content is written there by App/AppDelegate.swift:1860, App/AppDelegate.swift:1968-1973, Services/Intelligence/AdviceService.swift:165, Services/Intelligence/MemoryExtractor.swift:490-494, Services/Intelligence/RealtimeScreenReactor.swift:165, and Services/Processing/CorrectionMonitor.swift:122-123.

Impact: transcripts, OCR-derived tasks, edited dictation, advice, and memory content can remain in a diagnostic file that a user may attach to support. This violates the privacy boundary even when intentional recovery logs are protected.

Required remediation:

1. Log identifiers, counts, sizes, reason codes, and hashes only by default.
2. Gate raw-content diagnostics behind an explicit, time-bounded local debug switch; never enable it automatically in production.
3. Apply 0600 after file creation and after truncation, as MCP already does.
4. Add a regression test or lint rule rejecting raw user content in NSLog.

### FBR-002 -- Screen Context promises local processing but sends OCR text to cloud LLM paths

Evidence:

- Views/Windows/MainSettingsView.swift:1483-1486 says that Screen Context OCR is fully on-device and screenshots are never saved.
- Services/Intelligence/AdviceService.swift:100-127 builds a context block from captured screen text and calls the Pro path when local LLM is unavailable.
- Services/Intelligence/RealtimeScreenReactor.swift:76-166 sends app name, window title, and OCR text through LLM processing.
- Services/Intelligence/ChatService.swift:85-180 includes fresh screen OCR in a voice-question prompt that may go to Pro chat.

Impact: pixels may remain local, but the sensitive semantic content does not. The current claim is materially misleading for users who enable screen capture for its stated privacy properties.

Required remediation: choose and implement one explicit contract: either cloud paths strip OCR/window text unless a local model is used, or Settings presents an opt-in that names the provider and says OCR text/window titles may leave the Mac. Add tests for both consent states.

### FBR-003 -- Pro activation deep link has no callback binding (state/nonce)

Evidence:

- App/AppDelegate.swift:2950-2964 accepts any metawhisp://auth?token= URL and calls LicenseService.activate(token:).
- Services/License/LicenseService.swift:101-126 activates that bearer token.
- No pending-login state, expiration, nonce, or single-use callback validation is present in this path.

Impact: another local process or a website can invoke the registered scheme and attempt to bind the app to an attacker-controlled session. Server validation may limit the outcome, but the client has no proof that the callback belongs to the login it initiated.

Required remediation: generate cryptographically random state, bind it to a short-lived pending login in Keychain, include it in the browser flow, and reject missing/mismatched/replayed callbacks before network activation. Add tests for success, missing state, mismatch, expiry, and replay.

## Major Findings

### FBR-004 -- Pro transcription sends glossary/prompt in the URL query

Services/Transcription/CloudWhisperEngine.swift:89-96 serializes promptWords as ?prompt=..., and :147-153 uses that URL for the audio POST. The direct BYOK flow correctly puts the prompt in multipart body at :214-228.

URLs are routinely retained by proxies, access logs, and observability systems. Move prompt/language/metering data to a JSON or multipart body and keep only a non-sensitive route in the URL. Replace the URL-focused regression test with a request-body contract test asserting that no prompt occurs in the URL.

### FBR-005 -- Files, Apple Notes, and Calendar can be sent to cloud without clear per-feature disclosure

Evidence:

- File content is read and included in an extraction prompt in Services/Indexing/FileMemoryExtractor.swift:72-92; when local LLM is not ready it uses Pro/BYOK cloud paths.
- Apple Notes body is included in a prompt at Services/Indexing/AppleNotesReaderService.swift:339-351 and its Pro path sends that prompt at :423-440.
- Calendar event title, attendees, location, and future events are assembled in Services/Indexing/CalendarReaderService.swift:443-466 and sent to Pro/BYOK at :358-381.
- Settings copy at Views/Windows/MainSettingsView.swift:1610, :1625, and :2292 explains local reading but not that content may be processed by a cloud provider. The user guide also does not name this boundary.

Impact: opt-in to a local data source is not informed consent for cloud export of its content, attendees, locations, or future schedule.

Required remediation: add a shared cloud-processing-of-this-source consent gate, provider-specific disclosure, and a local-only mode that waits for the local model. Document retention and what is persisted locally. Cover File, Notes, Calendar, and Screen Context with the same contract tests.

### FBR-006 -- SwiftData V1 migration schema is not a frozen historical schema

Models/MetaWhispSchema.swift:18-40 defines V1 using the live application models rather than immutable V1 model declarations. Services/Data/HistoryService.swift therefore cannot guarantee that a future change to a live @Model retains the shape needed to open a real older store.

Impact: a future breaking model edit can prevent an existing store opening. The fallback/degraded behavior protects the app process but cannot make the user's old data readable.

Required remediation: snapshot each V1 model shape into VersionedSchema, add an explicit migration plan to ModelContainer, and test it against a copied realistic V1 store before the first schema-changing release.

### FBR-007 -- Second Brain extraction permanently drops conversations after five failures

Services/Intelligence/ExtractionQueueStore.swift:95-100 removes an item once failedAttempts reaches its cap. MemoryExtractor and TaskExtractor return .failedAttempt for malformed model output and regular errors at MemoryExtractor.swift:157-162,196-200 and TaskExtractor.swift:172-180,213-216.

Impact: a user can lose memory/task extraction for a conversation with no dead-letter record, retry action, notification, or fallback. This is especially likely when a local model produces malformed JSON.

Required remediation: retain exhausted items in a durable failed state, expose them in the UI with source conversation and error class, and offer retry with local/cloud selection. Do not silently delete input evidence.

### FBR-008 -- Several user-visible workflows still swallow persistence failures

Examples:

- Services/Intelligence/ChatService.swift:64,267,291,586,703,725,741 uses try? ctx.save() after inserting chat messages or mutating tool state.
- Services/Indexing/FileIndexerService.swift:151,155,241,245 marks scans as complete even when batch persistence can fail.
- Services/Indexing/AppleNotesReaderService.swift:139-141 reports processed notes after a best-effort save.
- Services/Intelligence/RealtimeScreenReactor.swift:251-258 inserts a staged task then silently ignores save failure.
- Services/Indexing/CalendarReaderService.swift:200-213,351-353 does the same for links and extracted data.

Impact: the user can see success, a count, or an updated in-memory view while the change is absent after restart. MutationService has the right throwing contract, but these paths bypass it.

Required remediation: make each workflow return a persistence outcome before showing success; reserve try? only for truly disposable telemetry or cleanup. For external hooks (Obsidian/MCP), show a recoverable saved-locally-sync-failed state rather than conflating it with the database save.

### FBR-009 -- Apple Notes bridge corrupts valid notes containing its delimiters

Services/Indexing/AppleNotesReaderService.swift:187-221 writes raw title/body using ||| as a field delimiter and <<<END>>> as a record delimiter, then splits on those strings. Those strings are valid note text. A note containing either delimiter is parsed into wrong fields or wrong records, silently skipped, or sent to the model under a different title/body.

Required remediation: make AppleScript return JSON with proper escaping, or encode each field (for example Base64) and decode before parsing. Add tests with both delimiters, multiline body, Unicode, and malformed AppleScript output.

### FBR-010 -- Indexed folder paths use CSV and break valid macOS paths

Models/AppSettings.swift:208-210,276-292 stores selected absolute paths as a comma-separated string. A path such as /Users/a/Notes, Archive is split into two invalid folders when read.

Required remediation: migrate the setting to a JSON [String], retaining a one-time CSV reader only for existing values. Add regression cases for commas, spaces, duplicate paths, and migration round-trip.

### FBR-011 -- Auto-paste reports success before paste happens and cannot confirm destination delivery

Services/System/TextInsertionService.swift:50-78 returns .autoPasted as soon as a verified clipboard write succeeds, but posts Cmd+V asynchronously after 50-200 ms. :112-128 only proves that CGEvents were created and posted; it cannot prove that the intended app or focused field received them.

Impact: callers can present a successful insertion result while text was pasted to a newly focused app, rejected by the target, or not pasted at all.

Required remediation: represent this honestly as .pasteRequested after posting events. Keep verified clipboard as the guaranteed recovery path. For supported editable accessibility elements, prefer direct selected-text insertion and verify the result; retain manual paste fallback for all other apps.

### FBR-012 -- Local structured extraction has no quality fallback before it spends the queue budget

MemoryExtractor.swift:121-162, TaskExtractor.swift:131-180, and FileMemoryExtractor.swift:75-100 always select a ready local LLM before Pro/BYOK. A malformed local answer becomes a retry/failure; it does not make one cloud attempt even when a configured cloud path exists. Conversation queues then reach the deletion cap in FBR-007.

Required remediation: distinguish provider failure from malformed output and, when the user permits cloud processing, make one bounded fallback attempt after local parse failure. Preserve an explicit local-only setting that never exports data, and show which path was used.

### FBR-013 -- Calendar UI advertises task creation that the code explicitly removed

Views/Windows/MainSettingsView.swift:2292 says Calendar creates tasks for upcoming events. Services/Indexing/CalendarReaderService.swift:335-342 says the previous task creation was removed and calendar events must not become tasks.

Impact: the product makes a concrete promise that current code intentionally does not fulfill.

Required remediation: change the copy to the actual contract (event context for meeting linking/pattern memories), or restore task creation as a separately specified feature with non-noisy acceptance tests.

### FBR-014 -- Stable hardware identifier is still exposed in authentication URLs

Services/License/LicenseService.swift:109 and :240 place machine_id (IOPlatformUUID) in the query string. It is not a bearer token, but it is a stable device identifier and therefore personal/correlatable data in gateway, proxy, and analytics URL logs.

Required remediation: place it in a POST body or a dedicated request header; avoid raw hardware identifiers where an app-scoped rotating installation ID would meet the product requirement.

## Minor Findings

### FBR-015 -- vagueVerb validation branch is unreachable

Services/Intelligence/TaskExtractionFilters.swift:127-143 returns .tooShort for every title with fewer than four words, then checks wordCount <= 3 for .vagueVerb. The test Tests/MetaWhispTests/Services/Intelligence/TaskExtractionFiltersTests.swift:106-128 documents and pins that behavior.

Decide the intended policy, remove the dead branch or change its predicate, and replace the test that asserts the current defect.

### FBR-016 -- Release hygiene and test gates are not enforceable from the current workspace

The working tree contains untracked root artifacts (Local, Plugin, CLAUDE2.md) and a large set of audit/iteration files. There is no installed SAST/secrets tool and no observed CI-enforced release gate for privacy scans, signed build, Sparkle feed publication, or an end-to-end smoke pass.

This is not a runtime bug by itself, but it raises the chance that artifacts or unreviewed changes ship. Add a release script/CI job that fails on unexpected root files, runs secret/SAST scanning, validates appcast/version consistency, and requires the smoke matrix after a signed build.

### FBR-017 -- Core ownership classes remain too large for their risk level

Examples: App/AppDelegate.swift (2,979 lines), Views/Windows/MainSettingsView.swift (2,936), Services/Intelligence/ChatService.swift (1,959), and Services/Intelligence/ChatToolExecutor.swift (1,137). These files own multiple user-data, UI, and provider contracts, making targeted review and regression testing unusually expensive.

Refactor only alongside a behavior change, beginning with explicit seams such as auth deep-link handling, meeting transcription pipeline, cloud request builders, and chat persistence. Do not do a broad cosmetic rewrite.

## Positive Findings

- Current meeting recording uses raw RMS for silence decisions: Services/Audio/MeetingRecorder.swift:78-98,405-451; the earlier boosted UI-level units mismatch is fixed and tested by Tests/MetaWhispTests/Services/Audio/MeetingRecorderSilenceTests.swift.
- MeetingTranscriptSanitizer now performs bounded cross-channel echo, repetition, and foreign-fragment cleanup, with focused tests at Tests/MetaWhispTests/Services/Intelligence/MeetingTranscriptSanitizerTests.swift.
- MCP snapshot handling has a clear opt-in, purge-on-disable, atomic write, complete file protection, and re-applied 0600 permissions: Services/MCP/MCPSnapshotService.swift:70-199.
- MutationService correctly models database save as a throwing boundary and only runs external hooks after commit: Services/Intelligence/MutationService.swift:4-67.
- The project has meaningful pure-function tests in high-risk domains: meeting sanitizer, RMS guard, extraction parsing, task filtering, URL construction, entitlement policy, screen policy, storage degradation, and MCP contracts.

## Fix Order for Implementation

1. Privacy/security blockers: FBR-001 through FBR-005 and FBR-014.
2. Prevent data loss: FBR-006 through FBR-008.
3. Correct integration and user-visible behavior: FBR-009 through FBR-013.
4. Keep codebase and release process reviewable: FBR-015 through FBR-017.

For every item: write a failing focused test first, implement the smallest change, then run the affected test plus the applicable manual OS/provider check. Do not mark privacy or audio behavior as fixed from unit tests alone.

## Required Runtime Matrix Before Release

| Scenario | Required proof |
|---|---|
| Screen, Files, Notes, Calendar with local-only mode | Confirm no outbound request contains source content. |
| Same sources with cloud consent | Confirm provider disclosure, provider selection, and redaction/retention behavior. |
| Pro sign-in | Correct state succeeds; missing, mismatched, expired, and replayed callbacks fail. |
| Pro transcription | Request URL has no user prompt; body still delivers language/prompt correctly. |
| Dictation insertion | Clipboard succeeds; auto-paste to supported and unsupported targets is honestly reported. |
| Meeting capture | Built-in mic, AirPods, headset, speaker bleed, silence end, calendar end, device switch. |
| Second Brain extraction | Local malformed JSON, cloud fallback allowed/denied, retries exhausted, durable user recovery. |
| Persistence migration | Upgrade a copy of a real old store and prove records remain accessible after relaunch. |
| Obsidian/MCP | Write failure and deletion failure are surfaced; MCP opt-out removes the snapshot. |
| Release | Signed build, smoke matrix, Sparkle feed/version, clean tracked artifact list, and secret scan. |
