# ITER-075 Steps 3–4 — code check (2026-09-25)

A read-only check of the current code and of ITER-074 for the plan's Steps 3 and 4.

The orchestrator re-checked two facts:
- The voice branch runs after the history save (TranscriptionCoordinator.swift:443-458).
- `send` returns early without closing the popup (ChatService.swift:47-56).

Line numbers are for commit 7d5748b.

## 1. Current behaviour

### Decision engine and router
1. `DecisionEngine` (Services/Agent/AgentInterfaces.swift:38-45) has these members:
   - `name` and `worstCaseUSD`;
   - `choose(ChooseRequest) -> ChooseAnswer`;
   - `risk(of:onPage:) -> RiskAnswer`.

   It has no routing call.
2. Only test fakes implement it: `ScriptedEngine` and `SlowCountingEngine`. There is no JevEngine, and no hosted-API or OpenRouter client in the app.
3. `AgentRouter`:
   - `Route` is `.question` or `.errand`.
   - An errand needs a confidence of 0.80 or more.
   - No engine, an error, a malformed answer or a late answer (2 s total) all mean "question".
   - Nothing in production calls AgentRouter, AgentQueue or AgentRun.
4. The loop calls the engine through `paid()`, which reserves budget and applies a 10 s deadline. Every threshold is a placeholder: AgentPolicy.swift:13-20 and AgentRouter.swift:24.
5. Secrets go through `KeychainHelper` (service `com.metawhisp.secrets`).

### Voice path and popup
6. Voice order in TranscriptionCoordinator:
   - gates → post-processing and translation → glossary and corrections → HistoryItem save, grouper and export → only then the voice branch (:450-465).
   - So every voice question is saved as a dictation and gets structured generation and extraction when its conversation closes.
7. The coordinator goes idle while the send is still running. `activeSendTask` is overwritten without cancelling the previous one.
8. Popup phases (VoiceQuestionState.swift:11-18): only answered and failed leave "thinking", and "thinking" has no timer.
9. Why the popup hangs on "thinking": `send` returns without touching the popup in four places.
   - `isSending` (:47);
   - no LLM access (:48-53);
   - empty text (:55);
   - no key (:199-205).

   Nothing bounds the whole answer:
   - Pro: 5 rounds of 60 s;
   - BYOK: 4 rounds of 30 s;
   - local: 3 rounds with no timeout.

### Chat send and tools
10. `send` (:46-308):
    - guards → save the user message → embed → history → screen capture → fetchers → prompt;
    - then the local, Pro or BYOK loop → a mutation becomes a pending bubble → save → popup and TTS.
    - There is no streaming.
11. In both loops the LLM picks the tool. Today an LLM decides steps.
12. There are two callers: typed chat (ChatView.swift:371, which prepends an anchor context block) and voice (TranscriptionCoordinator.swift:458).
13. Tool names are kept by hand in six lists and four switches:
    - `toolSchemas`, `readOnlyTools`, `allKnownTools`;
    - the `<available_tools>` prompt block and `localSystemPrompt` (which has already drifted);
    - the strip regex;
    - the switches `validate`, `execute`, `executeReadOnly` and `undo`.

    ChatToolSchemaSyncTests checks only part of this.

### Commands today
14. Create and complete a task exist, chosen by the LLM.
    - Calendar read is partial: EventKit reads exist, but the chat sees the calendar only as metadata on linked meetings.
15. Create event is missing: the only EventKit write edits the notes of an existing event. Reminders are missing: no `EKReminder`, no usage string.
16. Open app or site is missing: the prompt tells the model it cannot. A timer is missing. Notes is partial: read-only, through osascript.
17. Insert at cursor is partial: it reactivates the saved app and sends ⌘V. It never re-checks the target and never restores the clipboard. There is no `InputLease` yet (ITER-074 I-1.5).

### Confirmations and the Jev spec
18. Confirmations:
    - Chat: a pending bubble with YES/CANCEL.
    - Voice: none — "confirm only in MetaChat window", and the popup closes after 6 s.
    - Errands: `ConfirmationRequest` (120 s, bound to the action), with no UI yet.
    - Safety classes: none.
19. Jev in the spec:
    - `POST /v1/decisions` on a hosted API or OpenRouter with the user's key, entered in Settings → Agent.
    - The wire shape, base URL, auth and price are in no file.
    - Question types: `choice` with a confidence, and `noul` (one probability).
    - The router asks one `choice` on the sentence. Choose asks an `action` choice plus a `goal_met` noul. Risk asks an `irreversible` noul.
    - Deadlines: router 2 s, decision 10 s.
20. Eval in the spec (ITER-074 §12.2, §17.1(5)): labelled router sentences and steps, with accuracy, cost and time split by language. The proposed bars are:
    - at least 50 steps and 50 sentences, half Russian;
    - no more than 2% of questions routed as errands;
    - at least 90% of errands caught;
    - router p95 of 1.5 s or less.

## 2. Changes for Step 3
1. `DecisionEngine` gains `route(_ sentence:) -> RouterAnswer`, and both fakes implement it.
2. `Route` gains `.command`, with a `commandFrom` threshold. Every fallback still means "question".
3. New `Services/Agent/JevWire.swift` (pure). It encodes the router, Choose and Risk questions, and decodes and checks the answers.
   - An unknown label, an out-of-range confidence or a missing noul gives nil.
   - The shape is copied from Jev's documentation once it is pinned.
4. New `Services/Agent/JevEngine.swift`: `DecisionEngine` over URLSession `POST /v1/decisions`.
   - Its timeout is never longer than the caller's deadline.
   - The key comes from the keychain.
   - Usage is reported as `EngineUsage`, and `worstCaseUSD` comes from a price constant.
   - Logs hold counts, confidences and milliseconds only.
5. The question texts live in one file, holding the I-0.4 ported texts with their sources. This step writes none.
6. An eval harness, in the test target only:
   - a pure scorer;
   - a live run through the production JevEngine, skipped unless the key and a labelled file (kept outside the repo) are set in the environment;
   - only the totals are committed to `evidence/ITER-075/`.
7. Once the owner confirms the bars, the thresholds are set from the report and pinned in tests.

## 3. Changes for Step 4
1. New `Services/Intelligence/AssistantCore.swift`: `handle(AssistantRequest) async -> AssistantOutcome` (answered, failed(reason), or confirming).
   - It routes first, before any save, embedding or capture.
   - ChatView and TranscriptionCoordinator call only this.
   - Jev gets the user's words, never the anchor block.
2. TranscriptionCoordinator: a pure `TranscriptDisposition`.
   - The voice branch moves to just after the gates. It cancels the previous task and saves no HistoryItem, conversation or export.
   - Questions still get post-processing and corrections.
3. Popup:
   - Every path ends in one final outcome, and there is a deadline on the whole answer.
   - `VoiceQuestionState` gains `.confirming`, with no auto-close in it.
   - Yes/No are buttons (the global Esc monitor cannot swallow keys).
4. New `ToolRegistry`: one `ToolSpec` per tool {name, safety class read/localChange/external, arguments, validate, execute, undo}.
   - The four switches are emptied into it.
   - The rate limit and the audit log stay.
   - The sync test is rebuilt on the registry.
5. Question route: step 2's Retrieval replaces the search tools, and the LLM gets no tools.
   - This is a prompt change for the owner to approve, with no new wording.
6. Command route: a Jev `choice` over the registry's commands.
   - Dates come from step 2's parser.
   - Target ids come from a Jev `choice` over Retrieval candidates.
   - Free text comes from the user's words or the writer.
   - URLs come only from the user's words.
7. New tools:
   - calendar read (EventKit occurrences in range);
   - create event (`EKEvent` + `save(_:span:commit:)`);
   - reminder (`EKReminder` + `requestFullAccessToReminders` + a usage string);
   - open app or site (`NSWorkspace`, http and https only);
   - timer (in app, plus a card);
   - note (Notes through the existing osascript runner, with the text escaped);
   - insert at cursor (TextInsertionService through InputLease and `restoreIfOwned`).
8. A pure `ConfirmationPolicy` by class:
   - read runs at once;
   - a change waits for a Yes, in the bubble or the popup, on one pending message;
   - expiry is computed from `createdAt`, with no schema change;
   - silence means No.
9. The errand route is answered as a question until step 5 connects AgentQueue.

## 4. Tests to write first
- AgentRouterTests: `.command` at or above `commandFrom`. Below it, an unknown label or a malformed answer gives `.question`.
- JevWireTests: a golden request per question type, plus the invalid answers.
- JevEngineTests (URLProtocol stub):
  - no key → no request;
  - an error or a late answer → "question";
  - the sentence appears in no log.
- JevEvalScoreTests: exact metrics and pass/fail at the bars.
- TranscriptDispositionTests: a voice question skips history, post-processing and the grouper.
- AssistantCoreTests: busy, no access, no key, an engine error or a deadline all end the popup with an error, never "thinking".
- ToolRegistryTests: unique names, one class each, full dispatch, and no prompt names an unknown tool.
- ConfirmationPolicyTests: read runs; a change waits; Yes runs; No and expiry cancel.
- One test per command, with fakes for the event store, opener, clock, script runner and lease.

## 5. Spec corrections and open questions
1. The routing thresholds are §3.1, and the pass bars are §17.1(5), not §6.4.
2. Latency: "within 2 s" at p95 (ITER-075) vs "≤1.5 s" (ITER-074). Set size: 100+ phrases vs 50 + 50, half Russian, while tests are English-only.
3. `command` is in no spec: no label, threshold or accuracy bar. Open: one flat `choice` (≤20 options) or two calls within 2 s?
4. Undefined: Jev's wire shape, base URL, auth, the OpenRouter form, and the price per call.
5. "They stay on the Mac" conflicts with the eval, which sends phrases to a hosted API or OpenRouter.
6. ITER-074 puts the router in TranscriptionCoordinator for voice only; ITER-075 moves it into the core.
7. Without a Jev key, today's path lets the LLM pick mutations, against the owner's rule. Decide what chat does for users without a Jev key.
8. Hypotheses to verify:
   - the calendars entitlement covers Reminders;
   - Notes Automation is credited to MetaWhisp for an osascript child;
   - which app "insert at cursor" targets from typed chat;
   - where the Jev key is entered in step 3;
   - whether the step-choice eval belongs to step 3 or step 5.
