# ITER-070 — Structured feedback, semantic deduplication, and pacing

**Status:** planned.
**Depends on:** ITER-064..069 complete; every visible item already has durable identity and validated evidence.
**User outcome:** the user can explain what was wrong, control interruption frequency, and stop near-duplicate advice without teaching MetaWhisp that every closed popup was “bad.”

## 0. Goal and Definition of Done

Add a small, explicit learning loop around delivered Screen Agent items. Feedback changes future eligibility through deterministic policy and bounded semantic matching. Pacing becomes an understandable user choice rather than several unrelated cooldown constants.

This iteration does not fine-tune a model, upload private screen text for analytics, or build a hidden productivity score.

## 1. User stories

### US-070-1 — say what failed

As a user, I want to mark a comment as wrong, obvious, outdated, repetitive, or too intrusive so MetaWhisp can react appropriately.

**Acceptance:** feedback is linked to the exact item/delivery, persists after restart, and changes only the relevant future guard or pacing policy.

### US-070-2 — closing is not criticism

As a user, I want to close a popup because I am busy without accidentally training the agent that its content was wrong.

**Acceptance:** dismiss and timeout remain neutral interaction outcomes; negative feedback is a separate explicit action.

### US-070-3 — predictable frequency

As a user, I want plain-language Quiet, Balanced, and Frequent modes plus Pause so I can choose how often MetaWhisp interrupts me.

**Acceptance:** the UI explains the active mode; changing it affects the final delivery gate immediately and does not release a delayed popup backlog.

### US-070-4 — no repeated idea

As a user, I do not want the same advice rephrased every time the screen changes slightly.

**Acceptance:** semantically equivalent items in the configured suppression window become `silence(semanticDuplicate)` even when the wording differs.

## 2. Feedback contract

Use the V4 `feedbackReason` field and add only the minimum local metadata needed for policy, such as timestamp and optional reason-specific structured value. Do not store free-form private comments in telemetry.

Reasons and product meaning:

| Feedback | Meaning | Deterministic effect |
|---|---|---|
| `wrong` | Claim/action is incorrect | Block the same evidence + claim signature; add replay candidate for review |
| `obvious` | Correct but no incremental value | Raise novelty threshold for the same intent/referent |
| `outdated` | Context was no longer current | Record a freshness defect; never treat it as a taste preference |
| `repeat` | Already shown or handled | Extend duplicate suppression for the semantic signature |
| `tooIntrusive` | Timing/frequency is wrong | Reduce delivery budget/pacing pressure; do not mark factual content wrong |

Feedback UI is available from Inbox/item/thread. The popup may expose one compact `Not helpful` entry only if it does not compromise focus or accessibility; the complete reason picker lives in the activating MetaChat surface.

Rules:

- one current reason per item; changing it is an explicit update with audit timestamp;
- feedback cannot alter the historic run, evidence, delivery, or action receipt;
- a deleted item removes its feedback under the same retention policy;
- confirmed tasks and their action receipts are not undone by feedback;
- `outdated` increments a release-blocking freshness metric and adds the case to replay review;
- no model decides whether feedback “counts.”

## 3. Semantic identity and duplicate guard

Create `ScreenAgentSemanticFingerprint` from structured, local inputs:

- decision kind and primary action;
- normalized named referent(s): person, document, task, field, requirement, deadline;
- stable evidence source IDs and source kind;
- normalized proposed result entity ID when present;
- a local semantic vector only when an already-approved local embedding route is available.

The deterministic exact signature is always present. A semantic scorer may compare short safe summaries locally, but it never replaces hard evidence/freshness policy.

Starting suppression policy:

- exact signature: suppress for 24 hours unless the underlying task/deadline state materially changed;
- semantic equivalent for the same referent/action: suppress for 8 hours;
- explicit `repeat`: suppress that signature for 7 days;
- successful `actioned`: suppress the completed intent until source state proves a new need;
- `later`: do not create a new popup for the same item; it remains in Later until the user reopens it;
- source state change, new assignee, changed amount/date, or new contradictory evidence creates a new signature only when validated.

These are starting policy values, injected through one testable policy object rather than scattered constants. Dogfood evidence may change them in a later approved iteration without changing the meaning of the presets.

## 4. Pacing model

One `ScreenAgentPacingPolicy` owns generation budget and popup presentation budget. Generation may still run in shadow for quality measurement when presentation budget is exhausted, but it cannot create delayed user-visible backlog.

Initial user-facing presets:

| Mode | Popup cap | Minimum interval | Intended use |
|---|---:|---:|---|
| Quiet | 2/day | 180 minutes | Only rare, high-value intervention |
| Balanced | 5/day | 60 minutes | Default dogfood candidate after approval |
| Frequent | 10/day | 20 minutes | Active evaluation/high assistance |

Additional rules:

- `Pause` overrides every preset immediately;
- recorded-meeting DND remains an independent hard suppression;
- no category may bypass the cap in this iteration;
- changing Quiet -> Frequent does not replay suppressed old items;
- changing Frequent -> Quiet cancels queued presentation at the final gate;
- time-zone/day-boundary calculations use the user's current calendar with injected clock tests;
- the default for existing users remains off until ITER-072 migration/consent approval;
- the product owner may adjust the numeric starting values after ITER-064 baseline/dogfood review, but Claude may not silently tune them to improve metrics.

## 5. Private measurement contract

Allowed local/dogfood metrics:

- run/item/delivery IDs;
- decision/reason enums;
- generated/presented/opened/actioned/feedback counts;
- latency and route/model version;
- preset and budget outcome;
- evidence count/source-kind counts;
- reviewed usefulness label.

Forbidden analytics fields:

- OCR or screenshot/image content;
- window title, app document name, prompt content, message content;
- task/memory/file text;
- source excerpts or embedding vectors;
- people, company, URL, email, amount, or deadline values.

Metrics must preserve the distinction between generated, presented, reviewed, helpful, actioned, and confirmed success. An unreviewed item is `unmeasured`, not helpful.

## 6. Master checklist — one atomic commit per item

- [ ] **070.1 Feedback state contract.** RED dismiss != feedback, one-current-reason/update/restart/delete; implement exact item-linked persistence.
- [ ] **070.2 Reason picker and receipts.** Add accessible Inbox/thread flow; show saved state without exposing chain-of-thought or private telemetry.
- [ ] **070.3 Deterministic fingerprints.** RED punctuation/word-order/exact evidence/state-change cases; implement stable signature.
- [ ] **070.4 Semantic duplicate guard.** RED paraphrase/same referent versus genuinely changed deadline/assignee/state; local bounded scorer plus fail-safe exact fallback.
- [ ] **070.5 Feedback-specific policy.** Prove wrong/obvious/outdated/repeat/tooIntrusive affect different guards and never rewrite past truth.
- [ ] **070.6 Unified pacing policy.** Injected clock/budgets for Quiet/Balanced/Frequent/Pause/meeting DND; remove competing Screen Agent cooldown ownership.
- [ ] **070.7 Final-gate and no-backlog behavior.** Mode/pause changes mid-run suppress; later preset expansion never catches up old popups.
- [ ] **070.8 Privacy-safe metrics.** Schema allowlist tests and log inspection; raw content must fail encoding/export.
- [ ] **070.9 Replay and threshold report.** Run all 60 cases plus paraphrase/state-change additions; report silence/usefulness/freshness by prompt/policy version.
- [ ] **070.10 Named signed-app QA.** Feedback persistence, duplicate blocking, all presets, day boundary, Pause/DND, accessibility, and restart.

## 7. Required tests

```text
ScreenAgentFeedbackServiceTests
ScreenAgentSemanticFingerprintTests
ScreenAgentDuplicateGuardTests
ScreenAgentPacingPolicyTests
ScreenAgentMetricsPrivacyTests
ScreenAgentReplayTests
```

Required cases:

1. popup close/timeout produces no negative reason;
2. explicit feedback survives restart and is linked to one item;
3. changing a feedback reason does not duplicate the item or rewrite delivery history;
4. `outdated` is counted as freshness defect and release blocker;
5. paraphrased same action/referent is suppressed;
6. changed date, assignee, amount, or contradictory state is not suppressed merely by similar prose;
7. actioned task proposal does not resurface until new source state;
8. Quiet/Balanced/Frequent caps and minimum intervals obey an injected clock;
9. mode or Pause change after generation but before show suppresses;
10. ending Pause/DND or increasing frequency does not show old suppressed items;
11. local midnight/time-zone change does not double or erase budget unexpectedly;
12. analytics encoder rejects raw OCR, image, title, excerpt, and embedding fields.

## 8. Live QA

1. Show one deterministic item, close it, and verify no negative feedback.
2. Mark a duplicate item `Repeat`; generate a paraphrase; verify silence and one Inbox history.
3. Change the underlying deadline and repeat; verify a new grounded candidate is eligible.
4. Mark an item `Outdated`; verify dogfood freshness dashboard/report blocks release.
5. Exercise Quiet/Balanced/Frequent with an accelerated injected dogfood clock, then real-time smoke one item per mode.
6. Switch to Pause during an in-flight run; no popup and no later catch-up.
7. Restart and verify preset, feedback, and suppression persist.
8. Complete reason picker using keyboard and VoiceOver.
9. Inspect analytics/log payloads from the run; confirm content fields are absent.

## 9. Definition of Done

- [ ] All ten checklist items closed.
- [ ] Dismiss/timeout remain neutral; feedback is explicit and reasoned.
- [ ] Each reason changes the correct policy and preserves historic truth.
- [ ] Exact and semantic duplicates are suppressed without hiding material state changes.
- [ ] One policy owns Quiet/Balanced/Frequent/Pause and no delayed popup backlog exists.
- [ ] Private content cannot enter the metrics encoder or durable diagnostic logs.
- [ ] Replay report distinguishes unreviewed, helpful, harmful, stale, and actioned outcomes.
- [ ] Full build/tests and named signed-app QA recorded before ITER-071.
