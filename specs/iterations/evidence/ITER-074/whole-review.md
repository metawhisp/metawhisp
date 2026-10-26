# ITER-074 — whole-layer review, 2026-09-24

Two independent read-only reviews of every file in `Services/Agent/` and its tests, at `ab6a131`:
Codex (`codex-whole`) and a Claude review agent. The label-word reader and classifiers were excluded
(their own Codex rounds 15–23 ran at the same time). Every finding below was checked against the code by
the orchestrator before it was written here. None of them had been raised by the per-commit rounds 5–23:
a search of the 46 evidence files finds only neighbouring points (cookie-banner recognition in round 5,
slotted text reaching the excerpt in rounds 7 and 10).

Verdict of both reviewers: not ready for the owner's live session.

Legend: **Confirmed** — traced in the code in this session; **Likely** — depends on a part not written
yet (the Dia bridge, the real Sheet).

## Safety — to fix before the live session

| # | Finding | Where | Source | Status |
|---|---|---|---|---|
| S1 | Back is a fresh GET to the previous address, with no guard: a page can plant `/deleteAccount` with `history.replaceState`, and a back to an approved `/buy?…` sends it again without a Yes | `AgentRun.swift:356-367`, `SafetyGuard.swift:76` | Codex 1, Claude 2 | Confirmed |
| S2 | A select's chosen option is not read by the lexicon or the grant check: "Delete account" or "Allow access" as an option of a neutral select is not asked about | `SafetyGuard.swift:53`, `:112` | Codex 2 | Confirmed |
| S3 | The action script does not look at the page's flags: payment or login fields that appear between the choice and the act do not stop the click | `ActionScript.swift` (no flag check) | Codex 4 | Confirmed |
| S4 | A web component's button has no name: slotted text is judged by its `<slot>`, which has no box, and the tree walker never reaches assigned nodes — `<sl-button>Delete account</sl-button>` reaches the engine and the lexicon nameless. Partly a side effect of the round-10 fix (`99bf8be`: a slotted text is judged by its slot) | `ObserverScript.swift:177-181`, `:220-231` | Claude 1 | Confirmed |
| S5 | Cookie banners are not handled in the loop: `CookieBanner` has no production caller, so «Accept all» goes through the lexicon («accept») and the user is asked — decision 15 forbids it; an unrecognised blocking overlay is not skipped (§7.2, §11) | `SafetyGuard.swift:173-248`, `AgentRun.swift` | Claude 11 | Confirmed |

## The loop against the spec

| # | Finding | Where | Source | Status |
|---|---|---|---|---|
| L1 | No source URL in the Sheet: only the writer's cells are pasted (US-9, J2, §17.2 ask for one on every row). The Sheet has no header row either | `AgentRun.swift:490`, `SheetCells.swift:54` | Claude 4, Codex 10 | Confirmed |
| L2 | `type` is offered with no text and can never act; the writer is never asked for it (§6.6) | `CandidateBuilder.swift:118`, `ActionScript.swift:76` | Claude 8, Codex 6 | Confirmed |
| L3 | `done` or `stuck` ends the errand at any confidence, even with no rows | `AgentRun.swift:194` | Codex 7 | Confirmed |
| L4 | A login form ends the errand and closes its tab instead of the pause with [Продолжить] (§11); a transient error ends the whole errand as failed (a slow page should be a miss); the rows are lost unless the errand is done or stuck | `AgentRun.swift:103-116`, `:156` | Claude 3, Codex 8 | Confirmed |
| L5 | The Sheet's address is recorded only after a paste; a paste whose reply is lost, or Stop after the paste, skips the read-back although §7.4 checks a sent action's postcondition; `AgentRunTests.swift:235` asserts the skip | `AgentRun.swift:493-497` | Claude 6, Codex 5 | Confirmed |
| L6 | A paid call can overrun the 600 s by its own deadline: `timeLeft` counts only the 30-minute expiry | `AgentRun.swift:274`, `AgentPolicy.swift:151` | Codex 9 | Confirmed |
| L7 | The paste's screen-consent wait counts as work time and has no bound from the expiry | `AgentInterfaces.swift:85-95`, `AgentRun.swift:494-497` | Claude 7 | Likely |
| L8 | Stop leaves the tab open when the bridge honours cancellation: `closeTab` runs in the cancelled task | `AgentRun.swift:112` | Claude 5 | Likely |
| L9 | The step log: an action chosen on the step that completed the rows is logged `acted` although it was never sent; a failed postcondition erases that the user had said Yes | `AgentRun.swift:189-191`, `:249` | Claude 9 | Confirmed |
| L10 | No loop test answers Yes in time, and none asserts `.confirmed` or `.failed` | `AgentRunTests.swift` | Claude 10 | Confirmed |

## A known limit — not fixable in v1

| # | Finding | Where | Source | Status |
|---|---|---|---|---|
| K1 | The observer runs in the page's own JavaScript world: a page that rewrites `JSON.stringify` or another built-in can forge the report — clear the flags, put text in names. Only an isolated script world closes this; Dia's AppleScript runs scripts in the page's world. §7.3 already says a hostile page can steer; it should say this too | `ObserverScript.swift:733` | Codex 3 | Confirmed |

## Decisions for the owner
- L1: a header row with the plan's column names — and the source column's name.
- L4: the pause card for a login form; whether an errand that ends early still pastes what it collected
  (§8 says no Sheet at a ceiling or after Stop).
- Russian names of a secret («Пароль», «Код из SMS») need a test with Cyrillic text; tests are English-only.
