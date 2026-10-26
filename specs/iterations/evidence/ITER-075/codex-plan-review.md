# ITER-075 plan — Codex review (2026-09-25)

**Scope.** `ITER-075-assistant-core.md` and the five code checks in this folder. The review was read-only (Codex, reasoning "ultra").

**Verdict.** Request changes: 13 findings, 2 critical and 11 major.

**Verification.** The orchestrator read the cited code for each finding. All 13 hold. Each one is folded into the plan and marked "Codex review Fn" there.

| # | Severity | Finding | Checked at | Resolved in |
|---|---|---|---|---|
| F1 | CRITICAL | The release smoke test launches the notarized copy with the production identity. It opens the owner's store, keychain items and log. | `release.sh:168-176`; `HistoryService.swift:17-32` | Step 0, US-0.2 |
| F2 | CRITICAL | Meeting audio lives only in memory, so a crash loses the whole call. The shutdown rescue covers an orderly quit only. | `AudioRecordingService.swift:636`; `SystemAudioCaptureService.swift:311`; `AppDelegate.swift:2654-2686` | Step 1, US-1.4 |
| F3 | MAJOR | Historical schemas list the live `ChatMessage` and `Conversation`, and V9 inherits V8. Adding a field also changes the historical shapes. | `MetaWhispSchema.swift:30`, `:91`, `:155`, `:366`; `HistoryService.swift:29`, `:52` | Step 2, "Also required" |
| F4 | MAJOR | Embedding whole transcripts sends them to the Pro proxy, and consent was only an open question. The eval claimed the phrases "stay on the Mac". | `EmbeddingService.swift:47-53` | Step 2, "Also required"; Step 3, owner line |
| F5 | MAJOR | A Jev confidence threshold was proposed as a stand-in for Russian secret detection. The patterns are English only, and a text field's value is reported. | `ObserverScript.swift:508-518`, `:650-653` | Step 6, US-6.2 |
| F6 | MAJOR | `prepare` can clear the clipboard, fail and never take ownership, so it is not restored. `insertResult` reports "pasted" before its delayed ⌘V. | `TextInsertionService.swift:36-41`, `:79-86`, `:181-191`, `:207-215` | Step 4, "Also required" |
| F7 | MAJOR | Existing rescue WAVs have no manifest, and the 7-day cleaner deletes them. Each save creates a new item, so an interrupted import duplicates. | `AppDelegate.swift:2666-2676`, `:3234-3272`; `HistoryService.swift:63-80` | Step 1, US-1.4 |
| F8 | MAJOR | A Yes in the chat starts a continuation that gives the LLM the full tool list and stores its next tool call. | `ChatView.swift:187`; `ChatService.swift:600-613`, `:675-687` | Step 4, "Also required" |
| F9 | MAJOR | The router turns a missing engine, an error or a late answer into "question" silently. Step 4 routed errands to a queue that has no runner until step 5. | `AgentRouter.swift:46-52` | Step 3, US-3.1; Step 4, US-4.1 |
| F10 | MAJOR | Blanking the fields is how the backfill callers force a regeneration past the "already structured" check. Removing the blanking alone disables them. | `StructuredGenerator.swift:256-258`; `ProjectAggregator.swift:315-320`, `:591-597` | Step 1, US-1.2 |
| F11 | MAJOR | The History window deletes items directly, so dirty marks placed on a few services miss those deletions. | `HistoryView.swift:165-173` | Step 2, "Also required" |
| F12 | MAJOR | Form action plus method is not a form identity: distinct forms can share an endpoint, and a submit button can override the form's destination (`formaction`). | `ObserverScript.swift:630-636`; `ObservedPage.swift:28-29` | Step 6, US-6.2 |
| F13 | MAJOR | A `type` that reports "holds" needs `ActionOutcome`, dispatch and verification to change together. Textareas report no value today. | `ActionScript.swift:17-19`; `AgentRun.swift:379`, `:425-428`; `ObserverScript.swift:645` | Step 6, "How (technical)" |

## What this changes in the evidence files
- `steps5-6-code-check.md`, Step 6 change 2: the 0.80 stand-in is withdrawn (F5).
- `step1-code-check.md`, changes 9–10, are extended by F7 and F10.
- `step2-code-check.md`, change 11 (V10), is extended by F3.

## New owner decision raised
Should plain dictation give the old clipboard back after pasting (F6)? Today the dictated text stays on the clipboard. This is outside ITER-075's steps; it is noted in Step 4.

## Estimates
- Step 1 grows to about 3–5 days, for recording to disk.
- Step 2 grows to about 4–6 days, for the schema freeze and the consent step.
- The rough total is now about 4–7 weeks, after step 0 also grew to about 2–3 days when the plan was rewritten.
