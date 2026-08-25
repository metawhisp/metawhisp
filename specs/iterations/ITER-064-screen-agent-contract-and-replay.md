# ITER-064 — Screen Agent contracts, V4 spine, and replay baseline

**Status:** planned; no implementation started.
**Depends on:** product owner approval of the master plan.
**User-visible behavior:** unchanged.
**Next:** `ITER-065` only after every DoD item below is green.

## 0. Goal and Definition of Done

Create the stable language and durable identity for every later Screen Agent slice before changing capture, prompts, models, or UI.

This iteration succeeds when:

1. typed decisions, evidence, runs, items, delivery and feedback outcomes exist;
2. a V3 store migrates to V4 without losing current data;
3. a versioned replay deck contains 60 privacy-safe scenarios, with at least 40 executable before this iteration closes;
4. the current system has a saved baseline by decision/reason/evidence validity, not cherry-picked text examples;
5. no user-visible screen behavior changes.

## 1. User stories

### US-064-1 — quality can be proven

As a user, I want Screen Agent changes evaluated against useful, silent, stale, unsafe, and malformed scenarios so a prompt tweak cannot quietly make the product worse.

**Acceptance:** every fixture reports the expected decision and reason codes; privacy/freshness/evidence violations are deterministic failures.

### US-064-2 — a comment has one identity

As a user, I want a future card, its source, its action, its chat continuation, and my feedback to refer to one durable item.

**Acceptance:** the schema can represent one run -> optional item -> delivery -> optional thread without using a closure or hidden prompt string as identity.

### US-064-3 — update does not risk history

As an existing user, I want the new agent records added without changing or losing my dictations, meetings, tasks, memories, or screen history.

**Acceptance:** V3 -> V4 and a fresh V4 store both open with intact legacy counts and empty new tables.

## 2. Non-goals

- Do not change `InsightPrompts`, model tiers, thresholds, cooldowns, notifications, task behavior, capture cadence, Settings, or onboarding.
- Do not wire V4 models into production behavior yet.
- Do not add a live network eval to the normal test suite.
- Do not add screenshots or raw OCR to fixtures, telemetry, or new models.
- Do not modify frozen V1-V3 schema shapes.

## 3. Pure contracts

Create `Services/Intelligence/ScreenAgentContracts.swift` with Codable/Equatable value types and strict enums.

### AgentDecision

```text
silence(reason)
suggestion(payload)
taskProposal(payload)
taskCompletionProposal(payload)
resurface(payload)
```

No `unknown(String)` fallback on the delivery path. Unknown model values fail closed during parsing.

### SilenceReason

At minimum:

```text
disabled, setupRequired, excluded, noPermission, captureFailed, emptyContext,
unchanged, insufficientDwell, lowSignal, noValue, generic, wrongOwner,
notGrounded, unknownEvidence, staleVisit, deadlineExceeded, duplicate,
dnd, paced, providerFailed, parseFailed, persistenceFailed, purged,
ownerScopeChanged
```

### EvidenceRef

Runtime issues evidence IDs; the model only returns those IDs.

```text
id
sourceKind: screenContext | screenObservation | task | memory | conversation | file
sourceID
visitID?
capturedAt?
validUntil?
contentHash?
normalizedQuoteHash?
```

Raw quote text belongs only in the local source/evidence resolver and optional user-facing safe excerpt under retention. It must not enter metrics.

### RunOutcome

```text
started, silence(reason), itemCreated(itemID), cancelled(reason), failed(reason)
```

### DeliveryOutcome and InteractionOutcome

Delivery terminal truth:

```text
presented, suppressed(reason), failed(reason)
```

Post-presentation interaction:

```text
opened, dismissed, timedOut, replaced, later, actioned, feedback
```

Never represent `generated` as a delivery outcome. Generation is a run state.

### FeedbackReason

```text
wrong, obvious, outdated, repeat, tooIntrusive
```

Closing a popup is neutral and must not become negative feedback.

## 4. V4 persistence contract

Add the five models described in the master plan:

- `Models/ContextVisit.swift`;
- `Models/ScreenAgentRun.swift`;
- `Models/ScreenAgentItem.swift`;
- `Models/ScreenAgentDelivery.swift`;
- `Models/ScreenAgentThread.swift`.

Use UUID foreign keys and Codable JSON envelopes for evidence/actions/message IDs. Do not add SwiftData relationships or change existing model layouts in this iteration.

Add `MetaWhispSchemaV4` containing all existing V3 models plus the five new ones, then one V3 -> V4 lightweight stage. Keep V1, V2, and V3 frozen.

Required model-level invariants:

- one `ScreenAgentItem.runID` per non-silence run;
- item creation is idempotent by run ID at the persistence owner layer;
- one delivery attempt has one terminal outcome;
- `ScreenAgentRun` stores prompt ID/version, actual runtime route/model identifier, schema version, deadline, and reason code;
- analytics-safe fields are separable from local private source summary;
- no screenshot blob and no raw OCR field exists in these models.

## 5. Replay deck

Create fixtures under `Tests/MetaWhispTests/Fixtures/ScreenAgent/v1/`.

Each fixture contains:

```json
{
  "id": "stable_case_id",
  "locale": "en",
  "timeline": [],
  "evidence": [],
  "existing_tasks": [],
  "recent_items": [],
  "policy": {},
  "model_output": {},
  "expected_decision": "silence",
  "expected_reason_codes": ["no_value"],
  "allowed_evidence_ids": [],
  "forbidden_claims": [],
  "max_tool_calls": 0
}
```

Golden labels are decision, reason codes, evidence IDs, action permission, and tool budget. Never assert exact generative prose.

Target distribution (60 total):

- 15 mandatory silence/generic/ordinary reading;
- 12 useful suggestion/conflict/mistake cases;
- 10 commitment, recipient, owner, fulfillment cases;
- 8 rapid-switch/freshness/content-resolution cases;
- 6 retrieval and notification-follow-up cases;
- 5 prompt-injection/privacy/owner-scope cases;
- 4 malformed schema/non-finite/tool-loop cases.

At least RU and EN appear in every applicable class.

## 6. Master checklist — one atomic commit per item

- [ ] **064.1 Pure enums and validation.** Add failing tests for unknown decisions, invalid evidence IDs, non-finite confidence, multiple decisions, and delivery double-terminal transitions; implement the minimum contracts.
- [ ] **064.2 Replay loader and reporter.** Add a failing malformed-fixture test; implement deterministic loading and per-case diagnostics.
- [ ] **064.3 First 40 fixtures and current baseline adapter.** Do not change current prompts. Record which current parser/guard would allow/block and why.
- [ ] **064.4 V4 models and migration.** RED V3 -> latest; add models/stage; prove legacy row counts and empty new tables.
- [ ] **064.5 Complete 60-case catalog and baseline report.** Save the report under `specs/screen-agent/baselines/` with date, commit, prompt hashes where known, model routes labelled observed/unmeasured, and every failing case.
- [ ] **064.6 Privacy audit of the new spine.** Prove no fixture/report/model includes raw screenshot data and analytics export contains only IDs, timings, enums, and reason codes.

## 7. Required tests

Proposed test files:

```text
Tests/MetaWhispTests/Services/Intelligence/ScreenAgentContractsTests.swift
Tests/MetaWhispTests/Services/Intelligence/ScreenAgentDeliveryStateTests.swift
Tests/MetaWhispTests/Services/Intelligence/ScreenAgentReplayTests.swift
Tests/MetaWhispTests/Services/Data/SchemaMigrationTests.swift
```

Required RED cases:

1. model returns an evidence ID not present in the run allowlist;
2. confidence is NaN, Infinity, negative, or greater than one;
3. model returns both task and suggestion;
4. delivery attempts to go `suppressed -> presented`;
5. an item is inserted twice for the same run;
6. malformed fixture gives a case ID and exact schema error;
7. V3 store opens under V4 with all legacy data;
8. current-code baseline demonstrates at least one stale/ungrounded/generic failure instead of pretending baseline is green.

## 8. Verification

Focused commands, adapted to actual XCTest discovery:

```bash
swift test --filter ScreenAgentContractsTests
swift test --filter ScreenAgentDeliveryStateTests
swift test --filter ScreenAgentReplayTests
swift test --filter SchemaMigrationTests
swift build
swift test
```

No signed-app live test is required because production wiring remains unchanged. Do inspect a copy of the real store with the existing migration test mechanism if it is available and explicitly safe.

## 9. Definition of Done

- [ ] All six master checklist items closed with RED/GREEN evidence.
- [ ] At least 40 executable and 60 catalogued fixtures; per-case report committed.
- [ ] Critical policy cases are fail-closed in the new validator.
- [ ] V3 -> V4, fresh V4, and frozen-shape tests green.
- [ ] Full build/test counts recorded in `specs/screen-agent/PROGRESS.md`.
- [ ] No screen capture, prompt, notification, task, chat, or Settings behavior changed.
- [ ] Product owner reviews the baseline failures before `ITER-065` begins.
