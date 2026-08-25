# ITER-068 — Anchored MetaChat continuation and confirmed actions

**Status:** planned.
**Depends on:** ITER-067 persistent item/Inbox complete.
**User outcome:** `Ask MetaWhisp` continues the exact comment with its original evidence, and screen-derived mutations happen only after explicit confirmation with a receipt.

## 0. Goal and Definition of Done

Connect every Screen Agent item to the existing MetaChat agent runtime. Replace the dead/string-only proactive handoff with a typed thread anchor. Reuse current read tools, mutation validation, confirmation, audit, receipts, and undo.

This iteration must not create another LLM chat service or add external computer-control tools.

## 1. User stories

### US-068-1 — same episode

As a user, I want to ask `Why?`, `What should I reply?`, or `Which option fits?` without explaining the screen again.

**Acceptance:** follow-up uses the item's original visit, safe source summary, and validated evidence even after the user switches windows.

### US-068-2 — explicit current screen

As a user, I want the agent to distinguish the old card source from whatever is on screen now.

**Acceptance:** no silent recapture occurs; `Look at current screen` is a separate explicit action that adds a clearly labelled new context.

### US-068-3 — safe task action

As a user, I want to edit and confirm a proposed task before it reaches My Tasks, then see success/failure/undo.

**Acceptance:** exactly one staged candidate becomes committed only after confirmation; double clicks/retries cannot duplicate it.

### US-068-4 — persistent continuation

As a user, I want an item reopened after restart to return to the same conversation.

**Acceptance:** one item creates or reuses one `ScreenAgentThread`; repeated opens scroll to the same anchor.

## 2. Thread model and typed navigation

Use the V4 `ScreenAgentThread` UUID link model. Do not change `ChatMessage` layout unless a RED performance/correctness test proves `messageIDsJSON` insufficient.

Create `ScreenAgentThreadService`:

- `openOrCreate(itemID)` is idempotent;
- validates item/run/visit owner scope;
- stores linked ChatMessage IDs after each send/reply/tool step;
- reopens the same thread after restart;
- deletes linked messages when screen-history delete policy deletes the unconfirmed item;
- does not copy raw OCR into ChatMessage text.

Replace `.proactivePrefillChat` string handoff with a typed request containing `itemID`/`threadID`. The current auto-submit behavior must not send an invented question on the user's behalf.

Item detail and thread render a source anchor above messages:

```text
Screen Agent item
Slack — #launch — captured 14:03
Anna expects the final deck by 16:00.
[Why this?] [Look at current screen]
```

If source retention removed raw evidence, show the saved safe summary and `Source no longer available`; never reconstruct a quote.

## 3. Frozen notification context in ChatService

Add a typed `ScreenAgentThreadContext` parameter/path to `ChatService.send` and prompt assembly. It contains:

- item/run/visit IDs;
- source label and capture time;
- safe summary;
- validated evidence refs and currently available safe excerpts;
- proposed action and existing result receipt;
- explicit marker that this is historical/frozen notification context.

Put it in a delimited untrusted-data block. The system prompt states:

- answer about the original item by default;
- do not replace it with current screen context;
- if evidence expired/deleted, say so;
- fresh capture is used only after explicit user action;
- previous assistant claims are not ground truth;
- action success exists only when a tool receipt says so.

Typed and voice follow-ups inside the same item thread append to the same canonical thread. A standalone voice question outside the thread keeps its existing scoped behavior.

## 4. Task and action contract

### Screen task proposal lifecycle

1. A grounded `taskProposal` item may create one linked `TaskItem(status="staged")` when dogfood delivery is enabled.
2. It is absent from My Tasks and visible as a candidate/fallback review item.
3. `Add to My Tasks` opens an editable confirmation for description, due date, and owner.
4. Add a typed `promoteTaskCandidate` tool/action to `ChatToolExecutor` or an equivalent owner-layer command using the same validation/audit/undo seam.
5. Confirm commits the same task ID and writes one receipt to the item/thread.
6. Cancel leaves staged or dismisses only according to the explicit choice.
7. Repeated confirm is idempotent and reports already committed, not success twice.

### Fulfillment

Screen evidence may propose `Mark done`; it does not call current invisible `applyFulfillment` in v2 mode. Reuse `completeTask` confirmation, receipt, and undo.

### Promotion service

In v2 `dogfood/live`:

- `TaskPromotionService` must not silently move staged screen candidates to committed;
- `TaskPrioritizationService` continues ranking staged candidates;
- ranked candidates may be resurfaced through director/Inbox subject to pacing;
- legacy behavior remains available only in mutually exclusive rollback/off mode.

Voice-explicit and calendar task behavior is unchanged.

## 5. Why this?

`Why this?` shows product rationale, not chain-of-thought:

- safe source excerpt(s) tied to evidence IDs;
- named linked task/memory/project fact when used;
- source time and availability;
- processing mode (local text/cloud text/visual when later enabled);
- short reason code translated for the user.

Never display the model's hidden reasoning string as proof.

## 6. Master checklist — one atomic commit per item

- [ ] **068.1 Thread service/idempotent anchor.** RED repeated open/restart/owner mismatch/deleted item; implement one thread per item.
- [ ] **068.2 Typed navigation and Chat/Inbox routing.** Replace string prefill/auto-submit for Screen Agent; repeated open scrolls to one anchor.
- [ ] **068.3 Frozen prompt context.** RED current Slack screen replacing original pricing item; inject original evidence and require explicit recapture.
- [ ] **068.4 Source availability and Why this.** RED deleted/expired/unknown evidence; render safe sources or honest unavailable state, never model reasoning as proof.
- [ ] **068.5 Staged task creation.** Idempotently link one staged candidate to a taskProposal item; no My Tasks entry before confirm.
- [ ] **068.6 Confirm/edit/promote action.** Add validated action/tool with audit, receipt, undo, persistence-failure truth, and double-click idempotency.
- [ ] **068.7 Fulfillment confirmation and legacy promotion cutover.** v2 proposes complete; disables silent screen promotion/auto-complete; ranking stays.
- [ ] **068.8 Other safe actions.** Only actions already supported by ChatToolExecutor/MutationService; unsupported external actions are explained, never faked.
- [ ] **068.9 Typed + voice same-thread continuity.** Voice follow-up in an open item thread persists there; standalone voice behavior unchanged.
- [ ] **068.10 Named signed-app end-to-end.** Popup/Inbox -> thread -> why -> task confirm -> receipt/undo -> restart -> reopen.

## 7. Required tests

```text
ScreenAgentThreadServiceTests
ScreenAgentChatContextTests
ScreenAgentNavigationTests
ScreenAgentWhyThisTests
ScreenAgentTaskActionTests
ChatToolSchemaSyncTests
ScreenRetentionTests
```

Required cases:

1. one item opened twice creates one thread/anchor;
2. restart reopens same thread and linked messages;
3. original pricing/SSO source remains active after user switches to Slack;
4. no fresh capture occurs without explicit action;
5. explicit recapture is labelled new and does not overwrite original evidence;
6. missing/deleted source yields honest unavailable state;
7. staged candidate is not in My Tasks before confirmation;
8. editable confirmation commits exactly one TaskItem with preserved source link;
9. cancel/failed save/double-click/retry produce correct state and receipt;
10. completion requires confirm and supports undo;
11. v2 promotion timer cannot silently commit staged candidate;
12. unsupported send/email/file/browser action cannot produce a success claim;
13. screen-history delete removes unconfirmed linked thread messages, confirmed task stays.

## 8. Live QA

1. Produce the pricing/SSO grounded item.
2. Switch to Slack, open `Ask MetaWhisp`, ask `Which option fits?`; verify original context.
3. Use `Look at current screen`; verify explicit second context.
4. Open the same item again; verify one thread/anchor.
5. Restart app; reopen from Inbox.
6. Produce task proposal; inspect/edit confirmation; verify absent from My Tasks before confirm.
7. Confirm twice rapidly; verify one task and one success receipt.
8. Undo if supported; verify task/item/audit truth.
9. Produce fulfillment evidence; verify no auto-complete, then confirm Mark done.
10. Delete raw source; old thread shows unavailable, does not invent evidence.
11. Try unsupported `send this email`; agent must not claim it sent anything.

## 9. Definition of Done

- [ ] All ten checklist items closed.
- [ ] String-only Screen Agent prefill/auto-submit removed.
- [ ] Every item opens/reuses one frozen-context MetaChat thread.
- [ ] Current screen is added only by explicit action.
- [ ] Why this shows validated source, never chain-of-thought.
- [ ] Screen-derived task creation/completion requires confirmation, is idempotent, and has receipt/undo truth.
- [ ] Silent v2 screen task promotion/fulfillment is disabled; ranking remains.
- [ ] No new general agent or external computer-control tool exists.
- [ ] Full build/tests and named signed-app end-to-end recorded before ITER-069.
