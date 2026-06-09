# ITER-045 — Free OOTB + Second Brain hardening — implementation plan

**Source review:** `specs/audit/REVIEW-SECONDBRAIN-FREE-TRANSCRIPTION-2026-06-09.md` (Claude Fable,
cross-checked with Codex), cross-referencing `SECOND-BRAIN-REVIEW-2026-06-07.md` and
`FULL-APP-AUDIT-2026-05-31.md`.

**Status:** PLAN — Iter 0 done; Iter 1–5 reviewed by Codex (2026-06-09), corrections applied below.
**Owner discipline:** Ralph loop — one checklist item per iteration pass, TDD, commit per green item,
update `PROGRESS.md` at the end of each pass. Re-read this file + the master checklist every pass.

---

## Codex review — applied corrections (2026-06-09)  ⚠️ AUTHORITATIVE over the sections below

17/18 findings confirmed REAL against source. **TR-2 is STALE → dropped** (comment matches impl + tests).
Per-finding deltas to fold in when implementing:

- **FREE-1:** `ModelManagerService.shared` **does not exist** — the service is app-owned/injected. Wire the
  *real* injected `ModelManagerService.startModelDownload(...)` through onboarding with a concrete model id
  (default `large-v3-turbo`). Real downloader at `ModelManagerService.swift:77`.
- **FREE-3:** add `TranscriptionError.noAPIKey`, but DON'T turn every cloud failure into a Pro upsell.
  BYOK-missing-key → prompt key setup; Pro-only routes gate separately. (`CloudWhisperEngine.swift:76`
  throws `.modelNotLoaded`; rendered "Download a model first." at `WhisperKitEngine.swift:197`.)
- **CC-1 (narrow):** `MutationService` owns **only `Task` + `UserMemory`** (DB + Obsidian + MCP consistency).
  Do NOT route summaries/goals/weekly/recaps through it (overreach). Initial call sites: `ChatToolExecutor`
  (incl. `writeAudit`), `TasksView`, `MemoriesView`, and extractor INSERT paths if MCP freshness matters.
- **SB-1 (re-located):** real skip is `MemoryExtractor.swift:73` + `TaskExtractor.swift:71`
  (`guard !isRunning else { return }`), NOT `ConversationGrouper`. Per-conversation queue/backfill is right;
  **independent of CC-1** (can land first).
- **SB-2 (widen):** also covers `ChatToolExecutor.writeAudit` (save+audit must commit together or report
  "not recorded") and the **extractor INSERT paths outside chat** (same swallow-on-save class).
- **SB-3:** `MCPSnapshotService.snapshotNow()` exists (`:94`) but has **no call sites** — wire it. Plan
  overstates task gaps (some dismiss/export paths already exist). **Memory delete needs a real .md file
  cleanup design** (not just re-export).
- **SB-7:** keep **local in `DailySummaryService`** (NOT via MutationService). Generate→temp→replace only
  after successful save; stop swallowing the replacement save failure too. (`DailySummaryService.swift:95`
  deletes before generate; nil at `:118`.)
- **LIC-1 (re-scope):** NOT a hard verified-only flip. Use `isProVerified` + `isProEntitled =
  verifiedActive || cachedActiveWithinGrace`. Grace **7–14 days** (not 72 h) with a pre-expiry warning;
  server-cost features require recent verification, local UX accepts cached-verified. A bare cached license
  key with **no session token / no last-verified timestamp** must NOT grant Pro.
- **SEC-1 (partly stale):** deletion-after-readback **already exists** (`AppSettings.swift:450`). Remaining
  fix = remove/tightly-gate the **permanent plaintext fallback** in `KeychainHelper.load`
  (`AppSettings.swift:382`). Safe sequence: migrate → verify readback of *every* key → migration marker →
  delete/rename legacy; then no silent plaintext fallback. Don't delete if any key fails readback.
- **CC-2 (ownership):** readiness gate must be owned by **`OnboardingContainer`** (controls bottom NEXT),
  not only the model page — else NEXT bypasses page-level checks.
- **TR-1 (sharpen):** "relax for long meetings" is too vague. Concretely: remove human words like `music`
  from the **unconditional engine-level drop list** (`WhisperKitEngine.swift:140`) or make cleanup
  context-aware; keep boilerplate/toxic-token filtering.
- **TR-2:** ✂️ dropped (not a real bug).
- **Sequencing tweaks:** within Iter 1, fix model-manager injection BEFORE readiness gates. SB-1 is
  independent of CC-1. **SB-8 (live toggles) can move earlier** — it makes Iter 4 indexer/scheduler testing
  reliable.
- **Also flagged (fold into SB-5):** Apple Notes parsing uses `|||` field splitting — note bodies
  containing `|||` corrupt fields. Use a safer delimiter/encoding when touching SB-5.

---

## 0. Working principles (apply to every finding)

1. **VERIFY-then-fix.** The review's line numbers are *approximate* (already confirmed drift: SB-1's
   `isRunning` mechanism didn't grep — needs re-location). Before touching any finding: re-grep, read
   the real code, confirm the mechanism still exists. If it's already fixed → mark `done (stale)` and move on.
2. **TDD.** Failing test first (red), then the fix (green). UI-only findings that can't be unit-tested get a
   documented manual verification step instead.
3. **Source-of-truth fixes** (CLAUDE.md): fix at the owner layer, not child-layer patches. Several findings
   collapse into two cross-cutting owners — build those once (see §1).
4. **Surgical + proportional.** Touch only what the finding needs; keep existing style.
5. **No identifying names** in any shipped code/spec/test (open-source). Generic placeholders only.
6. **Build correctly:** `swift build && bash hot-swap.sh` (hot-swap alone deploys the *stale* `.build`
   binary — confirmed this session). `swift test` runs the `MetaWhispTests` target.

---

## 1. Cross-cutting owners (build these FIRST, inside their iteration)

### CC-1 — `MutationService` (linchpin for SB-2, SB-3, SB-7, parts of SB-6)
One entry point for every task / memory / summary / recap mutation.
- `save()` **throws → propagates**; callers get `Result`/throw. Never `try? + ok = true`.
- **Post-commit hooks** run only after a successful save: Obsidian re-export (single item) + MCP
  `snapshotNow()`. Hooks are best-effort/logged but never flip the mutation to "success" if save failed.
- Consumers migrate to it: `ChatToolExecutor`, `TasksView`, `MemoriesView`, `DailySummaryService`.
- Land incrementally — one call site at a time, each behind a test — to keep the diff reviewable.

### CC-2 — Onboarding completion gate (FREE-1, FREE-2, FREE-4, FREE-5)
`OnboardingWindowController.complete()` (and the try-it page's NEXT) require **≥1 genuinely working path**:
model actually downloaded (`ModelManagerService.isDownloaded`) **or** a validated cloud key **or** Pro active.
Pure decision helper `OnboardingReadiness.resolve(...)` → unit-testable; the view just renders/binds it.

---

## Iteration 0 — Housekeeping (before new work)

Land the already-confirmed, uncommitted work as clean checkpoints so the big plan starts from a green tree.

- [ ] **0.1** Remove the temporary `[CoachDiag]` diagnostic NSLogs from `MeetingCoachWindowController`
      (Meeting Copilot two-window fix is confirmed working).
- [ ] **0.2** Commit Meeting Copilot click-through fix (SelfSizingHostingView, CardShadowView, two-window
      controller, MeetingCoachView). Pre-commit name/secret grep.
- [ ] **0.3** Commit deep-link sign-in banner fix (SignInBannerDecision + NotificationService.postSignInResult
      + AppDelegate handler + WindowActivationGuard scan extended to App/) — if not already committed; run
      `swift test` for the guard + SignInBannerDecision suites first.
- [ ] **0.4** Decide on the Meeting Copilot **suggestion-pipeline** follow-up (gate works; downstream bugs #1–#5
      from Codex audit are unproven live). Park as ITER-046 or fold into Iteration 5 — NOT in this plan's P1/P2.

---

## Iteration 1 — Free works out-of-the-box  🔴 highest user value

**Goal:** a brand-new free user finishes onboarding only with a working transcription path; Right ⌘ never
errors with "No model loaded" after a "successful" setup.

**User story:** *As a free user, after onboarding I can dictate immediately, because setup refused to finish
until a real engine was ready.*

| ID | Verify | Fix | Test |
|---|---|---|---|
| **FREE-1** | `OnboardingModelPage.startDownload()` uses a `Timer` (confirmed earlier this session) | Call real `ModelManagerService.shared.startDownload()`, bind real `phase`/progress, gate NEXT on `isDownloaded(modelId)` | UI: download→ready→model file on disk; can't NEXT before done |
| **FREE-2** | `OnboardingWindowController.complete()` unconditional; cloud key field `.constant("")`; VERIFY no-ops | CC-2 readiness gate; real `@State` key field + real validation (cloud probe); try-it surfaces engine error and blocks | Unit: `OnboardingReadiness.resolve` truth table; manual: can't finish with no working path |
| **FREE-3** | `CloudWhisperEngine` throws `.modelNotLoaded` on missing key; coordinator maps it generically | Add `TranscriptionError.noAPIKey`; free user on a Pro/cloud feature → explicit "available in Pro" surface, not a cryptic error | Unit: error mapping; manual: missing-key path shows key prompt |
| **FREE-4** | `ModelManagerService` sets `phase = .done` without on-disk check | Verify `isDownloaded()` before `.done`; else `.failed` + retry affordance | Unit: interrupted download → `.failed`, not `.done` |

**Acceptance:** fresh-profile onboarding cannot complete without a working engine; dictation works
immediately after; cloud-key path validates; interrupted download is retryable.

---

## Iteration 2 — Second Brain data integrity  🔴 silent data loss

**Goal:** no silent loss of memories/tasks; external surfaces (Obsidian, MCP) never diverge from the DB.

**User stories:**
- *As a user, when two calls end at once, both get their memories/tasks — nothing is silently skipped.*
- *As a user, when the chat says "marked done", the DB, my Obsidian vault, and Claude Desktop all reflect it.*

- [ ] **CC-1** Build `MutationService` (see §1) + tests (save-fail propagates; hooks fire only on success).
- [ ] **SB-1** *(verify first — `isRunning` mechanism not at the cited lines)* Replace silent
      `guard isRunning` skip in the conversation-close extractor path with a **persistent per-conversation
      extraction queue** (states: pending/running/done/failed) + startup backfill of `pending`/`failed`.
- [ ] **SB-2** `ChatToolExecutor` (8 sites: 233/253/271/311/341/364/622/656) → route through `MutationService`;
      `try? save()` becomes a propagated throw; `ok = false` on failure; chat reports the real error.
- [ ] **SB-3** Obsidian re-export + MCP `snapshotNow()` from `MutationService` post-commit hook
      (covers TasksView/MemoriesView complete/edit/dismiss + memory-file deletion).
- [ ] **SB-7** Daily-summary regenerate: generate into a temp object, **replace only after a successful save**
      (no delete-before-create data loss on nil generation).

**Acceptance (tests from the review):** two simultaneous conversation closes → both extracted; a forced
save-failure in chat surfaces an error (no false success); complete/edit/dismiss update DB+Obsidian+MCP
atomically; regenerate-fail keeps the old summary.

---

## Iteration 3 — License & security  🔐

**Goal:** Pro gating can't be bypassed by a stale/planted Keychain key; secrets aren't readable on disk.

**User story:** *As the business, a stale or planted license key cannot unlock Pro routes indefinitely offline.*

- [ ] **LIC-1** Split `cached` vs `verified` Pro state in `LicenseService`; **Pro-gated routes require
      `verified`**; bound offline-grace with a TTL (e.g. 72 h) so cached-Pro expires without a server check.
      *Risk-managed:* feature-flag + conservative TTL so legit offline Pro users aren't locked out abruptly.
- [ ] **SEC-1** After a confirmed Keychain read-back of every migrated value, **delete `.secrets`** and remove
      the permanent plaintext read fallback (AppSettings:365–444). One-way migrate, then no plaintext on disk.
- [ ] **FREE-5** Onboarding Pro tab: subscribe to `$isPro`, auto-advance / "Check activation" button after the
      deep-link returns (no silent purchase limbo). (Pairs with the shipped deep-link banner.)

**Acceptance:** stale Keychain key offline → Pro routes inactive after TTL; `.secrets` gone after migration;
Pro onboarding confirms activation.

---

## Iteration 4 — Indexing & synthesis freshness

**Goal:** RAG/index never surface deleted content; Apple Notes scans paginate + don't re-burn LLM on empties;
weekly digest is reachable and self-heals; Second Brain toggles apply live.

- [ ] **SB-4** File index path reconciliation on every scan (+ tombstones); RAG checks file existence before
      returning. Deleted notes never leak into chat context.
- [ ] **SB-5** Apple Notes: paginate by `modifiedAt` (drop the hard 40 cap); separate processing-state
      (`lastResult`/`lastError`/`modifiedAt`) so empty-result notes aren't re-sent to the LLM every scan and
      edited notes get re-indexed.
- [ ] **SB-6** Weekly digest: add a UI section to read `PatternDigest`; on parse-fail store **nil** (not a fake
      "success" that blocks retries 6 days); fix the notification routing target.
- [ ] **SB-8** Central settings-observer: start/stop Daily/Weekly/FileIndexing/AppleNotes/Calendar schedulers
      on toggle change (no relaunch required).

**Acceptance:** deleted file absent from RAG after a scan; 100-note vault continues past note 41; broken weekly
JSON doesn't block retries; toggling a Second Brain feature takes effect immediately.

---

## Iteration 5 — Polish

- [ ] **SB-9** Extractors trim + reject empty/whitespace memories & tasks (TaskExtractor / MemoryExtractor /
      FileMemoryExtractor).
- [ ] **SB-10** TasksView "N active" excludes completed.
- [ ] **TR-1** Hallucination filter: relax for long meeting recordings so legitimate short utterances aren't dropped.
- [ ] **TR-2** Remove the stale comment in `TranscriptionLanguageResolver` (bug already fixed).

---

## Master checklist (canonical — sync `PROGRESS.md` to this each pass)

**Iter 0 housekeeping:** ☑ 0.1 ☑ 0.2 (b168cfa) ☑ 0.3 (ff1d0d7) ☑ 0.4 (suggestion pipeline → ITER-046)
**Iter 1 Free OOTB:** ☑ FREE-1 ☑ FREE-2 ☑ FREE-3 ☑ FREE-4   *(real download+auto-load+gate on "loaded"; validated cloud key; noAPIKey error; verify-on-disk before .done) — Codex-verified 1A+1B*
**Iter 2 Data integrity:** ☐ SB-1 *(independent)* ☐ CC-1 ☐ SB-2 ☐ SB-3 ☐ SB-7 *(local)*
**Iter 3 License/security:** ☐ LIC-1 *(grace, not hard flip)* ☐ SEC-1 *(KeychainHelper.load fallback)* ☐ FREE-5
**Iter 4 Indexing/synth:** ☐ SB-8 *(can move earlier)* ☐ SB-4 ☐ SB-5 ☐ SB-6
**Iter 5 Polish:** ☐ SB-9 ☐ SB-10 ☐ TR-1   ~~TR-2~~ *(dropped — stale)*

## Tests to add (mapped to iterations)

- Iter1: onboarding can't finish without a working engine (FREE-2); interrupted download → `.failed` (FREE-4).
- Iter2: two simultaneous conversation closes → both extracted (SB-1); chat save-fail → error, no false success
  (SB-2); complete/edit/dismiss → DB+Obsidian+MCP atomic (SB-3); regenerate-fail keeps old summary (SB-7).
- Iter3: stale offline Keychain key → Pro routes inactive after TTL (LIC-1).
- Iter4: deleted file absent from RAG after scan (SB-4); 100 notes, first 40 done → scan continues from 41 (SB-5);
  broken weekly JSON → retry not blocked 6 days (SB-6).

## Risks / rollback

- **LIC-1** is the riskiest: tightening Pro gating can lock out legitimate offline Pro users. Mitigate with a
  feature flag + generous TTL + telemetry before enforcing. Roll back = flip flag.
- **SEC-1** is destructive (deletes `.secrets`). Only delete after a verified read-back of *every* value from
  Keychain; keep a one-release safety window where migration runs but deletion is gated behind a confirmed flag.
- **CC-1 MutationService** touches many call sites. Land call-site-by-call-site behind tests; never big-bang.
- Sequencing: Iter 1 first (broken-for-free is the highest user-visible harm); Iter 3 before any public release
  (security). Iter 2 depends on CC-1 existing.
