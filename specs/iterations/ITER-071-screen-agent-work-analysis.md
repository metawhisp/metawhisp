# ITER-071 — Canonical work analysis from Screen Agent visits

**Status:** planned.
**Depends on:** ITER-064..070 complete; canonical visits, evidence, actions, feedback, and delivery states are stable.
**User outcome:** MetaWhisp can explain what the user worked on, what progressed, and what remains open without building a second inconsistent screen-history pipeline or judging the user's productivity.

## 0. Goal and Definition of Done

Migrate the hourly `ScreenExtractor` capability onto accepted `ContextVisit` records. Work analysis becomes a read-only synthesis over canonical visits and confirmed product state. It may create grounded observations and task candidates, but it cannot silently create memories/tasks or use fragile model indices.

No new top-level Work Analytics area is added. The output appears through existing Library/Rewind, Dashboard/Workspace where appropriate, and MetaChat questions.

## 1. User stories

### US-071-1 — what did I work on?

As a user, I want a trustworthy summary of my recent work grouped into understandable sessions or workstreams.

**Acceptance:** every summary statement maps to accepted visit/source IDs; excluded/deleted sources and capture gaps are stated honestly.

### US-071-2 — what changed and what is still open?

As a user, I want MetaWhisp to distinguish activity, progress, a commitment, and an unresolved loop.

**Acceptance:** an app visit alone is not progress; open-loop/task candidates require grounded evidence and confirmation before entering My Tasks.

### US-071-3 — one reality

As a user, I do not want the live agent and daily analysis to disagree because they reconstructed different visits.

**Acceptance:** batch analysis consumes the same immutable `ContextVisit`/frame identity as realtime and never rebuilds visits from app name plus five-minute gaps.

### US-071-4 — no surveillance score

As a user, I want useful recall and planning help, not a hidden score for how focused or productive I was.

**Acceptance:** UI/prompts contain no moralizing `productive/distracted` rating, employee score, or time-at-app claim beyond measured eligible capture intervals.

## 2. Canonical analysis model

Retain `ScreenObservation` as the persisted work-summary surface unless a RED migration/correctness test proves a new entity is required. Link its `sourceContextIDsJSON` to accepted frame IDs and add any new provenance through the V4 link/run records rather than modifying frozen legacy layouts casually.

One analysis window contains:

- immutable visit IDs and accepted frame IDs;
- measured start/end/capture-gap metadata;
- source labels safe under current retention;
- grounded Screen Agent items/action receipts in the same interval;
- confirmed tasks/projects/memories only when owner-scoped and explicitly retrieved;
- no image and no source that policy currently excludes.

Useful output types:

1. **Work session summary** — concrete documents/conversations/decisions observed.
2. **Progress evidence** — a validated state transition, result, or confirmed action.
3. **Open loop candidate** — unresolved commitment/question that may become a Screen Agent item or staged task candidate.
4. **Recall link** — exact source time/visit where retention permits.

Do not label a session productive/distracted. Do not infer hours worked from missing frames, sleep, permission loss, or excluded apps.

## 3. Checkpointing and bounded processing

Replace `lastRunAt`-style optimistic advancement with an exact checkpoint:

- `lastAcceptedContextID` plus timestamp/order key;
- checkpoint advances only after all output for the processed page saves successfully;
- zero eligible contexts advances to the last safely scanned boundary only when exclusion/retention semantics are explicit;
- failure/cancellation/purge leaves the checkpoint at the previous committed page;
- replaying a page is idempotent by source window + prompt/schema version;
- pages are ordered and bounded; no `fetchLimit=500` followed by taking an arbitrary first/last 20 that silently drops older unprocessed data;
- new contexts arriving during a run belong to the next immutable high-water mark;
- negative, huge, repeated, or model-generated visit indices are not accepted because prompts use opaque runtime-issued IDs.

The service is enabled only when Screen Agent/screen history and the relevant work-analysis setting allow it. Turning off or deleting screen history cancels work and invalidates checkpoint/output links under the retention contract.

## 4. Split prompt responsibilities

Retire the monolithic `observation + task + memory` write contract. Use versioned typed producers:

### Work observation producer

- summarizes only supplied visits;
- names concrete sources/workstream where evidence allows;
- returns evidence refs for each statement;
- never creates a task or memory.

### Open-loop/commitment producer

- reuses the task candidate contract and recipient/evidence validator from ITER-066;
- returns zero or more candidates for director/Inbox review;
- never commits, promotes, or completes a task.

### Memory candidate producer

- proposes a durable fact only when specific, reusable, and evidenced;
- routes through the same user-review/owner layer as other memory proposals if such confirmation exists;
- otherwise remains an observation and is not silently written to `UserMemory`.

Prompts receive opaque visit/frame IDs, not `Visit 1` labels. Output IDs must be an allowlisted subset. Screen text remains delimited untrusted data.

## 5. Workstream/session grouping

Deterministic grouping happens before the model:

- a visit already defines a focused-window episode;
- adjacent visits may be proposed as one work session when their project/task/document identity matches and the gap is within an injected policy;
- app name alone is insufficient to merge sessions;
- Slack channels, browser documents, two windows of one app, and normalized titles stay distinct when identifiers differ;
- the model may label a supplied group but cannot change its source membership;
- confidence below the grouping threshold produces separate sessions or `unknown workstream`, not a fabricated project.

Reuse existing `ProjectAggregator`/daily summary surfaces only after checking their owner and persistence contracts. Do not create a parallel project graph.

## 6. User surfaces and questions

### Library/Rewind

- shows source-backed work observations in chronological context;
- exposes capture gaps/source unavailable states;
- opens exact retained source when possible.

### Dashboard/Workspace

- may show confirmed task progress and explicit open-loop candidates;
- never counts unconfirmed candidate as completed work or committed task.

### MetaChat

Support grounded questions through existing read tools:

- `What did I work on today?`
- `Where did I leave the launch deck?`
- `What changed after the pricing discussion?`
- `Which open loops still need my confirmation?`

Answers cite visit/item/task IDs and distinguish observed, inferred, confirmed, unavailable, and capture-gap states. No answer may claim complete-day coverage when screen capture was off or excluded.

## 7. Master checklist — one atomic commit per item

- [ ] **071.1 Current extractor characterization.** RED fixtures for zero/negative/huge/repeated indices, app/title merging, 20-of-500 loss, save failure, toggle off, purge, and arriving-during-run contexts.
- [ ] **071.2 Canonical visit reader and high-water mark.** Ordered bounded pages, immutable run window, owner/policy filters, no reconstructed visits.
- [ ] **071.3 Transactional checkpoint/idempotency.** Advance only after saved page; retry cannot duplicate observation/task/memory candidate.
- [ ] **071.4 Typed work observation producer.** Opaque evidence IDs, per-claim validation, capture-gap honesty, no productivity judgement.
- [ ] **071.5 Open-loop/task producer migration.** Reuse Screen Agent candidate/confirmation path; remove direct staged-task write from extractor.
- [ ] **071.6 Memory proposal migration.** Stop silent batch `UserMemory` creation; route through approved review or retain only as observation.
- [ ] **071.7 Deterministic workstream grouping.** Same app/different window, normalized title, gaps, unknown project, and multi-display histories.
- [ ] **071.8 Product surface integration.** Library/Rewind chronology, confirmed Workspace state, MetaChat grounded work-analysis questions; no new sidebar.
- [ ] **071.9 Retention/toggle/legacy cutover.** Screen off/delete/purge cancels and cascades; disable legacy hourly writes in dogfood/live; rollback mutually exclusive.
- [ ] **071.10 Named signed-app day-analysis QA.** Mixed real workday sample with capture gaps, excluded apps, commitments, confirmed actions, restart, and delete-all.

## 8. Required tests

```text
ScreenWorkAnalysisServiceTests
ScreenWorkAnalysisCheckpointTests
ScreenWorkObservationPromptTests
ScreenWorkstreamGroupingTests
ScreenWorkAnalysisSurfaceTests
ScreenRetentionTests
ScreenAgentReplayTests
```

Required cases:

1. two windows of one app remain separate visits/sources;
2. same title with changed accepted frames remains one visit with ordered generations;
3. app name alone cannot merge unrelated work;
4. >500 contexts process in pages without dropping the oldest unprocessed records;
5. output save failure leaves checkpoint unchanged;
6. retry writes no duplicate observation/candidate;
7. model output cannot address a negative/huge/unknown index because only opaque IDs validate;
8. contexts arriving after high-water mark wait for next run;
9. screen/work-analysis off blocks reads and writes;
10. purge mid-run cancels and removes unconfirmed derived output;
11. a visit proves activity, not progress or productivity;
12. commitment for another participant does not become the user's open loop;
13. task candidate is absent from My Tasks until confirmed;
14. Chat answer explicitly reports excluded/capture-gap intervals and does not claim complete coverage.

## 9. Live QA

1. Prepare a named two-hour dogfood session across two browser documents, Slack, Figma, and an excluded app.
2. Include one same-title content change, two windows of one app, one capture gap, one explicit commitment, and one confirmed task action.
3. Run analysis, then compare every summary/progress/open-loop statement with its exact source.
4. Ask all four MetaChat questions from section 6; inspect cited sources and uncertainty.
5. Restart and rerun the same high-water window; verify no duplicates.
6. Inject a save failure halfway; verify retry resumes from the last committed page.
7. Turn capture off and later on; verify the report states the gap and makes no hidden coverage claim.
8. Delete screen history; verify unconfirmed summaries/candidates/source chat links are removed and confirmed task receipt survives as source unavailable.
9. Review language for absence of productivity judgement or employee-style scoring.

## 10. Definition of Done

- [ ] All ten checklist items closed.
- [ ] Hourly work analysis consumes canonical visits and never reconstructs them from app/time heuristics.
- [ ] Ordered paging/checkpoint/retry cannot drop or duplicate eligible contexts.
- [ ] Observations, open loops, memories, and confirmed task state are distinct.
- [ ] No screen-derived task/memory is silently committed by batch analysis.
- [ ] Every work claim is evidenced or honestly marked unknown/unavailable/gap.
- [ ] No productivity/focus score or moralizing label exists.
- [ ] Existing Library/Rewind, Workspace, and MetaChat surfaces carry the value; no new top-level area.
- [ ] Full build/tests and named signed-app day-analysis QA recorded before ITER-072.
