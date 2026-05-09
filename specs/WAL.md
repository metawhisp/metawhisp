
## Released v1.3.2 — 2026-05-09 02:30 GMT+3

**Status: SHIPPED to users via:**
- ✅ GitHub Release [v1.3.2](https://github.com/metawhisp/metawhisp/releases/tag/v1.3.2)
- ✅ Cloudflare Pages deploy `b17438ec` (appcast.xml + 13 blog posts intact + sitemap)
- ✅ Cloudflare Page Rule flipped to `releases/latest/` pattern (no more per-version dashboard edits ever)
- ✅ Hot-swap on `/Applications/MetaWhisp.app` (PID 43837)
- ⚠️ Source push to github.com BLOCKED tonight by network MITM (SSL self-signed cert + 444 from intercept). Local commit `726c515` ready; user pushes when network unblocked.

**Root cause that took 4 failed releases to find:** `build.sh` line 212 was `cp -r "$APP_DIR" "$INSTALLED_APP"` — macOS `cp -r` dereferences symlinks, destroying Sparkle.framework's required `Sparkle → Versions/Current/Sparkle` etc symlink layout. Apple notary then reject with "signature invalid" because CodeDirectory hashes (computed on pristine, with-symlinks artifact) didn't match the `cp -r` post-state (with-files-instead-of-symlinks). Fix: `cp -r` → `ditto`.

**Also fixed in build.sh same session:**
- TSA retry budget 3→10 with exponential 5→60s sleep — Apple TSA outages last minutes, the old 8s window blew through them.

**1.3.2 user-visible changes** (`website/src/appcast.xml` updated):
- Back-to-back transition via stable EKEvent.eventIdentifier (replaces flaky window-title heuristic)
- Stop-reason on every meeting recording stop
- Calendar-end auto-stop with grace
- Conversation titles preserve calendar event names
- Project clustering deduplicates aliases at load
- Privacy: scrubbed personal references from binary strings
- Health-report cron sentinel
# WAL — Write-Ahead Log

**Backlog:** открытые треки перечислены в `specs/BACKLOG.md` (source of truth). Ни одна работа не начинается без OK user'а.

**Session handoff:** `specs/HANDOFF.md` — обязательно прочитать при старте новой сессии (после BOOT/KARPATHY/BACKLOG).

**Shipped in session 2026-04-19 (summary):** Phases 0-3 end-to-end (Conversations, Screen pipeline, Readers), sidebar reorg 9→6 tabs, MetaChat brand + RAG + typing animation, Phase 6 voice questions (long-press Right ⌘ → TTS answer) with redesigned floating UI + STOP/Space/Esc controls. Phase 4/5/7/8 planned in BACKLOG. E4 Gmail + E5 unified runner deferred.

**Shipped in session 2026-04-20 (summary so far):**
- Cleanup: rewrote 2 pushed commits to scrub external-reference name from titles + bodies, renamed branch to `architecture-phase-1-3` (force-push), scrub commit `96bd8e2` across 37 repo files (165+/215−).
- Phase 6+ Premium TTS shipped: backend `/api/pro/tts` endpoint (OpenAI tts-1 proxy, 6 voices) + frontend dual-provider routing (cloud if Pro+enabled, else AVSpeech) + Settings Cloud Voice toggle gated on Pro. Awaiting user deploy of `api/` + `wrangler secret put OPENAI_API_KEY` before live test.

**Shipped in session 2026-05-08 night (ITER-032.2 — curative pass + canonical-by-conv-count + free-form rename):**

### Why ITER-032.2: ITER-032.1 stopped the bleed but didn't clean existing mess

ITER-032.1 prevented FUTURE hallucinations (LLM now sees existing canonicals in prompt) and shipped manual UI controls (MAKE CANONICAL / SPLIT OUT). User pushback: «борешься со следствием а надо с причиной — у всех пользователей тоже должна быть такая история, их не должно быть ничего про HallucinatedName». Manual UI fix-up doesn't scale; the auto-curative pass should heal existing data automatically for every user.

### ITER-032.2 components

- **`Services/Intelligence/AliasCanonicalPicker.swift` (NEW, ~30 LOC pure func)** — `pickByConversationCount(variants:counts:) -> String`. Replaces the old "winner = most variants" heuristic with "winner = most conversation references". Case-insensitive count lookup, alphabetical tie-break. 6 RED→GREEN tests in `AliasCanonicalPickerTests.swift`.
- **`Services/Intelligence/ProjectAggregator.swift`** — four new methods:
  - `curativePass(generator:) async` — orchestrates the three-step migration
  - `reclassifySuspiciousConversations(generator:) async` — for each conversation whose `primaryProject` is NOT in the established-canonicals set (alias with conv count ≥ 2), null out structured fields and re-run `StructuredGenerator.generate(...)`. The new prompt (ITER-032.1) injects the canonicals list, so LLM is encouraged to reuse `Example Project` over inventing `HallucinatedName`. 300ms throttle between calls so it doesn't hammer the proxy.
  - `recanonicalizeAll() -> Int` — for every alias, tally conversation counts per variant, then `AliasCanonicalPicker.pickByConversationCount(...)` to set `canonicalName`. Updates `updatedAt` only when the pick differs from current.
  - `pruneOrphanAliases() -> Int` — delete alias rows whose every variant has 0 conversation references. Cleans up after `reclassifySuspicious` migrated conversations away.
  - `renameCanonical(currentCanonical:newName:) -> Bool` — free-form rename. Unlike `setCanonical`, accepts ANY string; adds it to `aliases` if missing, then promotes to canonical. Used by the new ProjectDetailView rename input.
- **`App/AppDelegate.swift`** — one-shot startup migration gated by `@AppStorage("didCurativePass_iter032_2")`. Runs once after the existing `backfillProjects` + `mergeAliases` pipeline. Flag flips to `true` after success; future launches no-op.
- **`Models/AppSettings.swift`** — `didCurativePass_iter032_2: Bool = false` flag. Suffix bumps when shipping a future curative sweep.
- **`Views/Windows/ProjectsView.swift` ProjectDetailView** — gained a `RENAME` section: text field + `RENAME` button. Disabled when input is empty/whitespace-only. Calls `renameCanonical(currentCanonical:newName:)` and refreshes local state on success. Lets the user override the auto-pick or invent a brand-new display name.

### Effect for shipped users (every Pro account)

- First launch after ITER-032.2 hot-swap: `[ProjectAggregator] curative pass — first run after upgrade` log line.
- `[ProjectAggregator] reclassify: N suspect conversations` followed by N × LLM calls (~300ms apart).
- `[ProjectAggregator] recanonicalize: 'HallucinatedName' → 'Example Project'` for any alias where the highest-count variant differs from current canonical.
- `[ProjectAggregator] prune: '<empty alias>' (0 conversations across N variants)` for orphans.
- After this pass, `HallucinatedName`-style hallucinations either:
  - Get re-tagged onto a real cluster (if LLM matches the conversation to an established canonical), OR
  - Become 1-conversation singletons (hidden by `≥2` filter in Projects view), OR
  - Get pruned entirely (if conversation gets re-tagged elsewhere and alias goes to 0 references).
- User never sees `HallucinatedName` in Projects view again unless it's a real project they keep mentioning.

**Shipped in session 2026-05-08 evening (ITER-034 — calendar-end-aware auto-stop + Pro proxy quota raise):**

### ITER-034 — calendar-end auto-stop using `EKEvent.endDate`

User report 2026-05-08: «созвон не выключается». Manual stops at 09:45 (15 min into 9:30-10:00 event) and 10:41 (41 min into 10:00-10:30 event) — recordings overran calendar end by ~10 min on average. silence guard (3 min) was the only auto-signal but ANY continued audio (people lingering, music playing, dictation nearby) reset it.

- **`Services/System/CalendarEndStopDecision.swift` (NEW, ~75 LOC pure func + Equatable enum)** — `evaluate(now:eventEnd:audioRMSLastNSec:notifyAttemptsSoFar:graceSeconds:extensionSeconds:quietRMSThreshold:maxNotifyAttempts:) -> .keepRunning | .stopNow | .notifyAndExtend(newDeadline:) | .hardStop`. Defaults: 60s grace, 5min extension, 0.005 RMS threshold, 3 max notify attempts. 8 RED→GREEN tests in `CalendarEndStopDecisionTests.swift` covering: keepRunning before end, keepRunning within grace, stopNow when quiet past grace, notifyAndExtend on active audio (1st + 2nd attempts), hardStop after maxAttempts, custom quiet threshold, custom grace.
- **`Services/Indexing/CalendarReaderService.swift`** — added `event(forIdentifier:) -> EKEvent?` so AppDelegate can resolve the EKEvent from the eventID it already stores (`recordingCalendarEventID`). Returns nil if access not granted or event deleted.
- **`App/AppDelegate.swift`**:
  - `calendarEndNotifyAttempts: Int` — counter for `notifyAndExtend` rounds, reset on each new recording.
  - `armCalendarEndStopTask(eventID:eventEnd:)` — schedules a `Task` that sleeps until `eventEnd + grace`, then calls `CalendarEndStopDecision.evaluate(...)` and acts on the outcome:
    - `.keepRunning` (rare at fire time) — re-arm in 60s as safety
    - `.stopNow` — `stopMeetingRecording(reason: "calendar-end-grace:<eventID>")`
    - `.notifyAndExtend(newDeadline)` — push `MWNotification` "Meeting overrunning — Tap to stop now or it will re-check in 5 min", increment attempts, re-arm to fire at `newDeadline`
    - `.hardStop` — `stopMeetingRecording(reason: "calendar-end-hard-stop:<eventID>")`
  - `runCountdownAndStartRecording(...)` — after `meetingRecorder.start(...)`, if `calendarEventID != nil`, resolves the EKEvent, snapshots `endDate`, and arms the task. Skips when event duration > 6h (heuristic: all-day events are not normal meetings) — falls back to silence guard.
  - `stopMeetingRecording(...)` — already cancels `calendarHardStopTask` on every entry (existing slot was reserved but never used; ITER-034 fills it). Also handles the post-start audio-sniff cancel path.

### Pro proxy quota — raised 60→180 min/day, 1800→5400 cap (api Worker deploy)

User report 2026-05-08: dictations + meetings hit the 1800-min cumulative cap on the Pro tier (60 min/day accrual). LiveAdvise partials every 30s during meeting recording compounded the consumption — typical workday consumes 100-180 min audio across dictations + meeting transcribe + LiveAdvise overhead.

- **`api/src/index.js`** — `dailyAllowance: 60 → 180`, `maxBalance: 1800 → 5400`. Error message text + docstring synced. Effect for license >30 days old: previously earned cap = 1800 (likely all spent), now earned cap = 5400 → effective balance jumps by ~3600 min instantly.
- Deployed via `wrangler deploy` to `api.metawhisp.com/*` (Worker `metawhisp-api`, version `7d502d45`). User-visible immediately.
- 4 Cloudflare API tokens were inadvertently pasted in chat during the deploy negotiation and remain compromised — user committed to revoking all four via dash.cloudflare.com/profile/api-tokens. Future deploys to use `security find-generic-password -s metawhisp-cf -w` (per `RELEASE-PLAYBOOK.md` convention) so the secret stays out of chat transcripts.

**Shipped in session 2026-05-08 later (ITER-032.1 — revert Lev auto-merge + LLM canonical-aware prompt + Rename/Split UI):**

### Why a follow-up: HallucinatedName regression

Auto-merge from morning ITER-032 ship absorbed `ExampleProject.ai`, `ExampleProject`, `Example Project` under `HallucinatedName` (LLM hallucination from a single past session). Lev distance between `atomicbata` ↔ `atomicbot` is 2 with shared length ≥ 5, so the rule fired — but the WINNER was the garbage variant because winner-pick was by `aliases.count`, not conversation count or "name quality". Same risk would exist for every shipped user. User explicitly: «HallucinatedName — такого проекта нет, ты почему контекст не читаешь». Right call.

### ITER-032.1 fix

- **`Services/Intelligence/ProjectClusterDecision.swift`** — Lev branch removed. Auto-merge now ONLY collapses canonical-equality (case fold + translit + emoji + punctuation + whitespace differences). Typo merges (`Island Expand` ↔ `Island Expend`) are NOT auto-decided — they go through user-approval UI. `Levenshtein.swift` retained (file + tests) for future LLM-curated cleanup pass / second-brain validation, but no longer wired into `canMerge`.
- **Tests updated** in `Tests/MetaWhispTests/Services/Intelligence/ProjectClusterDecisionTests.swift`:
  - `test_singleTypo_isNotAutoMerged` — regression guard pinning typos to user-approval path
  - `test_atomicBataNotMergedWithExampleProject` — explicit guard against the production false positive
  - `test_punctuationOnly_merges` — uses `ChatApp.` ↔ `ChatApp,` (both canonicalize to `chatapp`)
- **`Services/Intelligence/ExistingProjectCatalog.swift` (NEW, pure func, ~50 LOC)** — `promptHint(from:minCount:maxRows:)`. Builds an "EXISTING PROJECTS (use these EXACT names if conversation matches; do NOT invent variants like 'HallucinatedName' when 'Example Project' already exists)" block listing canonical names + conv counts, sorted desc, capped at 30 rows. Singletons excluded by default (convCount ≥ 2). 5 RED→GREEN tests in `ExistingProjectCatalogTests.swift`.
- **`Services/Intelligence/StructuredGenerator.swift`** — `buildPrompt(transcript:startedAt:)` now also fetches established canonicals via `projectAggregator?.listProjects(includeSingletons: false)` and embeds the catalog hint into the user prompt. Empty-string fallback when no projectAggregator wired or no qualifying projects. ~15 LOC. Effect: LLM sees user's real project list with conv counts → reuses exact names instead of inventing variants. Stops the bleed for future conversations.
- **`Services/Intelligence/ProjectAggregator.swift`** — three new methods:
  - `aliasVariants(for canonicalName:) -> [String]` — fetch all known variant strings under a cluster
  - `setCanonical(currentCanonical:newCanonical:) -> Bool` — promote an existing variant to canonical (variant must already be in the aliases list; preserves exact original casing)
  - `splitAlias(currentCanonical:variantToSplit:) -> Bool` — extract a variant out into its own ProjectAlias row (handles edge case of splitting the canonical itself by promoting another variant first; refuses if cluster has only 1 alias)
- **`Views/Windows/ProjectsView.swift` ProjectDetailView** — gained an `ALIASES` section (visible when cluster has ≥2 variants) with one row per variant. Each row shows a star indicator (filled for current canonical), the variant text, and two action buttons: `MAKE CANONICAL` (greyed for current canonical, replaced by `CANONICAL` tag) and `SPLIT OUT` (orange). Fetched on `.task` via `aliasVariants(for:)`. Mutations refresh local state immediately. Lets the user fix any auto-merge mistake in seconds — exactly the escape valve the Lev-merge approach was missing.

### Behaviour change for shipped users

- Old behavior: `HallucinatedName` swallows `Example Project` cluster automatically.
- New behavior: those stay as separate `ProjectAlias` rows. `HallucinatedName` is a singleton (convCount=1) — hidden from Projects view by default (display threshold from morning ITER-032). User sees only `Example Project (24 conversations)` in the grid. LLM future classification reuses `Example Project` because the canonical list is in the prompt.
- For users who already shipped with bad merges (e.g. dev test): open ProjectDetailView → ALIASES → MAKE CANONICAL on the right variant → SPLIT OUT the garbage one. ~10 seconds.

**Shipped in session 2026-05-08 (ITER-032 — Projects auto-dedup with translit + Levenshtein + digit-token guards):**

### ITER-032 — Projects auto-merge on creation + curative pass + display threshold

User report 2026-05-08: «у меня в проектах какая-то грязь — ~52 alias rows, реально проектов десяток. Голосок/VoiceSnack дублируется, Island/Island Expand/Island Expend (typo), Atomic-zoo. Нужно чтобы он сам анализировал и адаптировал — мы же делаем второй мозг.» Pre-fix `ProjectAggregator.resolveCanonical` did `localizedCaseInsensitiveCompare` only — no transliteration, no typo tolerance, no length/digit guards. Every LLM-hallucinated variant became a new alias row.

- **`Services/Intelligence/ProjectAliasNormalizer.swift` (NEW, ~30 LOC)** — pure func `canonicalize(_:) -> String`. Pipeline: Apple's `.toLatin` ICU transliteration (`Голосок → Golosok`, `й → j`, `ц → c`) → lowercase → strip non-alphanumeric except space → collapse whitespace → trim. Original variant preserved unchanged in `ProjectAlias.aliasesJSON`; canonical is comparison-only.
- **`Services/Intelligence/Levenshtein.swift` (NEW, ~35 LOC)** — Wagner-Fischer minimum edit distance, single-row DP (O(m·n) time, O(n) space). Symmetric. Used for typo tolerance in cluster decision.
- **`Services/Intelligence/ProjectClusterDecision.swift` (NEW, ~75 LOC)** — pure func `canMerge(_:_:) -> Bool` combining everything in priority order:
  1. Either input empty → false
  2. Canonical forms equal → true (case / translit / emoji / punctuation only)
  3. Digit-token guard: if either side has digit tokens AND tokens differ (or asymmetric presence) → false. Catches `Q3` ≠ `Q4`, `CryptoWallet 2.0` ≠ `CryptoWallet 3.0`, `ChatApp 2026` ≠ `ChatApp`. Versions / quarters / years stay separate.
  4. Length guard: shorter canonical ≥ 5 chars before Lev applies (prevents `API` ↔ `AWS` collision via Lev=2).
  5. Levenshtein distance on canonicals ≤ 2 → true. `Island Expand` ↔ `Island Expend` (1 char) merges.
- **22 RED→GREEN unit tests** in `Tests/MetaWhispTests/Services/Intelligence/{ProjectAliasNormalizerTests,LevenshteinTests,ProjectClusterDecisionTests}.swift`. All green at `0.005s` total. Honest documented limitation: free-form translit (e.g. LLM `VoiceSnack` for `Голосок`) is too lexically far for Stage 1 → caught by Stage 2 embedding cosine instead.
- **`Services/Intelligence/ProjectAggregator.swift`** — three wires:
  - `resolveCanonical(_:)` — Phase A: existing fast exact-match path. Phase B (NEW): `ProjectClusterDecision.canMerge` against any variant of any existing alias → if match, `addAlias` to existing instead of inserting a new row. Logs `[ProjectAggregator] dedup: '%@' → '%@'`.
  - `mergeAliases()` — gained Stage 1 deterministic pass BEFORE the existing embedding-centroid stage. Cross-pair every variant of every alias through `canMerge`; absorb smaller cluster into larger; log `deterministic merge: '%@' ← '%@'`. Stage 2 (embedding cosine ≥ 0.88) unchanged. Total `lastMergeCount = stage1 + stage2`. Runs at app startup (already wired) so legacy 52-alias mess auto-collapses on first launch.
  - `listProjects(includeSingletons:)` — new parameter, defaults to `false`. Filters out projects with `conversationCount < 2`. Strips one-off LLM hallucinations from the grid.
- **`Models/AppSettings.swift`** — `@AppStorage("projectShowSingletons") var projectShowSingletons: Bool = false`.
- **`Views/Windows/ProjectsView.swift`** — `ALL` / `≥2` toggle in header. ALL state shows everything; ≥2 hides singletons. Tooltip explains what each state means.

**Shipped in session 2026-05-07 (Calendar title priority for Library / Obsidian / row):**

### ConversationTitleResolver — calendar event name beats LLM-generated title

User report 2026-05-07: today's recordings showed "Discussing Project Updates And Marketing" in Library, but the actual calendar event was `Standup C`. Same for `Daily Sync` → "Video Generator Finalized". Calendar names — what user TYPED in their calendar — were being silently overwritten by LLM theme inference. Earlier 2026-05-02 fix only patched the recap popup (which reads `conv.calendarEventTitle`); the Library/Obsidian/row title (`conv.title`) still got stomped by `parsed.title` from the LLM.

- **`Services/Intelligence/ConversationTitleResolver.swift` (NEW, ~25 LOC pure func)** — `resolve(calendarEventTitle: String?, llmTitle: String) -> String`. Calendar title wins if non-empty; otherwise fallback to LLM title (manual recordings / no calendar permission / no link found). 3 RED→GREEN tests in `Tests/MetaWhispTests/Services/Intelligence/ConversationTitleResolverTests.swift`.
- **`Services/Intelligence/StructuredGenerator.swift`** — both title-assignment paths route through resolver:
  - Short-transcript / placeholder path (line ~256): was hard-coded `conv.title = "Quick note"` → now `ConversationTitleResolver.resolve(calendarEventTitle: ..., llmTitle: "Quick note")` so a sub-300-char meeting still inherits its calendar event name.
  - LLM-result path (line ~296): was `conv.title = parsed.title` → now resolver.
- **No backfill** per user spec ("предыдущий можешь не трогать"). Pre-existing rows keep their LLM-generated titles. Fix applies to conversations created after 2026-05-07 hot-swap (PID 24450).

**Shipped in session 2026-05-06 (ITER-028 — back-to-back via calendar event ID + stop-reason logging + daily health cron):**

### ITER-028.2 — back-to-back transition pivots from window-title to calendar `EKEvent.eventIdentifier`

User report 2026-05-06: «не записывается созвон» — third report in 3 days. Health reports `specs/health-reports/2026-05-05.md` and `2026-05-06-morning.md` documented a 100% kill rate on calendar-triggered recordings: 09:30 + 10:00 + 14:00 all killed within 78s by the back-to-back race. Root cause: Google Meet tab title evolves through 4+ stages (`Meet`, `Meet - Google Chrome - …`, `Meet – ROOM-NAME - …`, `Meet – ROOM-NAME - Camera and microphone recording - …`) within the first ~1s after page mount. Lazy-capture grabbed one stage; next tick saw a different stage; back-to-back killed. The 2026-05-04 lazy-capture patch and 2026-05-03 isManualMode guard were both bandaids on a fundamentally flaky signal source.

- **`Services/System/BackToBackTransition.swift` (NEW, ~80 LOC pure func)** — `decide(currentRecordingEventID, gateDecision, isManualMode) -> BackToBackDecision (.keepRecording | .stopAndRestart(newEventID, newName))`. Compares stable `EKEvent.eventIdentifier` instead of mutable window titles. Manual mode short-circuits unconditionally. Fallback recordings (no eventID baseline) are left alone. RED-then-GREEN with 8 unit tests in `Tests/MetaWhispTests/Services/System/BackToBackTransitionTests.swift`.
- **`App/AppDelegate.swift`** —
  - Replaced `recordingFrontmostTitle: String?` with `recordingCalendarEventID: String?`.
  - Restructured `startMeetingAutoStartTickLoop`: now always evaluates the gate (even while a recording is active), then dispatches via `BackToBackTransition.decide`. Old window-title comparison block + lazy-capture deleted.
  - `runCountdownAndStartRecording` accepts `calendarEventID: String?` parameter; stores it in `recordingCalendarEventID` at start. Caller at the gate `.calendarReady` switch passes the eventID; fallback path passes nil.
  - **CC-14 inline fix**: when `BackToBackTransition.decide` returns `.stopAndRestart`, AppDelegate stops A AND immediately calls `runCountdownAndStartRecording(name: newName, source: "calendar", calendarEventID: newEventID)` in the same tick. Necessary because `MeetingAutoStartGate.lastCalendarEventID` blocks the gate from re-emitting B on subsequent ticks (it's a "fire-once-per-event" invariant that we can't violate without breaking the calendar trigger semantics).

### ITER-028.1 — `stopMeetingRecording(reason:)` mandatory parameter

Audit gap discovered when investigating 2026-05-05 10:00 case: a recording stopped after 86s with NO log line explaining why (no back-to-back, no silence guard, no manual stop). Diagnostic blindspot meant the only way to find the cause was to cross-grep timestamps and guess.

- `stopMeetingRecording()` → `stopMeetingRecording(reason: String)`. Logs `[MetaWhisp] ▶️ stopMeetingRecording reason=%@` on entry. All 4 call sites updated:
  - `meetingRecorder.onAutoStop` callback → `recorder-auto-stop:<reason>`
  - `toggleMeetingRecording` (user STOP button) → `user-toggle`
  - Dictation card "End meeting" tap → `dictation-end-card-tap`
  - Back-to-back fast-tick kill → `back-to-back-eventID:<newID>`
- The post-start audio-sniff path that calls `meetingRecorder.stop()` directly (not via wrapper) at `runCountdownAndStartRecording` line ~1730 was intentionally left unchanged — its log line `[CallDetect] ⚠️ %@ post-start sniff — silence (audioLevel=...)` already explains why.
- TDD: per `specs/TDD.md` exclusion (NSLog is not a pure function, AppDelegate orchestration is integration), no XCTest. Smoke validates by tail-grep of next stop event.

### Daily health-report cron — `33 10 * * 1-5` (read-only sentinel)

User: «можешь анализировать мои созвоны за прошлый день, есть ли ошибка». Created via SDK `CronCreate` with `recurring: true, durable: true` — but runtime flagged it `session-only` and 7-day auto-expire is hard. Documented as known limitation; long-term replacement via `launchctl` plist + shell script is `ITER-030` candidate.

- Prompt is self-contained (cron-fired agents have no conversation memory) and read-only: NEVER build/edit/hot-swap. Reads `~/Library/Logs/MetaWhisp.log`, filters yesterday's lines, finds every `[CallDetect] ▶️ <name> auto-start` and pairs with the next `[MeetingRecorder] Stopped` to compute duration + kill reason + transcription outcome. Writes report to `specs/health-reports/YYYY-MM-DD.md`. Posts macOS notification on any `❌` failure. Chat output capped at 8 lines.
- Seeded reports manually for 2026-05-05 (3 auto-starts: 1 ❌ empty, 2 🟡 partial — all back-to-back race or unlogged early stop) and 2026-05-06-morning (2 ❌ — both back-to-back race). Demonstrated the regression pattern that motivated ITER-028.2.

### Known unfixed: ITER-029 backlog — fallback gate too strict for windowed Meet usage

User report 2026-05-06 at 13:01: hour-long ad-hoc Meet call (no calendar event) — never recorded. `[CallDetect] Google Meet detected — gate now monitoring for sustained signal (10s frontmost+fullscreen)` fired but `[CallDetect] gate fallback ready` never followed. Cause: `MeetingAutoStartGate` requires 10s sustained frontmost AND fullscreen. Real-world: user has Meet in a window alongside Notion/Slack and tabs around → streak resets. Anti-noise gard for ITER-026 v2 was too tight. Backlog candidate ITER-029: replace fullscreen gate with audio-activity probe (mic OR system audio above speech threshold for 10s straight). Robust because real call = real audio; background Meet tab without audio still rejected.

**Shipped in session 2026-05-05 (Launch at login):**

### Launch at login via SMAppService.mainApp (copy of reference desktop pattern)

User request 2026-05-05: «MetaWhisp не включается при включении компа, давай добавим». Standard macOS feature, missing.

- **`Services/System/LaunchAtLoginManager.swift` (NEW, ~80 LOC)** — `@MainActor`/`ObservableObject` singleton wrapping `SMAppService.mainApp` (macOS 13+; Package.swift target is `.macOS(.v14)`, no availability gate needed). Pattern copied verbatim from reference `LaunchAtLoginManager.swift` (63 LOC), only `log()` → `NSLog`. Exposes `@Published isEnabled`, `@Published statusDescription`, `setEnabled(_:) -> Bool`, `updateStatus()`. Source-of-truth is the system, NOT a mirrored `@AppStorage` flag — System Settings → Login Items can flip the registration externally and a local mirror would silently drift.
- **CC-13 fix (built in from the start, not a follow-up)** — observer on `NSApplication.didBecomeActiveNotification` calls `updateStatus()` so when user flips the Login Item from System Settings while MetaWhisp is in the background, the toggle in our Settings reflects reality the moment we re-foreground. Closure hops to `MainActor` via `Task { @MainActor in ... }` since `updateStatus()` is actor-isolated.
- **`Views/Windows/MainSettingsView.swift`** — added `@ObservedObject launchAtLogin = LaunchAtLoginManager.shared`. In `optionsSection` after `AUTO-PASTE`: `toggleRow("LAUNCH AT LOGIN", isOn: Binding(get: ..., set: launchAtLogin.setEnabled))` + caption `Text(launchAtLogin.statusDescription)`. Binding round-trips through `setEnabled` → `updateStatus`, so a failed register snaps the toggle back to OFF (no lying UI).
- **`App/AppDelegate.applicationDidFinishLaunching`** — one-line `LaunchAtLoginManager.shared.updateStatus()` after `MW.applyTheme`. Re-reads at every launch in case the user flipped Login Items while the app was off.
- Tests: per `specs/TDD.md`, `SMAppService` is a TCC-style system service → manual smoke only. No XCTest.
- Smoke executed by user on 2026-05-05: toggle ON → reboot Mac → MetaWhisp auto-launched on login. Confirmed working.

**Shipped in session 2026-05-02 / 2026-05-03 (massive marathon — auto-record gate, calendar awareness, dictation pause, manual mode, back-to-back, 1.3.1 release with TSA-flake fix, GitHub Releases architecture for DMG distribution):**

### ITER-026 v2 — meeting auto-start gate (root-cause fix for false-positive recordings)

User report 2026-05-02: «у меня запись началась хотя я в Telegram сидел / Meet-вкладка лежала в фоне». Pre-fix logic: any single tick of frontmost-window scan that matched a call pattern (Meet/Zoom/Teams) → 5-sec countdown → auto-start. Failed in two directions: (a) leftover background Meet tabs caused random recordings, (b) tabbing away from Meet during a real call killed the recording via 180s callEnded debounce.

- **`Services/Audio/MeetingAutoStartGate.swift` (NEW)** — singleton state holder. `evaluate(callName, isFullscreen, audioActive, calendarEventNow)` returns `.idle / .tracking(secondsLeft) / .fallbackReady(name) / .calendarReady(name, eventID)`. Two paths:
  - **Strong (calendar):** non-allday EKEvent whose startDate is in `(now - 65s, now]` AND endDate >= now → fires immediately on first tick that sees the event boundary.
  - **Weak (fallback):** call window must be FRONTMOST + FULLSCREEN sustained for 10 seconds straight before firing. Streak resets on signal drop.
- **`App/AppDelegate.startMeetingAutoStartTickLoop()`** — 1-sec poll loop. Samples `NSWorkspace.frontmostApplication`, checks fullscreen via `kAXFullScreenAttribute` + bounds compare against `screen.frame`, queries calendar via new `CalendarReaderService.eventStartingNow()`. Skips entirely while a recording is active or a countdown is in flight.
- **`runCountdownAndStartRecording(name:source:)`** — pushes a 5-sec countdown plashka into `MWNotificationStack`. Dismissal (×) cancels. Otherwise starts `meetingRecorder.start(manualMode: false)` and waits 3 seconds. If `audioLevel < 0.01` (silent room / AFK) → stops without persisting. Avoids "Quick note (empty)" rows clogging Library.
- **`handleCallContext` rewritten** — old path (auto-start on first detect) gutted. Now only posts the `.call` MWNotification card. Auto-start is entirely owned by gate. The 180s callEnded debounce shrunk to a 60s session-end grace timer that ONLY resets `CallSessionMachine`; recording is NEVER stopped on window-loss anymore (per user spec: "то что в окне нет = не значит запись остановилась — другие сигналы говорят что идёт").
- **`Services/Screen/ScreenContextService.captureIfChanged`** — call-detect reverted from multi-window scan back to FRONTMOST-ONLY (per user spec 2026-05-02: «созвон ВСЕГДА начинается с окна куда смотрит пользователь, не с какой-то 95-й вкладки в фоне»). The brief-lived multi-window scan caused background Meet tabs to falsely trigger recordings. The previous concern that frontmost-only would lose the signal during tab-switches is now solved differently: once recording started, window state doesn't matter — silence guard owns the stop decision.

### ITER-026 v2 — dictation-during-meeting → pause + "End meeting?" card

User feedback 2026-05-02: «если я диктую сразу после созвона, диктовка попадает в meeting transcript». Solution: when any dictation/voice-question/translate hotkey fires while a meeting is recording, pause the meeting mic stream and offer the user a one-tap option to end the meeting.

- **`Services/Audio/MeetingRecorder.pauseMic() / resumeMic()`** — record `pauseStartedAt: Date?`. On `stop()`, accumulate pause windows (start/end seconds since `recordingStartedAt`) and zero out matching slices of the raw mic samples via `applyPauseMutes(to:)` before returning. System audio keeps recording during pause (other side may still be speaking).
- **`AppDelegate.dictationDidStart()`** — called by `TranscriptionCoordinator.startRecording`. If `meetingRecorder.isRecording`, calls `pauseMic()` + pushes a `.recordingStopped`-kind card "Meeting recording in progress / Tap to end meeting now". Card's `onTap` calls `stopMeetingRecording()`.
- **`AppDelegate.dictationDidEnd()`** — called from `TranscriptionCoordinator.stopAndTranscribe` right after `recorder.stop()`. Resumes meeting mic. Failed-start path (`catch` in startRecording) also calls dictationDidEnd to avoid dangling pause.
- **Safety net**: `MeetingRecorder.stop()` checks `if pauseStartedAt != nil { resumeMic() }` so a meeting stopped mid-dictation still gets a closed pause window.

### ITER-026 v2 — manual recording = no auto-stop

User spec 2026-05-02: «если я нажал RECORD сам, то остановиться может только мной нажатой STOP. Через 2 часа покажи плашку что 2 часа уже идёт, но НЕ останавливай».

- `MeetingRecorder.start(manualMode: Bool = false)` — flag stored as `private(set) var isManualMode`. When true, `armMaxDurationGuard` and `armSilenceGuard` are SKIPPED; instead `armManualHeartbeat()` runs (one-shot Task that fires `onManualHeartbeat` after 2h).
- `AppDelegate.startMeetingRecording()` (menu-bar STOP/RECORD path) → `meetingRecorder.start(manualMode: true)`.
- `runCountdownAndStartRecording` (gate auto-start path) → `meetingRecorder.start(manualMode: false)` — full guards apply.
- `meetingRecorder.onManualHeartbeat = { [weak self] in ... }` in AppDelegate pushes a non-blocking `.recordingStopped`-kind card "Recording: 2 hours elapsed". One-shot for now (TODO: re-arm every 2h).

### ITER-026 v2 — back-to-back meeting transition via callSignature

User spec: «если митинг А до 15:00 и Б с 15:00, нужно проверять — открылся ли НОВЫЙ митинг (другая комната), или А затягивается». Solution: snapshot the frontmost window title at recording start; in fast-tick loop, compare against current title. Same → don't fire B's plashka (it's the same call). Different → stop A, let next tick fire B.

- `AppDelegate.recordingFrontmostTitle: String?` captured in `runCountdownAndStartRecording` after `meetingRecorder.start` succeeds; cleared in `stopMeetingRecording`.
- Fast-tick loop: if recording is active AND `!meetingRecorder.isManualMode` AND frontmost title is itself a call window AND it differs from `recordingFrontmostTitle` → call `stopMeetingRecording()`, continue tick. Next tick re-evaluates gate for new call.
- `isManualMode` guard added 2026-05-03 after smoke check — without it, a manual recording started in (e.g.) Notion would be auto-stopped if the user later opened Meet, because Meet ≠ Notion's title. Manual recordings are user-controlled and ignore back-to-back transition logic entirely.

### ITER-026 v2 — back-to-back guard hardened against non-call frontmost at auto-start (2026-05-04)

User report 2026-05-04 (PID 21010, two sequential calendar-triggered Daily Sync recordings killed within 90 sec each): «не записывается созвон / начался 34 минуты назад и сейчас новый начался». Log evidence: `[CallDetect] back-to-back: live='Meet - Google Chrome - <User> (example.com)' != recorded='‎⁨<Telegram contact>⁩ – (24999)' → stopping current recording`. The recorded title was a Telegram chat (bidi-isolate Unicode marks `U+2068/2069` around the contact name + unread counter `(24999)` is a Telegram macOS window-title signature). Root cause: at calendar-strong auto-start, `recordingFrontmostTitle` was unconditionally set to whatever was frontmost — which was Telegram because user was reading messages while waiting for the meeting to start. As soon as user fronted the Meet tab, fast-tick saw `live (Meet) != recorded (Telegram)` and fired back-to-back stop — TWICE in 90 sec.

- `AppDelegate.runCountdownAndStartRecording` — at auto-start, `recordingFrontmostTitle` is now set to the live title ONLY if `SystemAudioCaptureService.detectCallContext(...)` confirms the frontmost is itself a call window. Otherwise stays `nil`. Telegram / Notes / Slack frontmost → no spurious title captured.
- `AppDelegate` fast-tick (`startMeetingAutoStartTickLoop`) — added a "lazy capture" branch: if `recordingFrontmostTitle == nil` and the current tick sees a real call frontmost, lock that title in as the canonical recordedTitle (logs `[CallDetect] back-to-back: lazy-captured recordedTitle='%@'`). The existing inequality branch (`live != recorded`) only fires after a real call title was canonicalized — so it can only stop on Meet→ZoomDifferentRoom, never on Telegram→Meet.
- Tests: existing `CallSessionMachine` tests cover the announce-once / decline-stickiness invariants; this fix is in the AppDelegate orchestration layer, not the state machine. Smoke test: trigger a calendar event auto-start while sitting in a non-call app (Telegram/Notes/Slack) → recording must NOT be killed when fronting the Meet/Zoom tab.

### ITER-026 v2 — silence guard 10 → 3 minutes + migration

User spec 2026-05-02: «через 10 минут может начаться другой созвон уже и ты скажешь что этот тот же — нужно меньше». Lowered `meetingSilenceStopMinutes` default 10 → 3. With ITER-026 v2's no-auto-stop-on-window-loss policy, silence guard is now the SOLE auto-stop signal for gate-triggered recordings, so it needs to be tight enough that back-to-back calls don't merge.

- `Models/AppSettings.swift` — `+@AppStorage("didMigrateSilenceStop_iter026") didMigrateSilenceStop: Bool = false`. Default for `meetingSilenceStopMinutes` lowered to 3.
- `AppDelegate.migrateSilenceStopMinutesOnce()` runs at launch. If user's existing UserDefaults value is `>= 9.5` (legacy default), bump to 3. User-tweaked values stay as-is.

### Calendar-task pipeline removed (ITER-026)

Earlier in the session: `CalendarReaderService.scanNow()` was bulk-creating `TaskItem(taskDescription: shortenTaskDescription(event.title), dueAt: event.startDate, sourceApp: "Calendar")` for every upcoming non-cancelled non-declined calendar event in a 14-day window. ~10 fake "tasks"/day at this user's calendar density. Tasks like "Tech Interview: Person — Marketing manager — Acme" rotted in the Tasks tab forever because nothing flipped them to completed when the meeting passed.

- `CalendarReaderService.scanNow` task-creation loop deleted. Calendar memory-extraction (recurring patterns) preserved.
- `Services/Intelligence/TaskExtractor.extractFromConversation` now passes a `CalendarMeetingContext` (title + start + end + attendees) to the LLM as enrichment context, so transcript-extracted tasks reference real attendee names ("Send draft to Mark" vs "Send draft to him"). System prompt extended with a `CALENDAR MEETING CONTEXT (when present, READ FIRST)` section.
- `Models/AppSettings.swift` — `+@AppStorage("didMigrateCalendarTasks_iter026")`. `AppDelegate.migrateCalendarTasksOnce()` runs at launch and bulk-dismisses every TaskItem with `sourceApp == "Calendar"` plus orphans (no conversationId, has dueAt, empty/nil sourceApp). Soft delete only.
- `CalendarReaderService.linkConversation` candidates now filter `if ev.isAllDay { return false }` — Holiday calendars (e.g. "Holidays in Serbia") emit 24h all-day rows that always overlap any conversation, scoring `timeOverlapFraction = 1.0` and hijacking meeting titles. Verified via direct EventKit query during the session: only `Holidays in Serbia` emits all-days; every real meeting is a bounded slot.

### Dual-stream merger — per-utterance Whisper segments

Garbled "Me: <5 min monologue> / Them: <5 min monologue>" recap symptom traced to `App/AppDelegate.transcribeStreamChunked` collapsing every audio chunk's text into a single `StreamSegment(startSec=chunkStart, endSec=chunkEnd)`. Fixed by iterating `result.segments` and emitting one `StreamSegment` per Whisper utterance with absolute timing = `chunkStartSec + whisperSeg.start`. Merger now interleaves at real-utterance grain — `Me: hi / Them: hello / Me: how are you / ...` like a real dialog.

### StructuredGenerator title prompt hardened against generic single-noun titles

User report 2026-05-02: «все вчерашние созвоны называются invoice». Confirmed no "invoice" calendar event exists — LLM was hallucinating from a single common transcript word. System prompt extended with HARD-FORBIDDEN list (single-noun generics: "Invoice", "Meeting", "Sync", "Call", "Discussion", "Standup", "Talk", "Update"; category words: "Work", "Project", "Business"). Requires ≥3 informative words OR proper noun + action noun.

### ITER-026 v2 — unified notification stack (eliminated top-right overlap)

Earlier in session: macOS-native `UNUserNotificationCenter` banners and the standalone `ProactiveChipWindow` both lived in the top-right corner without knowing about each other → visual collision.

- **New unified system** in `Views/Notifications/`:
  - `MWNotification.swift` — single struct + `Kind` enum (`.task | .call | .recordingStopped | .recap | .advice | .proactive`).
  - `MWNotificationCard.swift` — Liquid Glass card layout, 344pt wide, header (kind icon + uppercase tracked label + relative time + close ×) + body (title + 3-line body, OR multi-row for `.proactive`).
  - `MWNotificationStack.swift` — singleton state, `push(_)` inserts at index 0 with spring animation, hard cap 4 cards, FIFO drop, 6s default auto-dismiss, hover pauses + re-arms.
  - `MWNotificationStackController.swift` — single `NonActivatingPanel` (level `.statusBar`, `.canJoinAllSpaces`, `becomesKey=false`), positioned top-right with 12pt edge inset.
- `NotificationService.swift` rewritten — every `post*` method routes through `MWNotificationStack.shared.push(...)`. `import UserNotifications` + UN delegate dropped.
- `postMeetingRecap` removed entirely — `MeetingRecapWindow` is the canonical surface for finished meetings.
- `WeeklyPatternDetector.postRecapNotification` / `postQuietWeekNotification` rewritten to push `.advice` cards.
- `Views/Proactive/` directory deleted — `ProactiveChipWindow` and `ProactiveChipView` removed. `.proactivePrefillChat` Notification.Name moved to `MWNotificationCard.swift`.

### Dashboard — hover popovers on TODAY 4 counters

`Views/Windows/DashboardView.swift:TodayStatsCard` — each of 4 stat cells (CONVOS / MEMORIES / DONE / NEW TASKS) now reveals a native macOS popover on hover with up to 10 lines from today's actual items + "and N more" overflow. Cells with `value == 0` stay inert.

### ChatService — stale calendar-task pollution fix (root cause)

Earlier in session, I shipped a `dueAt > now - 7d` filter as a symptom-fix. After identifying the calendar-task pipeline as the real source, **reverted** the filter: `fetchPendingTasksForQuery` predicate is back to `!isDismissed && !completed && status != staged`. Voice-extracted tasks with past dueAt now correctly surface with `(overdue Nd)` tag from `formatTaskLine`. `PendingTaskBundle` shape changed `[String]` → `[PendingTaskSnippet]` (id + description + dueAt) — no external callers.

### ShrekPillView build break + alpha cleanup

ShrekPillView.swift had been failing compile with `Bundle.module is internal` (collided with `swift-transformers/Hub.module`) plus 5 missing-type-context errors. Fixed via `Bundle(for: Coordinator.self)` (with `Bundle.main` fallback) and explicit type prefixes. Also: `shrek-pill.mov` was declared in Package.swift but NOT copied by `build.sh` — added to build.sh's resource copy block. Multiple attempts at fixing the alpha-channel halo around dancing Shrek (host CALayer isOpaque, AVPlayerLayer pixel format BGRA, TimelineView re-render forcing) all failed because the halo is BAKED into the source `.mov`'s alpha channel — not a rendering artifact. User accepted "оставим так".

### 1.3.1 release pipeline (2026-05-03)

End-to-end release of all the above:

1. `Resources/Info.plist` — bumped `CFBundleShortVersionString` 1.3.0 → 1.3.1, `CFBundleVersion` 5 → 6.
2. **`build.sh` — TSA-flake retry shipped permanently.** First release attempt failed Apple notarization with "signature of the binary is invalid" on Sparkle.framework/Sparkle (both x86_64 + arm64) and outer MetaWhisp binary. Root cause: Apple's TSA endpoint (`timestamp.apple.com`) silently dropped timestamps for some signing operations; `codesign` returned exit 0 anyway; Apple notarization rejected. Fix: every `codesign` call in build.sh now verifies `Timestamp=` in the resulting signature and retries up to 3 times with 8s sleep on missing timestamp. Applied to both `sign_target` (Sparkle nested) and the outer-bundle codesign.
3. `release.sh` re-run after fix — Apple notarization Accepted, stapler validated, Sparkle EdDSA signed.
4. **GitHub Release `v1.3.1` created** at `metawhisp/metawhisp` repo with `MetaWhisp.dmg` as asset (9,801,122 bytes, sha-256 `d7055253...`). Public download URL: `https://github.com/metawhisp/metawhisp/releases/download/v1.3.1/MetaWhisp.dmg`.
5. **Cloudflare Page Rule** created on `metawhisp.com`: pattern `*metawhisp.com/downloads/MetaWhisp.dmg` → 302 → GitHub Release URL. Marketing site untouched. See `specs/RELEASE-PLAYBOOK.md` for full architecture diagram.

### Cloudflare Pages atomic deploy near-disaster

Mid-session: blindly ran `wrangler pages deploy _site --project-name=metawhisp` from local `_site/` (eleventy-built from `src/blog/`). Cloudflare Pages atomic deploy DELETED 6 blog posts (`dictation-for-doctors-hipaa`, `google-stitch-mcp`, `hate-voice-messages`, `microsoft-productivity-apps-mac`, `office-365-productivity-mac`, `private-voice-to-text-mac`) that had been written by an external automation directly to Pages without committing back to `src/blog/`. Recovered via `POST /pages/projects/metawhisp/deployments/{previous_id}/rollback` — instant restore. **Lesson codified in `specs/RELEASE-PLAYBOOK.md` "Pages deploy procedure (DANGEROUS)"** section: never deploy without first wget-mirroring live state.

### NEW DOCS SHIPPED THIS SESSION

- `specs/RELEASE-PLAYBOOK.md` — end-to-end release procedure, token requirements (no values), architecture diagram, lessons learned.
- `specs/ROADMAP.md` — Phase 3-7 future work (voice-everywhere capture, Obsidian as second brain, chat as portal, MCP interop, polish/scale).

### Open / next session

- **Sparkle auto-update for existing 1.3.0 users.** `appcast.xml` still on Cloudflare Pages with old 1.3.0 entry; existing 1.3.0 users won't get auto-update notification until either (a) we move appcast.xml to GitHub Releases too with a Page Rule, or (b) we do a safe Pages deploy (wget mirror first). RELEASE-PLAYBOOK.md documents both paths. (a) is recommended.
- **Page Rule destination is hard-coded to `v1.3.1`.** Needs manual update on each release. Better: change destination to `https://github.com/metawhisp/metawhisp/releases/latest/download/MetaWhisp.dmg` (GitHub auto-resolves). Test first.
- **All compromised tokens to revoke** (appeared in chat logs during release session): 2x GitHub PATs, 4x Cloudflare API tokens (3 + 1 cfut). Listed in chat history, user acknowledged.
- **`MetaWhisp.app` v1.3.1 currently running locally** as PID 21010 (replaced by hot-swap). Working tree has all uncommitted changes including this WAL update.
- **DailySummaryService.tasksCompleted always returns 0** — pre-existing, separate hunt.
- **Auto-complete tasks when their linked calendar event ends** — would close the loop so even voice-extracted "follow up after meeting X" gets cleared.
- **Tasks tab UX**: stale `(overdue Nd)` badge + bulk-cleanup button.

---

**Shipped in session 2026-05-02 (Dashboard popovers + ITER-026 unified notifications + calendar-task root-cause fix):**

### Dashboard — hover popovers on the 4 TODAY counters
- `Views/Windows/DashboardView.swift:TodayStatsCard` — each of the 4 stat cells (CONVOS / MEMORIES / DONE / NEW TASKS) now reveals a native macOS popover on hover with up to 10 lines from today's actual items + "and N more" overflow. Cells with `value == 0` stay inert. Items: conversation calendar/title for CONVOS, content prefix for MEMORIES, taskDescription for DONE/NEW TASKS, sorted by createdAt/completedAt desc.
- `stat()` factored out into a new `StatCell: View` with `@State var isHovered` (popover state can't live inside a `private func`). `StatPopover` helper view renders the bullet list with `MW.caption` rows.

### ITER-026 — unified in-app notification stack (root-cause fix for top-right overlap)
- User report 2026-05-02: two visually different notifications kept overlapping each other in the top-right corner. Investigation: macOS-native `UNUserNotificationCenter` banners (5 callers in `NotificationService.post*`) and the standalone `ProactiveChipWindow` both lived in the same corner without knowing about each other.
- **New unified system** in `Views/Notifications/`:
  - `MWNotification.swift` — single struct + `Kind` enum (`.task | .call | .recordingStopped | .recap | .advice | .proactive`), each kind with its own SF Symbol + accent color. `proactiveItems: [SurfaceItem]?` carried only by `.proactive` cards (multi-row content).
  - `MWNotificationCard.swift` — one Liquid Glass card layout for every kind (`thinMaterial` + specular rim + shadow, 344pt wide, 14pt radius). Header: kind icon + uppercase tracked label + relative time + close (×). Body: title (semibold) + body (3-line) for single-row kinds; `proactiveRow(_:)` repeats for `.proactive`. Tap dispatch executes `SurfaceTapAction` directly (`openChat` posts `proactivePrefillChat`, `openTab` switches sidebar tab).
  - `MWNotificationStack.swift` — `MWNotificationStack.shared` singleton (`@MainActor`, `@Published items`). `push(_)` inserts at index 0 with spring animation; `dismiss(id:)` removes with ease-out; `setHovering(_:id:)` cancels/re-arms per-card auto-fade. Hard cap **4** visible — pushing a 5th drops the oldest (FIFO). Default auto-dismiss **6s**, paused on hover.
  - `MWNotificationStackController.swift` — single `NonActivatingPanel` (level `.statusBar`, `.canJoinAllSpaces`, `becomesKey=false`), positioned top-right with 12pt edge inset. Subscribes to `MWNotificationStack.shared.$items` — panel hides entirely when stack is empty so it never paints invisible chrome or steals clicks.
- **`NotificationService.swift` rewritten** — every `post*` method routes through `MWNotificationStack.shared.push(...)`. UN imports + `UNUserNotificationCenterDelegate` extension dropped. Compatibility shims: `hasPermission` → `true`, `requestPermission()` → `true` (preserved so old callers compile). Rate-limit on `postAdvice` (1/min) and DND-during-meeting on task/advice posts preserved.
- **`postMeetingRecap` removed entirely** — the loudest visual collision was that finished meetings produced BOTH a top-right banner AND a top-center `MeetingRecapWindow` (560×540 structured payload). The window is the canonical surface; banner was redundant. `AppDelegate.fireMeetingRecap` no longer calls into it.
- **`WeeklyPatternDetector.postRecapNotification` / `postQuietWeekNotification` rewritten** — used to call `UNUserNotificationCenter.add` directly. Now push `.advice` cards into the stack via `Task { @MainActor in MWNotificationStack.shared.push(...) }` (the detector is non-isolated). `import UserNotifications` removed.
- **`AppDelegate`** — added `let notificationStackController = MWNotificationStackController()` so the panel host is alive at launch. Removed the `UNUserNotificationCenter.notificationSettings()` permission probe + `import UserNotifications` (no OS permission needed for the in-app stack).
- **`Views/Proactive/` directory deleted** — `ProactiveChipWindow.swift` and `ProactiveChipView.swift` removed. The `.proactivePrefillChat` `Notification.Name` extension that lived inside them is now declared at the bottom of `MWNotificationCard.swift`. Sole caller (`ProactiveContextService`) pushes a `.proactive` `MWNotification` with the items array directly.

### ITER-026 — calendar-event-to-task pipeline removed (root-cause fix for "интервью давным-давно")
- User report 2026-05-02: chat was citing weeks-old interview tasks ("Tech Interview: Person — Marketing manager — Acme"). Earlier in the session I shipped a `dueAt > now - 7d` filter in `ChatService.fetchPendingTasksForQuery` — that masked the symptom. User pushed back: "Борись с причиной, а не со следствием — посмотри как у референса" — and they were right.
- **Root cause located** in `Services/Indexing/CalendarReaderService.swift:scanNow()` — for every upcoming calendar event in a 14-day window, the service bulk-inserted a `TaskItem(taskDescription: shortenTaskDescription(event.title), dueAt: event.startDate, sourceApp: "Calendar")`. Bypassed `TaskExtractor` LLM entirely. Density ~10/day at this user's calendar load → endless rotting noise once events passed because nothing flipped them to `completed`.
- **Reference comparison**: the reference action-item extractor NEVER turns calendar events into tasks. Calendar metadata is passed as **enrichment context** to the transcript-extraction LLM so attendee names land in extracted task descriptions ("Send draft to Mark" vs "Send draft to him"). One-way: voice → LLM → action item, with calendar metadata as side input.
- **Fix:**
  - `CalendarReaderService.scanNow` — bulk task-creation loop deleted (lines 296-321 in the old file). Memory-extraction for recurring patterns (lines 323-331) kept. `lastSummary` now reports `Memories: N · Scanned M events` (no `Tasks:` row). Helpers `fetchRecentTaskSignatures` and `shortenTaskDescription` removed (orphan after the loop).
  - `TaskExtractor.extractFromConversation` — fetches `Conversation.calendarEvent*` fields (populated by ITER-018 `linkConversation`) into a new `CalendarMeetingContext` struct. `buildPrompt(...)` now takes `calendarContext: CalendarMeetingContext?` and prepends a `CALENDAR MEETING CONTEXT:` block (Title / Scheduled / Participants) BEFORE the transcript fragments.
  - `TaskExtractor.systemPrompt` extended with a `CALENDAR MEETING CONTEXT (when present, READ FIRST)` section instructing the LLM to use participant names verbatim, never extract the meeting title itself as a task, and SKIP rather than guess when assignee is ambiguous.
  - `Models/AppSettings.swift` — `+@AppStorage("didMigrateCalendarTasks_iter026") didMigrateCalendarTasks: Bool = false`.
  - `AppDelegate.migrateCalendarTasksOnce()` runs at launch behind that flag. Dismisses every TaskItem with `sourceApp == "Calendar"` AND every orphan looking like calendar-pipe output (`conversationId == nil && dueAt != nil && sourceApp empty/nil`). Voice/meeting-extracted tasks all carry a `conversationId` so they survive. Soft-dismiss only (`isDismissed = true, status = "dismissed"`) — rows preserved for audit.
- **Reverted** the earlier `ChatService.fetchPendingTasksForQuery` `staleCutoff` filter — predicate is back to `!isDismissed && !completed && status != staged && status != dismissed`. Voice tasks with past `dueAt` ("оплатить счёт во вторник, забыл") now correctly surface in chat with the `overdue Nd` tag from `formatTaskLine`. System-prompt bullet trimmed to drop the now-misleading "7-day cutoff" wording.
- **Kept**: `formatTaskLine(_:)` enrichment (dueAt → human suffix), `PendingTaskSnippet` shape (id + description + dueAt) — both still useful and not the symptom-mask.

### Calendar linker — `isAllDay` filter (root-cause fix for "Labor Day Holiday" titles)
- User report 2026-05-02: «вчерашние созвоны называются Labor Day Holiday / invoice». Verified via direct EventKit query (osascript) that `Holidays in Serbia` calendar emits 24h `allday=true` rows for Labor Day (May 1) + Labor Day Holiday (May 2). Score path: `timeOverlapFraction = 1.0` (conv fully inside 24h window) × 0.6 = **0.60** > 0.5 threshold → every conversation matches.
- `Services/Indexing/CalendarReaderService.swift:linkConversation` — added `if ev.isAllDay { return false }` to the candidate filter. Real meetings are never all-day. Confirmed against 9-day calendar dump: only `Holidays in Serbia` events are all-day; every actual meeting is a bounded slot.
- Did **not** add an event-duration cap. Looked at the actual calendar data — every real meeting was ≤2h. A blanket cap would risk excluding legitimate long-form meetings and isn't necessary now that all-day rows are filtered.
- For the «invoice» titles separately: confirmed no `invoice` event exists in the user's calendar over 9 days. That's `StructuredGenerator` LLM output, not a calendar match. Fix below.

### Dual-stream merger — per-utterance `StreamSegment` (root-cause fix for "опять кривая хуйня")
- User report: meeting transcripts read as garbled. Found that `App/AppDelegate.transcribeStreamChunked` was emitting ONE `StreamSegment` per audio CHUNK (5-min granularity) with `startSec=chunkStartSec`, `endSec=chunkEndSec`, ignoring Whisper's per-utterance timings inside `result.segments`.
- Effect on rendered transcript:
  ```
  Me: <full 5 min of user's speech>
  Them: <full 5 min of system audio>
  Me: <next 5 min>
  Them: <next 5 min>
  ```
  i.e. 5-MINUTE BLOCKS of monologue alternating, not real-time interleaving. Looks like garbage even though every word inside the block is correct.
- `App/AppDelegate.transcribeStreamChunked` — now iterates `result.segments` (the WhisperKit / Cloud Whisper engine already populates them). Each Whisper segment becomes one `StreamSegment` with absolute timing = `chunkStartSec + whisperSeg.start`. The mergeStreams() output now interleaves per-utterance:
  ```
  Me: Привет, как дела?         (10s)
  Them: Хорошо, а у тебя?       (13s)
  Me: Тоже. Давай по делу.      (16s)
  Them: Окей, начинаем.         (19s)
  ```
- Fallback: if `result.segments.isEmpty` (some engine doesn't fill them), falls back to old chunk-level segment (rare, but safe).

### Call detection — multi-window scan + no auto-stop debounce (root-cause fix for «созвон обрезался / уведомления нет»)
- User report 2026-05-02: «90% митинга сижу не в окне созвона, по другим вкладкам лажу. Запись обрывается». Root cause in `Services/Screen/ScreenContextService.captureIfChanged`: only the FRONTMOST window was scanned for call patterns. Tab away from Meet → frontmost is now Slack → `currentCall = nil` → 180s `callEndedDebounceTask` → recording auto-stops mid-meeting.
- Two-part fix:
  - **`ScreenContextService.detectCallAcrossAllWindows`** (new static helper) — fast path checks frontmost via the existing `SystemAudioCaptureService.detectCallContext`; slow path enumerates `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`, resolving each window's `pid → bundleID` (cached per tick) and feeding owner+title+bundleID through `detectCallContext`. Returns the first hit. Now a Zoom tab parked behind Slack still keeps the call signal alive.
  - **`AppDelegate.handleCallContext(nil)` rewritten** — removed the 180s `callEnded` auto-stop entirely. User explicit feedback: window-loss alone is NOT a stop signal, audio is. Now `nil` only arms a 60s session-end grace timer that resets `CallSessionMachine` (so a brand-new call with the same app name later isn't suppressed as duplicate). Recording stop is owned exclusively by `MeetingRecorder.armSilenceGuard` (10 min < 0.025 RMS) + `armMaxDurationGuard` (4h cap).

### StructuredGenerator title prompt — reject generic single-noun titles
- User report 2026-05-02: «все вчерашние созвоны называются invoice». Confirmed no `invoice` calendar event exists — this is the LLM titler hallucinating a single common keyword from transcripts.
- `Services/Intelligence/StructuredGenerator.systemPrompt` extended with a HARD-FORBIDDEN block under the TITLE section:
  - Rejects single-noun generics: `"Invoice", "Meeting", "Sync", "Call", "Discussion", "Standup", "Talk", "Update"`.
  - Rejects category words: `"Work", "Project", "Business", "Marketing", "Sales"`.
  - Requires ≥3 informative words OR a proper noun (project / person / product) + a verb-or-action noun.
  - Even when "invoice" IS the dominant word, the title must specify WHICH invoicing topic (Stripe webhook bug, Q2 invoicing pipeline, dispute with vendor X). A bare `"Invoice"` tells the user nothing.

### Bonus — fixed pre-existing ShrekPillView build break
- `Views/Components/ShrekPillView.swift` was failing compile with `Bundle.module is internal` (collided with `swift-transformers/Hub.module`) plus 5 missing-type-context errors on `.resizeAspect / .none / .layerWidth/HeightSizable`. Anchored bundle via `Bundle(for: Coordinator.self)` (with `Bundle.main` fallback) and added explicit type prefixes (`AVPlayer.ActionAtItemEnd.none`, `AVLayerVideoGravity.resizeAspect`, `CAAutoresizingMask.*`). `swift build` clean after the fix — the user requested this as part of the same PR ("и одновременно туда шрека добавить").

### Build status
- `swift build` — **clean, 0 errors** at session end.
- `swift test` — not run; user wanted to sleep. Should run on next session before pushing.

### Open / next session
- DailySummaryService.tasksCompleted always returns 0 — same as before, separate hunt.
- Auto-complete tasks when their linked calendar event ends — would close the loop so even voice-extracted "follow up after meeting X" gets cleared instead of waiting for user's manual dismiss.
- Tasks tab: stale `(overdue Nd)` badge + bulk-cleanup button (still useful even with the fix; voice tasks can also rot if user never dismisses).
- `swift test` to confirm no test regressions before push (pair-locked Karpathy + TDD per project memory).
- Live smoke test of the full flow per `specs/SMOKE-TEST.md` — especially M1 (call detected → MWNotificationStack card top-right, no UN banner) and M5 (meeting recap window only, no parallel banner).

---

**Shipped in session 2026-04-30 / 2026-05-01 (huge marathon — root-cause fixes + UX polish + voice/meeting reliability):**

PIDs walked: 27515 → 29604 → 32180 → 36834 → 37195 → 39404 → **47365** (current).

### Phase B transcription — pseudo-diarization
- `Services/Intelligence/DualStreamMerger.swift` (NEW) — pure helper. `Speaker { .me, .them }` + `StreamSegment(text, startSec, endSec, speaker)` + `mergeStreams(mic:system:)` (sort by startSec) + `renderTranscript(_:)` (collapses consecutive same-speaker into single `Me:` / `Them:` line). 4 RED→GREEN tests in `Tests/MetaWhispTests/Services/Intelligence/DualStreamMergerTests.swift`.
- `MeetingRecorder.stop()` returns `(mic: [Float], system: [Float])` raw, not the previous `Self.mix(...)` pre-summed buffer. mic and system never combined → the "AYA Google" cross-channel mix-in is physically impossible.
- `App/AppDelegate.swift` `transcribeMeetingDualStream(mic:system:engine:)` replaces `transcribeMeetingChunked` — runs `transcribeStreamChunked` per channel (Phase A's silence-cuts + VAD trim preserved per-stream), produces labeled `[StreamSegment]`, `DualStreamMerger.mergeStreams` + `renderTranscript`. Sequential (engine.transcribe is shared, not parallel-safe). Cost ~2× the single-mix path — accepted.
- `MeetingRecorder.mix` static helper retained for `assembleMeetingTranscriptFromLive` tail (live-reuse path — single-pass on ≤30s tail, mix-in not material).

### Voice/meeting mic instance separation (root-cause fix for 3 cascading bugs)
- `App/AppDelegate.swift:25-31` — `meetingMic = AudioRecordingService()` is now a SEPARATE instance from `recorder` (top-level dictation/voice question). Old: `MeetingRecorder(mic: recorder, …)` — both code paths shared one AVAudioEngine. New: `MeetingRecorder(mic: meetingMic, …)` — each owns its own engine.
- Fixed three cascading bugs at the source: (a) voice question received the WHOLE meeting buffer (15+ min, ~950s of mic audio) because `recorder.start()` early-returned on `isRecording=true` and never cleared `samples`; (b) `recorder.stop()` killed the AVAudioEngine that the meeting mic stream depended on, so the rest of the meeting captured 0 mic samples; (c) MeetingCoach repeatedly emitted "Turn on microphone" advice because the channel was literally silent post-voice-question.

### Voice popup multi-turn boundary (chat history scope for voice path)
- `Services/UI/VoiceQuestionState.swift` — `+voiceSessionStartedAt: Date?`. Set on first `startListening()` of a session; subsequent listens within the open popup keep the same anchor (multi-turn). Cleared in `dismiss()` (Esc / auto-after-answered / X) → next `⌘ long-press` opens with `nil` → fresh.
- `Services/Intelligence/ChatService.swift` — `+fetchVoiceSessionHistory(limit:)`: fetches `ChatMessage` rows where `createdAt >= anchor`. `send(_, source:)` picks `fetchVoiceSessionHistory` for `.voice` and the full `fetchChatHistory` for `.typed`. Voice popup gets multi-turn within session, typed chat keeps full history. Old voice popup sessions don't bleed into new ones.

### Voice question screen-aware (live OCR per question)
- `Services/Intelligence/ChatService.swift:80-95` — for `source == .voice`, `await screenContext.captureNow()` BEFORE building user prompt (~200-500ms ScreenCaptureKit + Vision OCR). Result threaded as `currentScreen: ScreenContextSnapshot?` into `buildUserPrompt`.
- New `<current_screen>` block prepended to user prompt with `app: …`, `window: …`, `ocr_text: <prefix(4000)>`. System prompt updated to instruct LLM to treat this as primary source for "what's on my screen?" / "fill this form" / "translate this UI" — distinct from historical `<recent_screen_activity>` (24h cache).

### Tool-call XML strip + drift recovery (Pro path)
- `Services/Intelligence/ChatService.swift:stripToolCallXML(_:)` — shared helper covering canonical `<tool_call>{...}</tool_call>` AND drift `<toolName>{...}</toolName>` patterns (Cerebras/Qwen drift). Applied to `runAgenticLoop` no-tool-call exit, post-loop final aiText, and non-Pro path.
- `runAgenticLoop` recovery: when `resp.toolCall == nil` but `txt` contains drift-format XML, parse via `ChatToolExecutor.parseToolCall` and continue the loop as if it were a native call. Stops raw `<searchMemories>{…}</searchMemories>` from leaking to the chat as METACHAT response.

### Voice popup hang on short/silent long-press
- `Services/System/TranscriptionCoordinator.swift:abortVoiceQuestionIfActive(reason:)` — pair-resets `voiceQuestionMode = false` AND `VoiceQuestionState.shared.failed(reason)`. Called from every early-return path in `stopAndTranscribe` + `transcribe`: too-short, too-quiet, engine-not-ready, empty result, hallucination filters, transcribe catch. Fixes the bug: hold ⌘ for 200ms with no audio → popup stuck in `.listening`/`.transcribing`; subsequent short-tap dictation routed to MetaChat instead of clipboard.

### CallSession state machine (1 call = 1 notify + DND)
- `Services/System/CallSession.swift` (NEW) — `struct CallSession { name, didAnnounce, userDeclinedRecording }`, `enum CallSessionDecision { fireNotify(name:armCountdown:), suppressDuplicate, suppressBecauseDeclined }`. `CallSessionMachine.onDetect / onUserStopped / onSessionEnd` are pure state transitions. 7 RED→GREEN tests in `CallSessionMachineTests.swift`.
- `App/AppDelegate.handleCallContext` rewritten around the machine: same call name in same session → suppress. User manually stops mid-call → flag `userDeclinedRecording`, no auto-restart for the rest of session. 180s end-of-session debounce calls `onSessionEnd` → next detect of same name = brand-new session.
- DND during recording: `NotificationService.postNewTask` + `postAdvice` early-return when `meetingRecorder.isRecording`. Tasks/advice still extracted, just don't ping; they show up in the post-meeting recap. **MetaWhisp-only DND** — never touches macOS Focus / system Do-Not-Disturb.
- `postCallDetected` now uses deterministic identifier `com.metawhisp.call.<name.lowercased()>` for native macOS dedup belt-and-suspenders (replaces UUID-per-call which stacked banners).
- `meetingSilenceStopMinutes` default 1 → 10 (calls have legit long quiet stretches; premature stops cost more than late ones).

### dur=0 fix (recap popup duration gate)
- `Services/Intelligence/ConversationGrouper.swift:assign(historyItem:callContext:meetingDurationSec:)` — new param. For fresh meeting: `startedAt = createdAt - duration`, `finishedAt = createdAt`, so `finishedAt - startedAt = duration` (was both = `Date()`). Recap popup's `durationSec >= 60` guard now sees real values.
- `App/AppDelegate.persistMeetingTranscript` passes `meetingDurationSec: duration`.

### Calendar title priority + link-before-LLM (root-cause fix for "Quick note (empty)")
- `Services/Intelligence/StructuredGenerator.swift:generate` — `await calendarReader?.linkConversation(conversationId)` runs synchronously BEFORE the LLM call (was fire-and-forget after, racing the recap popup). After link, refresh `conv.calendarEvent*` fields from the new ctx.
- Display: `displayTitle(for:)` in `ConversationsView` + same logic in `MainSettingsView`/`fireMeetingRecap` — `calendarEventTitle ?? title`. Library list and recap popup show calendar event name when matched.
- `MeetingRecapView` removed redundant calendar chip below title (title itself IS the calendar name now).

### StructuredGenerator transcript race — SwiftData cross-context fix
- Initial fix: `static func fetchHistoryItems(conversationId:in:)` — replaced flaky `#Predicate { $0.conversationId == conversationId }` over Optional UUID with broad fetch + in-memory filter (3 retroactive RED tests).
- Still hit "Quick note (empty)" placeholders in production — race was in `ModelContext` not seeing just-committed rows, not in the predicate. Real fix: `scheduleOnClose(for:knownTranscript:)` accepts the transcript at the call site (`assign()` already has it in memory), passes through to `generate(conversationId:knownTranscript:)`. New context skipped entirely on the meeting path. Backfill / manual paths fall back to DB fetch.
- `assign()` returns of `activeOrNewConversation` widened to `(Conversation, isFreshMeeting: Bool)` — caller fires `scheduleOnClose` with the in-memory transcript only on fresh-meeting path.

### Recap popup — render the 5 missing structured sections
- `Services/Intelligence/MeetingRecapState.swift` — `Payload` gained `participants: [String]`, `decisions: [String]`, `nextSteps: [String]`. Data was always saved by StructuredGenerator (ITER-021 `participantsJSON` / `decisionsJSON` / `nextStepsJSON`) but recap UI only rendered ABOUT — leaving huge empty space and no answer to "с кем созвон / о чём договорились / что дальше".
- `App/AppDelegate.fireMeetingRecap` — decodes the JSON arrays via new `decodeStringArray(_:)` helper. Participants prefer `calendarAttendeesJSON` (objective EKEvent attendees) when non-empty, else fall back to LLM-extracted `participantsJSON`.
- `Views/MeetingRecap/MeetingRecapView` — added `WITH (N)`, `DECISIONS (N)`, `NEXT STEPS (N)` sections + `bulletList(_:)` helper. ScrollView max height 320 → 380. Empty sections hidden (no visual noise when not generated). Render order: ABOUT → WITH → DECISIONS → ACTION ITEMS → NEXT STEPS → MEMORIES.

### Dashboard real-time + resize-lag fix
- `Views/Windows/DashboardView.swift:TodayStatsCard` — 4 TODAY counters now compute live from `Conversation` / `UserMemory` / `TaskItem` `@Query`s + in-memory filter to today. Last-7-day chart same source. Was depending on `DailySummary.date == today` existing — that record only generates at the user's scheduled hour (default 22:00) or via manual GENERATE NOW. Symptom (2026-05-01 user report): "уже несколько дней по нулям" while the user had real activity (17 conv / 4 mem / 20 tasks today). DailySummary still owns the 4 LLM-narrative subsections (learned/decided/shipped/energy/headline) — those CAN'T be real-time.
- Same file: outer `GeometryReader { geo in … }` replaced by `.onGeometryChange(for: CGFloat.self) … action: { width in if newWide != isWide { isWide = newWide } … }`. `isWide`/`isFullscreen` are `@State` Bool, flip ONLY on threshold cross (1240, 720). Per-pixel resize no longer invalidates the whole subtree. User report: "пиздец как тормозит на ресайзе".

### Clipboard reliability — verified write + retry (root-cause fix for "ничего не вставляется ⌘V")
- `Services/System/TextInsertionService.swift:writeToClipboardVerified(_:attempts:)` — calls `clearContents()` + `setString` and CHECKS the bool return, then 5ms `usleep` + read-back to confirm. Retries up to 3 times when either fails. Catches the race where another process (Universal Clipboard sync, Maccy/Paste/Raycast) clears or overwrites between OUR `clearContents()` and `setString`.
- New `enum InsertOutcome { autoPasted, clipboardOnly, clipboardFailed }` returned from `insertResult(text:)`. Caller `TranscriptionCoordinator.transcribe` distinguishes:
  - `.autoPasted` → silent
  - `.clipboardOnly` → "Copied to clipboard — press ⌘V"
  - `.clipboardFailed` → "Clipboard write failed — recover from Library → History"
- 4 RED→GREEN tests in `TextInsertionClipboardTests.swift` (write/empty/unicode/sequential).

### Dictation hallucination filter — recovery via clipboard + lastResult
- `containsExcessivePhraseRepetition` moved from `isAlwaysHallucination` (always-discard) to `isHallucination` (silence-only, RMS<0.003). Real dictations with brief mid-speech pauses (Whisper hallucinates `"ну и комьюнити, ну и комьюнити, …"` to fill silence) no longer get the WHOLE result discarded — repetition is filtered only when the whole audio was actually quiet.
- `TranscriptionCoordinator.transcribe` filter discard paths now: (a) `Self.saveSuspectToClipboard(trimmed)` puts text on clipboard, (b) `lastResult = result` so popover shows preview, (c) `lastError` flags red banner with recovery hint. Previous version silently lost 30-60s of speech to false-positive filter hits.
- Empty-result branch surfaces `lastError = "Transcription returned empty — try again louder/closer."` (was silent return).
- `saveSamplesAsWav(_:)` — on Cloud Whisper / on-device transcribe throw, raw 16kHz Float32 samples written as WAV to `~/Library/Application Support/MetaWhisp/Recovery/recording-YYYY-MM-DD-HH-mm-ss.wav`. Path in `lastError`. 3 RED→GREEN tests in `TranscriptionCoordinatorRecoveryTests.swift`.

### Default window size + autosave
- `Views/Windows/MainWindowController.swift` — `contentRect` 700×500 → 1440×1000, `minSize` 500×400 → 900×600, `+window.setFrameAutosaveName("MetaWhispMainWindow")`. First open is large; user resize sticks across launches.

### MenuBar Variant A — Liquid Glass redesign
- `Views/MenuBar/MenuBarView.swift` — full chrome rewrite per `mockups/voice-and-hotkeys.html` Variant A spec. Status `PulsingDot` (idle = green pulse 1.6s, recording = red pulse 1.0s, processing/translating = solid blue/accent). RECORD/STOP pills are `Capsule` not `Rectangle`. Action grid: accent-colored SF Symbol icons + tracked label + `Keycap` hotkey badge, `frame(height: 44)` (was fixed 48). Footer: `HoverButtonStyle` with hover-tinted bg, transparent base, padding 12×6. Top specular rim via top-down `LinearGradient` overlay + `.blendMode(.plusLighter)`. Width kept 300pt (compact pass after first iteration was visually too wide/tall).

### FloatingVoiceView — Liquid Glass redesign
- Full rewrite of voice popup in same Liquid Glass system. 4-phase chrome: header tinted by `MW.stateColor` (red listening / blue transcribing+thinking / green answered / red error). `FVPulsingDot` for state indicator. Q/A cards with avatar (👤 / ✨) + uppercase tracked label + body text, hairline dividers. STOP capsule + Esc Keycap when speaking. Width 380, ultraThinMaterial backdrop, specular rim, double shadow stack. Mockup `mockups/voice-and-hotkeys.html`.

### Settings — Hotkey panel extended + Microphone picker
- `Views/Windows/MainSettingsView.swift:hotkeySection` — 2 → 4 rows. Each: action name + description + TAP/HOLD badge + Keycap(s). New rows: VOICE QUESTION (HOLD ⌘ ≥0.5s), AUTO-TRANSLATE (input) (HOLD ⌥ ≥1.5s). HOLD badges in `MW.accent` color, TAP badges in muted.
- New MICROPHONE section in Dictation tab (between Model and Language). Picker with "System default" + every input device returned by `AudioInputCatalog.availableInputDevices()` (CoreAudio enumerator). Refresh ↻ button re-pulls list. Selection persists in `AppSettings.preferredInputDeviceUID`.
- `Services/Audio/AudioInputDevice.swift` (NEW) — `struct AudioInputDevice(uid, name, deviceID)` + `enum AudioInputCatalog { availableInputDevices(), device(forUID:), setInputDevice(_:on:) }`. CoreAudio HAL — `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)` for enumeration, `kAudioOutputUnitProperty_CurrentDevice` set on `engine.inputNode.audioUnit` to bind. Default device put first in list. Unplugged devices → silent fallback to system default.
- `Services/Audio/AudioRecordingService.start()` applies preferred device BEFORE `installTap` (switching after a tap is undefined).

### TDD discipline catch-up (retroactive coverage)
- `Tests/MetaWhispTests/Services/Intelligence/StructuredGeneratorFetchTests.swift` (3 cases) — in-memory filter for the fetch helper.
- `Tests/MetaWhispTests/Services/System/TranscriptionCoordinatorRecoveryTests.swift` (3 cases) — `saveSamplesAsWav` empty/valid/path-in-recovery-folder.
- `Tests/MetaWhispTests/Services/System/TextInsertionClipboardTests.swift` (4 cases) — clipboard verified write happy-path/empty/unicode/sequential.
- `Tests/MetaWhispTests/Services/System/CallSessionMachineTests.swift` (7 cases) — full state-machine coverage.
- `Tests/MetaWhispTests/Services/Intelligence/DualStreamMergerTests.swift` (4 cases) — pure merge/render.
- `specs/SMOKE-TEST.md` (NEW) — 18 critical user stories, run before every `swift build` + `bash hot-swap.sh`. 5 categories (Dictation / Voice / Meeting / Dashboard / Settings / MetaChat) + diagnostic playbook per failure mode.

### Memories updated
- `feedback_never_build_without_ask.md` (NEW) — `swift build` / `swift test` / `bash hot-swap.sh` / `bash build.sh` fire ONLY on explicit user ask. Cold builds 5-15 min were burning 90% of session time. Edits-on-disk-only is the default state.

### Open / next session
- DailySummaryService.tasksCompleted always returns 0 — not picking up `TaskItem.completedAt`. Separate root-cause hunt.
- ScreenContext call detection latency — currently 30s polling tick. Enhancement: subscribe to `NSWorkspace.didActivateApplicationNotification` for instant detect on app focus change.
- ProjectAggregator clutter — 52 alias rows of which 46 are 1-conv noise (Голосок/VoiceSnack dup, Island/Island Expand/Island Expend typos, Atomic-zoo). Plan: threshold ≥2 conv before showing in Projects view + delete-button per row.
- Phase B chunk overlap (35s with 5s overlap, dedupe at merge boundary) — original Phase B plan, deprioritized while addressing user's bigger pain points. Revisit.
- Phase C Deepgram streaming WebSocket — still budget-pending.

**Shipped in session 2026-04-28/29 (massive marathon — 1.3.0 release + transcription quality Phase A):**

### 1.3.0 release (notarized + on metawhisp.com)
- Bumped `Info.plist` 1.2.0→1.3.0 / 4→5
- DMG 9.26MB (`uHYXZ0t...DuDg==`), notarized + stapled, deployed via Cloudflare Pages to `metawhisp.com/downloads/MetaWhisp.dmg` + `appcast.xml`. Existing 1.2.0 users will auto-update via Sparkle.
- **Notarization is now MANDATORY in `release.sh`** (memory `project_distribution.md`). Required fixes to ship: (1) `cp -R Sparkle.framework` → `ditto` (cp was breaking framework symlinks), (2) Sparkle moved `Contents/MacOS/Sparkle.framework` → `Contents/Frameworks/Sparkle.framework` (Apple notary rejected ambiguous bundle), (3) added `install_name_tool -add_rpath @executable_path/../Frameworks` to main exec, (4) `--timestamp` flag on every codesign call (Apple requires).

### Major features delivered in 1.3.0
- **Meeting Copilot Overlay** — floating panel during meetings with live LLM suggestions. 5-level depth scale prompt (L1 platitudes banned, L5 cross-meeting connections preferred). Long-context: ALL partials + rolling LLM-summary every 4 ticks, plus UserMemory injection by `subject` substring match. Files: `Services/Intelligence/MeetingCoachService.swift`, `MeetingCoachState.swift`, `Views/MeetingCoach/*`.
- **Per-meeting Recap popup** — floating card 8 sec after meeting stop with title + emoji + overview + checkable action items + memories + Copy + Open in Library + Dismiss. UNIFIED guard blocks BOTH this popup and macOS recap notification when: duration < 60s OR (fallback title "Quick note"/"Meeting" + no real content). Files: `Services/Intelligence/MeetingRecapState.swift`, `Views/MeetingRecap/*`, `App/AppDelegate.fireMeetingRecap`.
- **About Me view** — Library → Conversations header has "About me" button (replaced the redundant `total` counter); opens sheet with sections (Projects / Preferences / Decisions / Facts) sourced from non-dismissed UserMemory. EXCLUDES `kind="person"` (those are about other humans). `UserProfileService.buildSections` is pure-tested. Files: `Services/Intelligence/UserProfileService.swift`, `Views/Windows/AboutMeView.swift`.
- **Obsidian outbound sync** — append-only `<vault>/MetaWhisp/Journal.md` for new memories every 12h, plus per-meeting `<vault>/MetaWhisp/Meetings/YYYY-MM-DD · title.md` with summary/transcript/actions/memories at conversation close. EKEvent.notes patched with `obsidian://open?...` link when meeting matched a calendar event. Settings → "Obsidian Sync" section with vault picker + SYNC NOW. Files: `Services/Indexing/ObsidianSyncService.swift`, `MeetingObsidianWriter.swift`.
- **Structured memory fields** — `UserMemory` has `kind` ("person"/"project"/"decision"/"preference"/"fact") + `subject` + `characterization`. MemoryExtractor prompt asks for these. ChatService renders `PERSON · Sam Smith — community partner` as clean lines in `<user_facts>` block, replacing noisy quoting of raw transcripts.
- **Anti-hallucination prompt rule** in ChatService: never quote suspicious ASR fragments verbatim, paraphrase or say "mentioned in N meetings, no clean details". Plus `containsExcessivePhraseRepetition` detector in `TranscriptionCoordinator.isAlwaysHallucination` — catches Whisper repetition-loop hallucinations (3-gram ≥3×, 2-gram ≥4×, single word ≥5× consecutive).
- **Tool-XML drift fix** in MetaChat: `ChatToolExecutor.parseToolCall` now tolerates `<searchTasks>{...}</searchTasks>` drift format (Cerebras/Qwen sometimes emits this instead of canonical `<tool_call>`). Strip-regex on display text covers both formats.

### TDD infrastructure (shipped 2026-04-29)
- `Package.swift` test target `MetaWhispTests`. `Tests/MetaWhispTests/` with `SmokeTests.swift` (`MeetingRecorder.mix`, `containsExcessivePhraseRepetition`) + `Services/Intelligence/UserProfileServiceTests.swift` (6 tests). `swift test` cold ~5-7 min, incremental ~30 sec.
- `specs/TDD.md` — protocol document. `specs/BOOT.md` updated to require reading TDD.md alongside KARPATHY.md at session start.
- Memory `feedback_tdd_karpathy.md` — pair-locked, with HARD BAN (added 2026-04-29): writing GREEN production code before RED test exists is forbidden. Every code task on TodoWrite splits into TWO todos: `[RED]` then `[GREEN]`. User has authority to interrupt with «тест написан до этого?»
- **TDD violation in Phase A** acknowledged honestly — split-chunks/trim-silence helpers got GREEN-first. Retro tests added in `Tests/MetaWhispTests/App/AppDelegateAudioChunkingTests.swift` (8 cases). Going forward: Phase B/C strictly TDD.

### Zoom/Teams strict-detect REVERTED (2026-04-29 late)
- Phase A's title-required detection for Zoom/Teams was missing real calls (titles like "User's Personal Meeting Room", "Waiting for host" don't contain "Zoom Meeting"). User reported missing calls multiple times.
- Reverted: Zoom (`us.zoom.xos`) + Teams (`com.microsoft.teams[2]`) moved BACK to `alwaysCallBundleIDs` — bundle match alone fires detection.
- Slack (`com.tinyspeck.slackmacgap`) + Discord (`com.discord.Discord`) STAYED in `dualModeCallBundleIDs` (require title indicator: "Huddle" / "Voice Connected").
- Trade-off acknowledged: clicking idle Zoom Workplace home triggers a 5-sec countdown. User can dismiss. Better than missing real calls.
- TESTS WRITTEN FIRST THIS TIME — `Tests/MetaWhispTests/Services/Audio/CallContextDetectionTests.swift` covers 11 cases including the Zoom-anyTitle behavior.
- **Currently running:** PID 75318 (debug binary in `/Applications/MetaWhisp.app`, signed with Developer ID).

### Phase A — transcription quality (just shipped 2026-04-29)
PID 43564 was Phase A first ship. PID 75318 = Phase A + Zoom revert.
Items addressed from 7-point reference-parity gap:
- **Lid-bounce conversation merge** — `ConversationGrouper` learned to RESUME a meeting that closed <10 min ago for the same `callContext` (set on auto-start path). Schema +`Conversation.callContext: String?`. Fixes user's "5 одинаковых митингов в Tasks при крышке lid".
- **callEnded debounce 60s → 180s** — covers bathroom break / lid bounce / network blip. Per `App/AppDelegate.handleCallContext` else-branch.
- **#4 Smart silence-boundary chunk cuts** in `transcribeMeetingChunked`: searches ±15 sec around target for the quietest 500ms window, cuts there. Lands cuts on natural pauses, not mid-word. Pure-tested.
- **#7 VAD edge trim** per chunk: strips leading/trailing silence (RMS<0.005 over 100ms windows). Less material for Whisper to hallucinate over. Pure-tested.
- **#5 smart_format** — Groq Whisper Large V3 Turbo via `verbose_json` already returns punctuation. No code change needed.
- **Strict Zoom/Teams/Slack/Discord detection** — `dualModeCallBundleIDs` now requires title contains call indicator (e.g. "Zoom Meeting", "Huddle", "Voice Connected"). Just clicking Zoom tab without an active call no longer triggers "Recording in 5s".

### Hot-swap signing (shipped 2026-04-28)
- `bash hot-swap.sh` is the canonical fast-path: build debug → cp into `~/Applications/MetaWhisp.app` → install_name_tool rpath → ditto into `/Applications/MetaWhisp.app` (rm + ditto pair gets past TCC) → re-sign outer with Developer ID Application identity (NOT ad-hoc — that resets TCC mic/screen/calendar grants every launch). Memory `feedback_hot_swap_signing.md`.

### Open / next session
- **Phase B (transcription)** — chunk overlap (35s with 5s overlap, dedupe at merge) + parallel mic/system streams (pseudo-diarize). Strictly TDD this time. ~3-4h.
- **Phase C (transcription)** — Deepgram streaming WebSocket (no chunks at all). Requires direct Deepgram account (~$0.0043/min) — budget decision pending. ~6-8h.
- **MeetingCoach 3-stage pipeline** (Gate → Generate → Critic) per the reference `proactive_notification.py` — would dramatically reduce L1 platitude noise. Open.
- **Action item push notifications with due_at** (reference FCM pattern) — we have macOS banners with counts only. Open.
- **Goal progress auto-update** in conversation extraction. Open.

**Shipped in session 2026-04-27 (release + meeting transcribe dedup):**
- 1.2.0 release: bumped `Info.plist` 1.1.1→1.2.0 / 3→4, rebuilt + signed via `release.sh`, hit a TCC wall on `hdiutil create -srcfolder` (copy-helper writes into `/Volumes/MetaWhisp` which TCC blocks for non-FDA shells like Cursor / Claude Code). Worked around in `make-dmg-manual.sh` by mounting via `-mountroot /tmp/mw-mount` and `ditto`-ing in instead of `srcfolder`. DMG 11.1MB signed (Sparkle edSig: `WEGL...CCA==`), copied to `website/src/downloads/`, `appcast.xml` 1.2.0 entry added. Awaiting `cd website && npm run deploy`. Memory updated: `project_distribution.md` (TCC mountroot workaround) + `feedback_dont_jump_to_tcc.md` reused.
- Hardcoded `v0.0.1` in `Views/MenuBar/MenuBarView.swift:83` → reads `CFBundleShortVersionString` from Info.plist now (correct version surfaces post-rebuild).
- Cloud quota diagnosis: prod user hit 502 «Transcription failed on all providers». Root cause via `wrangler tail`: Cloudflare Workers AI free tier (10K neurons/day, ~6min audio) exhausted by single user's 61min/day. Deepgram 429s, Groq fallback usually saves but blipped during a tick. Memory `project_distribution.md` will note this; recommendation is Workers Paid ($5/mo).
- ITER-019.1 — **Meeting transcribe dedup (50% cloud cost reduction):**
  - **Symptom:** 30-min meeting → 60min cloud-billed because `LiveMeetingAdvisor` (every-30s partial transcribes for live advice) AND `AppDelegate.stopMeetingRecording` (full chunked re-transcribe) hit the cloud over the SAME audio.
  - **Root cause:** `LiveMeetingAdvisor` discarded its partials (only kept `lastPartial` for UI). On stop the full recording was re-transcribed from scratch — duplicate work.
  - **Fix at owner-layer (advisor owns partials):**
    - `Services/Intelligence/LiveMeetingAdvisor.swift` — `+private var collectedPartials: [String]`. Append after the existing hallucination filters (so "live experience" matches "final transcript"). Reset on `arm()`, NOT `disarm()` (preserves data across the Combine isRecording=false race vs the explicit close path). `disarm()` no longer touches offsets/partials. `+func finalize() -> FinalizationResult?` — cancels timer, sets `isActive=false`, returns `(text, partialCount, micOffsetAtFinalize, sysOffsetAtFinalize)` or nil if advisor was off / nothing collected.
    - `App/AppDelegate.swift` `stopMeetingRecording` restructured: call `liveMeetingAdvisor.finalize()` BEFORE `meetingRecorder.stop()`, snapshot tail samples via `mic.peekSamples(from: live.micOffsetAtFinalize)` while buffers still hot. After `stop()`, in async Task: if `liveResult` non-nil → `assembleMeetingTranscriptFromLive(...)` (single `engine.transcribe` over the ≤30s tail, append to partials text); else → `transcribeMeetingChunked(...)` (existing 5-min chunked path, unchanged behavior). Downstream `persistMeetingTranscript(...)` extracted as shared helper for both paths (history save, conversation grouping, recap, advice).
  - **Cost:** before — 60min cloud per 30min meeting. After — 30min (live) + ≤30s (tail) ≈ 30.5min. ~49% reduction.
  - **Behavior preserved when `liveMeetingAdviceEnabled=false`:** advisor never arms → `finalize()` returns nil → fallback path runs (= current code). Zero behavior change for that flag.
  - **Files touched:** `Services/Intelligence/LiveMeetingAdvisor.swift`, `App/AppDelegate.swift`. Build clean.

**Shipped in session 2026-04-23 (resumed):**
- ITER-010-A — UserMemory enrichment fields (`headline`, `reasoning`, `tagsCSV`); MemoryExtractor prompt + parser updated; ChatService renders memories with headline/reasoning/tags so MetaChat can quote both the fact and why it was stored.
- ITER-010-B — DailySummaryService rebuilt as multi-agent: 4 specialist LLM agents (`learnedAgent` / `decidedAgent` / `shippedAgent` / `energyAgent`) run in parallel via `async let`, then a follow-up `headlineAgent` synthesizes the headline from already-extracted sections. Each agent has its own focused system prompt with anti-cliché rules. Old monolithic `systemPrompt` + `buildPrompt` + `parseResponse` + `ParsedSummary` removed. New `DailySummary` fields `learnedJSON / decidedJSON / shippedJSON / energy` populated; legacy `overview` mirrors `energy` for compat.
- ITER-019 — Realtime advice during meeting recording:
  - **Goal:** advice fired ТОЛЬКО после `MeetingRecorder.stop()` потому что весь chunk транскрибится за один pass на close. На длинных звонках юзер сидит час без помощи. Делаем партиал-транскрибацию каждые 30s + кормим в `AdviceService.triggerOnTranscription(source:"meeting-live")`.
  - **Audio peek API:**
    - `Services/Audio/AudioRecordingService.swift` — `+var currentSampleCount: Int`, `+func peekSamples(from:)` — non-destructive read accumulated buffer.
    - `Services/Audio/SystemAudioCaptureService.swift` — same pair.
    - `stop()` всё ещё возвращает full recording для финальной транскрипции — peek просто читает срез.
  - **New service — `Services/Intelligence/LiveMeetingAdvisor.swift`:**
    - `configure(meetingRecorder:coordinator:adviceService:)`
    - Auto-arm/disarm через Combine subscription на `meetingRecorder.$isRecording` (`removeDuplicates` чтобы не дребезжало).
    - Periodic Task каждые `chunkSeconds` (default 30, clamped 10-120):
      - peek mic+sys samples since last offset
      - mix через `MeetingRecorder.mix(...)` (статический helper)
      - silence guard (`< 0.0008 RMS`) + min 1s samples
      - transcribe через `coordinator.activeEngine` (тот же engine что финальный pass)
      - hallucination filter (`isAlwaysHallucination` + `isHallucination` под низкий RMS)
      - на success — `adviceService.triggerOnTranscription(text, source: "meeting-live")` + advance offsets
      - на fail — НЕ advance offsets (retry на следующем chunk'е)
    - Reset offsets в 0 на disarm — fresh meeting читает с нуля.
    - `@Published var lastPartial`, `lastFireAt`, `isActive` — для UI status pill (можно добавить позже).
  - **Settings — `Models/AppSettings.swift`:**
    - `+liveMeetingAdviceEnabled: Bool = false` — opt-in (стоит ~$0.05 на час meeting'а под Pro proxy).
  - **Settings UI — `Views/Windows/MainSettingsView.swift`:**
    - Новый toggle "Live advice during meeting" в Meeting Recording секции под Recap notifications. Подпись объясняет cost ($0.05/h) + Pro only.
  - **AppDelegate — `App/AppDelegate.swift`:**
    - `+let liveMeetingAdvisor = LiveMeetingAdvisor()`
    - `liveMeetingAdvisor.configure(meetingRecorder:, coordinator:, adviceService:)` сразу после `adviceService.configure(...)`.
  - **Files touched:** `Services/Audio/AudioRecordingService.swift`, `Services/Audio/SystemAudioCaptureService.swift`, `Services/Intelligence/LiveMeetingAdvisor.swift` (NEW), `Models/AppSettings.swift`, `Views/Windows/MainSettingsView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Costs / risks:**
    - 1 transcription call per 30s chunk → 120 calls на час meeting'а. Cloud preferred via active engine.
    - AdviceService уже имеет per-source cooldown (15 min default), so actual advice пишется реже.
    - On-device WhisperKit тоже сработает но медленнее (CPU). Pro path (cloud) рекомендован.
    - Если transcribe failed (network blip) — offset не двигается → следующий chunk re-attempts тот же буфер расширенным.

- ITER-018 — Calendar ↔ Conversation cross-reference:
  - **Goal:** автоматически линковать каждый закрытый Conversation к ближайшему по времени EKEvent (с весами time-overlap + title-similarity). Снапшот event title + time + attendees сохраняется на Conversation. MetaChat получает `calendar:` поле в `<recent_meetings>` блоке и может отвечать «о чём говорили на standup в среду» по имени календарного события (а не auto-сгенерированного title'а).
  - **Data model — `Models/Conversation.swift`:**
    - `+calendarEventId: String?` — `EKEvent.eventIdentifier`.
    - `+calendarEventTitle: String?` — snapshot title.
    - `+calendarEventStartDate: Date?` / `+calendarEventEndDate: Date?` — snapshot range.
    - `+calendarAttendeesJSON: String?` — JSON `[String]` имена участников (или email из URL fallback).
    - All Optional → SwiftData lightweight migration. Verified: 5 new ZCALENDAR* columns в БД после relaunch.
  - **Linker — `Services/Indexing/CalendarReaderService.swift`:**
    - NEW `linkConversation(_ convId: UUID) async` — pre-checks calendar auth, fetches conv, computes window `[startedAt - 5min, finishedAt + 5min]` (or last HistoryItem.createdAt + 5min when finishedAt nil), calls `store.predicateForEvents(...)`, scores each candidate.
    - Score = `0.6 × time-overlap-fraction + 0.4 × title-token-Jaccard` (lowercase tokens length ≥ 3). Threshold 0.5.
    - Snapshot match → save 5 fields to Conversation, log `[Calendar] ✅ linked conv X → event 'Y' (score Z)`.
    - Idempotent: skips if `calendarEventId != nil`.
    - NEW `backfillCalendarLinks() async` — bounded 90 days, 200 max. Walks completed convs without link, attempts each. Called from AppDelegate launch +25s delay (after embeddings + projects backfills).
    - NEW pure helpers `timeOverlapFraction(a:b:)` and `tokenJaccard(_:_:)` — reusable + unit-testable.
  - **Wiring:**
    - `Services/Intelligence/StructuredGenerator.swift` — `+weak var calendarReader: CalendarReaderService?`. After title/overview populate + project resolve → fire `Task { await calendarReader?.linkConversation(conv.id) }`. Non-meeting dictations rarely match — linker exits cheaply.
    - `App/AppDelegate.swift` — wires `structuredGenerator.calendarReader = calendarReader` и спавнит `backfillCalendarLinks()` спустя 25s после launch.
  - **MetaChat surfacing — `Services/Intelligence/ChatService.swift`:**
    - `MeetingSnippet` extended: `+calendarTitle, calendarStart, calendarEnd, calendarAttendees: [String]`.
    - `fetchMeetingsForQuery` decodes `calendarAttendeesJSON` and packs into snippet.
    - `<recent_meetings>` rendering adds `  calendar: <title> (HH:mm-HH:mm) · with: name1, name2` line when matched.
    - System prompt extended in MEETINGS rule: «Calendar lookup — when user references meeting by EVENT NAME, match against `calendar:` line. Prefer citing calendar name over auto-title».
  - **Files touched:** `Models/Conversation.swift`, `Services/Indexing/CalendarReaderService.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Services/Intelligence/ChatService.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Risks:**
    - Threshold 0.5 calibrated empirically — may misss meetings with very generic titles ("Meeting") and few common tokens. Acceptable: time-overlap alone (no title similarity) gets 0.6 × overlap_fraction; full overlap = 0.6 score → just on threshold.
    - Multiple events in same time window → highest score wins. Edge: back-to-back meetings could grab the wrong one, but score formula prefers earlier-overlap when both 100% temporal-fit.
    - Privacy: only event TITLE + attendee NAMES snapshotted, no description/location/notes. Surfaced only inside MetaChat prompts (Pro proxy).

- ITER-034 Pills redesign — 4 stage-aware variants (2026-04-26):
  - **Trigger:** Liquid Glass spec § 8 + design-handoff/pills.jsx + MetaWhisp Pills.html. Deferred from ITER-033 base sweep per user.
  - **`MW.stateColor` mapping remap.** Per spec STAGE_META: idle→ok green, recording→alert red, processing→**info blue** (was orange), postProcessing→**accent** (was blue). Reflects semantic: recording = user action (red), transcribing = waiting on Whisper (blue/info), translating = producing user's voice in another language (their accent). `Helpers/DesignSystem.swift:197-216`.
  - **CapsulePillView.** Full rewrite. Layout: [colored dot] [bars (recording only)] [LABEL]. Dot pulses on recording (1.18 scale). Specular rim — top-down white gradient (0.22 dark / 0.85 light → 0.04/0.25 → 0). Two-shadow stack: raised black shadow + state-coloured 28px halo when active. Replaces prior monoLg label + Rectangle hairline + AngularGradient processing border + processingGlow shadow. Labels uppercase tracked: READY / RECORDING / TRANSCRIBING / TRANSLATING.
  - **IslandAuraPillView.** Collapsed 5 blur layers → 2: outer soft bloom (360x140, blur 28, opacity * 0.6) + inner crisper bloom (250x80, blur 12, opacity * 0.9). Voice drives SCALE (1 → 1.18) not opacity wobble per spec. Status badge moved BELOW notch (offset y = notchH + 6) — never inside Apple's reserved sensor zone. Removed ContourSnakeCanvas + edge stroke layers. Stage colour from `MW.stateColor`.
  - **IslandPillView (Island Expand).** Notch geometry: idle 200×32, expanded notchW+80×notchH+12 (≥260×38 baseline). Aura geometry DERIVED from current notch (auraW = currentW + 140, auraH = currentH * 4 + 40, top centred). Two aura layers (outer blur 28 + inner blur 14) replacing 3 ContourSnakeCanvas/ContourDualSnakeCanvas/ContourVoicePulseCanvas. Content panel BELOW expanded notch (offset = currentH + 6) with bars+label for recording, spinner+label for processing/translating. Expanded radius = MW.rLarge / 2.
  - **GlowStripPillView (Edge Glow).** Voice-reactive on EVERY active stage (not just recording). Strip thickness 4→9px, falloff depth 90→140px, hot-spot width 80→200px — all driven by `voiceLevel = sqrt(audioLevel) * 1.5`. Multi-layer shadow stack (4×) creates the cinematic halo. Two voice-driven hotspots at 15% / 85% width via RadialGradient. Cinematic shimmer sweep (LinearGradient highlight, location -0.3 → 1.3, 2.4s linear repeat, blendMode plusLighter) ALWAYS on when active. Removed prior processing-only shimmer + per-stage hardcoded colors.
  - **Files touched:** `Helpers/DesignSystem.swift`, `Views/Components/PillVariants.swift`.
  - **Build:** all 4 incremental builds clean (2.7-6.5s). Final relaunched signed.
  - **Visual impact:** all 4 variants now use the new state-color mapping (translating becomes accent — when user picks Warm Orange, translating pill is warm orange). Capsule has full state-coloured halo. Aura has cleaner 2-layer bloom + below-notch badge. Expand has below-notch content panel. Edge Glow has continuous shimmer sweep + voice-reactive hotspots.

- ITER-033.1 Dashboard refinements + Library mockup match (2026-04-26):
  - **Trigger:** user feedback after ITER-033 base sweep — (a) cards have unequal heights despite Grid + maxHeight, (b) Library don't match canvas mockup, (c) empty space in TodayCard / Stats card on fullscreen but should NOT split when window compressed.
  - **Equal-height fix.** Root cause: `.frame(maxHeight: .infinity)` applied OUTSIDE the card (on the wrapper) — outer frame stretched but inner card content stayed at natural height, leaving the card's own background shorter than the grid cell. Fix: moved `maxHeight: .infinity` INSIDE each card (TodayCard, TomorrowCard, TodayStatsCard, ScreenActivityCard) so the `.padding().frame(...).mwCard(...)` chain correctly stretches background + content together. `Views/Windows/DashboardView.swift:180/314/460/565` — replace_all on the `.frame(maxWidth: .infinity, alignment: .topLeading) → .mwCard(...)` pattern.
  - **Library mockup match.** `LibraryView.Section` rawValues: UPPERCASE → TitleCase ("CONVERSATIONS" → "Conversations" etc.) per mockup §02. `ConversationsView.Filter` enum same. Page header rebuilt: 28pt bold "Conversations" + monospace "N total" right (was MW.monoLg UPPERCASE). Filter chips replaced with `GlassChipButton` pills (radius 999). **Date-grouped rows now wrap in single rounded glass card per group** with hairline-separated rows inside — was per-row card chrome that read as a stack of plates. Row redesigned: waveform icon + title + LIVE pip (red dot + "LIVE" tracked label when status==inProgress) + category chip + meta + chevron, flush inside group card.
  - **Empty-space refinements (responsive).**
    - **TodayCard** content split into 2 columns when window ≥ `Self.fullscreenThreshold = 1240`: LEARNED + SHIPPED on left, DECIDED on right (headline + energy stay full-width). Below 1240 → dense single-column. New `var isFullscreen: Bool = false` parameter threaded from `DashboardView.body` GeometryReader.
    - **TodayStatsCard** at fullscreen: 2x2 stats grid LEFT + `last7Chart` RIGHT (7-day total-activity bar chart, today bar = `MW.accent`, past = `MW.textDim.opacity(0.55)`, weekday letter labels). Below threshold → stats grid alone. Same `isFullscreen` flag.
    - **ScreenActivityCard** top-4 → top-5 (Grid manages heights so the extra row no longer breaks alignment).
  - **`TodayTomorrowSection` API:** added `isFullscreen: Bool` alongside existing `isWide: Bool`. Both threaded from `DashboardView.body`'s GeometryReader (`isFullscreen = geo.size.width >= 1240`).
  - **Files touched:** `Views/Windows/DashboardView.swift`, `Views/Windows/LibraryView.swift`, `Views/Windows/ConversationsView.swift`.
  - **Build:** all incremental builds clean (3-6s). Final relaunched signed Developer ID bundle.
  - **Visual confirmed by user:** «хорошо стало вроде» — heights match, Library matches mockup, fullscreen fills space without empty zones, narrow windows stay dense.
  - **Deferred (still ITER-034):** PillVariants.swift redesign (4 stage-aware variants).

- ITER-033 Liquid Glass design sweep — Steps 1–5 except Pills (2026-04-26):
  - **Trigger:** design handoff package `design-handoff/MetaWhisp Design Spec.html` + tokens.css. User explicitly deferred PillVariants.swift to a follow-up iteration. Mantra «дырок нет» — equal-height card rows on Dashboard.
  - **Step 1 — DesignSystem.swift tokens.** New tokens: `hairlineColor` (primary.opacity(0.06)), `selectFill` (0.10) / `selectRim` (0.16), `rimInner` (theme-aware specular), `accentSoft` (accent.opacity(0.16)) / `accentRim` (0.45). Status colors → точные spec hex (idle #34C759, processing #FF9F0A, recording/live #FF453A, postProcess #5AC8FA). 5 accent presets: `mono` (default, Color.primary), `warmOrange` (#E08948), `electric`, `mint`, `violet`. `MW.accent` теперь computed dynamic из `AppSettings.shared.accentColor`. `Models/AppSettings.swift:23` — добавлен `@AppStorage("accentColor") String = "mono"`.
  - **Step 2 — MWCardModifier.** Removed legacy single-shadow extension. New `GlassShadowsModifier` применяет per-elevation shadow stack из tokens.css: flat = single, raised = dual (24px halo + 6px tight), hero = dual (60px + 16px). Theme-aware opacity (dark heavier чем light). Specular gradient values (0.30/0.04/0) уже совпадали — без изменений.
  - **Step 3 — `Views/Components/GlassPrimitives.swift` (NEW, ~280 lines).** 7 reusable components: `SidebarItem` (glass-flat selectFill active state), `GlassChipButton` (pill / segmented chip с accent variant), `StatusPill` + `StatusPillState` enum (Ready/Recording/Processing/PostProcessing с per-state fill/rim/label color), `PageHeader<Right: View>` (28pt bold с тrack -0.4 + right slot), `SegmentedGlass<T: Hashable>` (pill segmented control с .thinMaterial active), `AccentSwatch` (для Settings picker — circle + selection ring), `PageWash` (radial+linear gradient, accent-aware warm corner).
  - **Step 5 — MainWindowView.** `heroBackground` linear-only заменён на `PageWash()`. Sidebar: width 200→220, использует `SidebarItem` примитив, brand block теперь `M | MetaWhisp / Liquid Glass` (subtitle), footer стал `v0.0.1 ... ● on-device` с idle-зелёным дотом.
  - **Step 4a — MainSettingsView accent picker.** Добавлен ACCENT row под THEME row: 5 `AccentSwatch` рядом — mono / warmOrange / electric / mint / violet. Tap → `AppSettings.accentColor = preset.id` → live-updates по всему app через `MW.accent` computed.
  - **Step 4b — DashboardView no-holes layout.** Главный фикс: `TodayTomorrowSection` перестроен — 2 stacked HStack (top row TODAY|TOMORROW, bottom STATS|SCREEN), каждая HStack с `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` на siblings + `.fixedSize(vertical: true)` на парент → match heights без растягивания. `TodayStatsCard.stat()` — убраны material/border на каждой ячейке, теперь plain text 36pt + caption (per mockup). `ScreenActivityCard.appRow()` — добавлен accent-tinted progress bar (Capsule fill MW.accent, ширина = `percent / topMax * available`). При accent=mono бар читается как primary text; при warmOrange — оранжевый strip как в mockup.
  - **Step 4c — LibraryView pill chips.** Старые квадратные чипы с `Rectangle().stroke` заменены на `GlassChipButton` (radius 999, ultraThin material inactive / selectFill active).
  - **Step 4d — ProjectsView 2-col grid.** `LazyVGrid` columns: `.adaptive(minimum: 280, maximum: 360)` → fixed 2-column flexible, spacing 14 (per spec § 7).
  - **Step 4e — ChatView accent bubbles.** User bubble: `MW.accentSoft` fill + `MW.accentRim` border. AI bubble: `.ultraThinMaterial` + `MW.border`. Radius 14 для обоих.
  - **Step 4f — DictionaryView tab pills.** Старые black-on-white inverted tabs → Capsule pills с selectFill active / ultraThinMaterial inactive. Counts теперь не в скобках а отдельным monoSm после label.
  - **Pills (PillVariants.swift) — ОТЛОЖЕНЫ** на ITER-034. Per user: «во вторую итерацию мы потом сделаем».
  - **Files touched:** `Models/AppSettings.swift`, `Helpers/DesignSystem.swift`, `Views/Components/GlassPrimitives.swift` (NEW), `Views/Windows/MainWindowView.swift`, `Views/Windows/MainSettingsView.swift`, `Views/Windows/DashboardView.swift`, `Views/Windows/LibraryView.swift`, `Views/Windows/ProjectsView.swift`, `Views/Windows/ChatView.swift`, `Views/Windows/DictionaryView.swift`.
  - **Build:** all 9 incremental builds clean (3-10s each). Final `./build.sh` produced signed Developer ID bundle, installed `~/Applications/MetaWhisp.app`, launched.
  - **Visual impact:** default accent=mono → текущие view-surfaces визуально не изменились (по дизайну). User opt-in coloring через Settings → Accent (5 swatches). Status pills получили точные Apple system hex (вместо `Color.red/.orange/.green`). Dashboard rows match heights → no holes. ScreenActivity bars — accent-tinted (mono = textPrimary stripe, warmOrange = orange). User bubbles в MetaChat — accent-soft.
  - **Deferred:** PillVariants redesign (4 stage-aware variants: Capsule, Island Aura, Island Expand, Edge Glow) — ITER-034 follow-up. Spec § 8.

- ITER-024…032 Prompt-audit re-alignment sweep (2026-04-26):
  - **Trigger:** аудит `specs/audit/PROMPT-AUDIT-2026-04-26.md` показал drift из-за выборочного копирования reference. 9 итераций по Карпати — каждая копирует референс ПОЛНОСТЬЮ, фиксирует 1 gap, build green, переходит дальше.
  - **ITER-024 MemoryExtractor** — восстановлены 8 NEVER-EXTRACT категорий (NEWS / GENERAL KNOWLEDGE / PRODUCT DOCS / CUSTOMER FACTS / INTERNAL METRICS / ORG RESTRUCTURING / COLLEAGUE FACTS WITHOUT RELATIONSHIP / GENERIC RELATIONSHIPS), добавлены IDENTITY RULES (4 правила про family/nicknames/spelling), LOGIC CHECK (sanity на возраст/локации/family), CONSOLIDATION CHECK, WORKFLOW step framing. Banned-language расширен filler-фразами + org-change verbs. `headline` cap 6w → 5w. `Services/Intelligence/MemoryExtractor.swift:149-280`.
  - **ITER-025 TaskExtractor** — добавлено REFERENCE_TIME правило: если `started_at` >7d before `current_time`, anchor due-date math at `current_time` (reprocess path). Surface в user-prompt: started_at + current_time + reference hint. + 4 bullet'а про real-time-exchange exclusion. `Services/Intelligence/TaskExtractor.swift:280-303`.
  - **ITER-026 ChatService** — два новых блока в systemPrompt: `<response_style>` (length budget per question type: voice 1-3 lines, default 2-8, "I don't know" 1-2 max, complex unlimited) + `<critical_accuracy_rules>` (7 banned robotic phrases: "in the logs"/"in your captured calls"/etc., 4 правила про empty results без fabrication). `Services/Intelligence/ChatService.swift:271-323`.
  - **ITER-027 StructuredGenerator** — на каждом из 5 ITER-021 полей (decisions / action_items / participants / key_quotes / next_steps) добавлены 3-5 GOOD + 3-4 BAD примера (RU+EN). LANGUAGE RULE: items в языке транскрипта, имена не транслитерируются. `Services/Intelligence/StructuredGenerator.swift:374-465`.
  - **ITER-028 RealtimeScreenReactor — главный gap fixed.** Добавлен PATTERN-1 USER COMMITMENT detector (30+ сигналов RU+EN: "Sure"/"Will do"/"договорились"/"сделаю"/etc.) — extractит таск который ДРУГОЙ человек попросил, ПОСЛЕ user'ского agreement. Рядом старый PATTERN-2 UNADDRESSED REQUEST. + chat-direction reading rules (right=outgoing/USER, left=incoming/OTHER). + IGNORE OVERVIEW/SIDEBAR rules заменили blanket-skip messengers. + 11 real BAD examples + 7 GOOD examples из production. + SPECIFICITY + FORGETTABILITY checks. `Services/Intelligence/RealtimeScreenReactor.swift:228-330`.
  - **ITER-029 AdviceService** — schema: `AdviceItem.headline: String?` (lightweight migration) + parser/AdviceJSON consumes. Prompt: WORKFLOW (4 steps) + CORE QUESTION в начале standard. Headline guidelines с 5 GOOD + 3 BAD примерами. Coach mode тоже расширен. `Models/AdviceItem.swift:24-41`, `Services/Intelligence/AdviceService.swift:158-340`.
  - **ITER-030 AppleNotesReader** — copy-1:1 reference's `classifierNoise` (6 шумовых паттернов: "Document Documents Papers..." и т.п.) + `isLikelyAttachment` heuristic (SQLite metadata SOLITE/kMDItem/exec, file extensions .png/.jpg/.heic/.pdf/.mov/.mp4/.gif, prefixes cleanshot/image/screenshot, scan+document combo, tiny content). Применяются в `parseAppleScriptOutput` ДО создания payload — Notes-attachments больше не идут в LLM, нет junk memories. `Services/Indexing/AppleNotesReaderService.swift:209-275`.
  - **ITER-031 DailySummary** — schema: `unresolvedQuestionsJSON: String?` + `dayEmoji: String?` (lightweight migration). Pipeline теперь fan-outит 6 параллельных агентов вместо 4: + `unresolvedAgent` (≤3 punchy questions snappy ≤15w, language-matched, "?" ending) + `dayEmojiAgent` (1 Unicode emoji semantic к дню, fallback 🌙). Два новых system-prompts с GOOD/BAD examples. **Conversation_ids back-pointers per item** — отложены на ITER-031b: требуют numbered conversation list в input, output schema change для всех 5 агентов, + UI clickthrough в DashboardView. `Models/DailySummary.swift:39-48`, `Services/Intelligence/DailySummaryService.swift:165-228, 372-422, 736-790`.
  - **ITER-032 ScreenExtractor + RealtimeReactor — title-rejection validator.** Reference TaskAssistant (`TaskAssistant.swift:807-833`) использует tool-loop architecture: vague title → feed rejection back → retry. У нас single-shot JSON, поэтому substitute: `TaskExtractionFilters.validateTaskTitle(_:) -> TitleRejectionReason?` — strict post-LLM gate. Reasons: `.empty` / `.tooShort(wordCount:)` (<4 words) / `.vagueVerb(verb:)` (single-verb starts: investigate/check/look/respond + RU аналоги). Wired в ScreenExtractor + RealtimeScreenReactor сразу после `isGenericNoise` reject. `Services/Intelligence/TaskExtractionFilters.swift:104-155`.
  - **Build:** all 9 iterations compiled clean. Final binary signed Developer ID, installed `~/Applications/MetaWhisp.app`, launched.
  - **Re-audit cadence:** через 2 недели или после крупного refactor — повторить через 2 параллельных агента. Diff vs `specs/audit/PROMPT-AUDIT-2026-04-26.md` baseline покажет новый drift.
  - **Deferred (для отдельной итерации ITER-031b):** conversation_ids back-pointers per DailySummary item + clickthrough в UI.

- ITER-023.2 Calendar CONNECT button actually wires through (2026-04-26):
  - **Symptom (user report):** CONNECT CALENDAR button «doesn't work, probably mock». Click — ничего не происходит, dialog не появляется, события не подтягиваются.
  - **Root causes (двa silent fail):**
    1. `connectCalendar()` дёргал `calendarReader.scanNow()`, а у того guard `hasLLMAccess` (требует `activeAPIKey` или `LicenseService.shared.isPro`) — abort-выход ДО request permission. На race-conditions при загрузке Pro license click уходил в дыру. Plus calendar permission и LLM access — ортогональные concerns, не должны быть связаны.
    2. macOS 14+ `requestFullAccessToEvents()` НЕ показывает dialog повторно если user отказал ранее — молча возвращает false. У нашего юзера TCC Authorization Cache содержал только Microphone (логи `log show --predicate 'process == "MetaWhisp"'`) — никакой попытки calendar request не доходило до TCC.
  - **Fixes — `Views/Windows/DashboardView.swift` (TomorrowCard only):**
    - **`+import AppKit`** — для `NSWorkspace` (deep-link на System Settings).
    - **Decouple from scanNow:** `connectCalendar()` теперь делает `EKEventStore().requestFullAccessToEvents()` напрямую. На grant — пишет `calendarReaderEnabled = true`, bumps `permissionTick`, calls `loadEvents()`, и в фоне `Task.detached { calendarReader.scanNow() }` для tasks/memories — non-blocking. На deny — лог в NSLog без UI freeze.
    - **3-state auth model:** `enum CalendarAuthState { granted, notDetermined, denied }` через `EKEventStore.authorizationStatus(for: .event)`. macOS 14+: `.fullAccess` → granted, `.notDetermined` → notDetermined, `.denied/.restricted/.writeOnly` → denied (writeOnly нам недостаточно — нужно read events). Legacy: `.authorized` → granted и т.п.
    - **Adaptive button:** в connectPrompt button label/icon/action меняются по state:
      - `.notDetermined` → "CONNECT CALENDAR" + `calendar.badge.plus` icon → fires `requestFullAccessToEvents`.
      - `.denied` → "OPEN SETTINGS" + `gear` icon + другой текст ("Calendar access is currently denied. Open System Settings → Privacy & Security → Calendars…") → calls `openCalendarSettings()` → `NSWorkspace.shared.open(URL("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))`. Единственный способ восстановить permission после deny.
    - **`loadEvents()` теперь passive:** только проверяет `EKEventStore.authorizationStatus`, НЕ делает request. Раньше при view appear был второй `requestFullAccessToEvents` параллельно с button click → двойной race-условный dialog. Теперь request живёт ровно в `connectCalendar()`.
  - **Files touched:** `Views/Windows/DashboardView.swift` only (TomorrowCard struct).
  - **Build:** clean (`swift build` 6.40s, 2 pre-existing warnings only).
  - **Verify:**
    - Dashboard → if status `.notDetermined` → CONNECT button → tap → OS dialog «MetaWhisp would like to access your calendar» → grant → events list появляется немедленно (loadEvents отрабатывает после permission).
    - If user отказал раньше → CONNECT превращается в OPEN SETTINGS → tap открывает Privacy & Security → Calendars пейн → user включает MetaWhisp → relaunch app для подцепки grant'а (или Dashboard re-render через permissionTick если grant произошёл при app live).
    - scanNow крутится в фоне после grant → в течение секунд появляются TaskItem rows для upcoming events, memories для recurring patterns (если LLM available — иначе skip pattern memories).
  - **Risks:** scanNow background task при отсутствии LLM access exits silently на guard hasLLMAccess — events/UI всё равно работают, просто не создаются TaskItem mirrors. Acceptable — UI показывает реальные EventKit events, дублирование в TaskItem — bonus feature.

- ITER-023.1 Tomorrow card empty-state fix (2026-04-26):
  - **Triggers (user feedback after first ITER-023 ship):** (a) CONNECT CALENDAR button не появляется хотя реальный EventKit permission не дан — `calendarReaderEnabled` уже стоял `true` от старого тестирования E3, поэтому первая версия пошла в ветку «No events scheduled for tomorrow.» вместо CONNECT prompt. (b) гигантская дыра справа когда CALENDAR пустой и нет tasks tomorrow — карточка коллапсировала до 1 строки рядом с высокой левой колонкой (Today + Stats|Screen sub-row).
  - **Fixes — `Views/Windows/DashboardView.swift` (TomorrowCard only):**
    - **Auth-aware CONNECT:** добавлен computed `calendarPermissionGranted` через `EKEventStore.authorizationStatus(for: .event)`. macOS 14+ → требует `.fullAccess`, legacy → `.authorized`. Новый computed `showsConnectPrompt = !settings.calendarReaderEnabled || !calendarPermissionGranted`. Покрывает кейс «toggle on but never approved system dialog».
    - **`permissionTick: Int` @State** — bumped после `connectCalendar()` и `loadEvents()` чтобы SwiftUI re-render и `calendarPermissionGranted` re-evaluate. `EKEventStore.authorizationStatus` re-reads system state на каждый call, но без state change нет re-render. Tick — minimal trigger.
    - **Beefier CONNECT button:** `calendar.badge.plus` icon + `CONNECT CALENDAR` label с tracking 1.0, padding 14×8, ultraThinMaterial bg + border. Description text вырос (12pt → 13pt, secondary text). Заменил `glassChip` на explicit RoundedRectangle для контроля размера.
    - **PENDING section (anti-hole):** новый `@Query pendingNoDate` — `task.dueAt == nil && !task.completed && !task.isDismissed`, sorted by createdAt desc. Computed `visibleSuggested` filters committed/nil status, prefix(5). Render `pendingSection` под dueSection с label `PENDING · no due date` + bullet list. Главный анти-дыра fix — карточка всегда несёт ценность пока есть open tasks без дат.
    - **Body spacing:** `MW.sp12 → MW.sp16` между секциями для воздуха.
    - **DUE label:** `DUE` → `DUE TOMORROW` для clarity.
  - **Files touched:** `Views/Windows/DashboardView.swift` only (TomorrowCard struct).
  - **Build:** clean (`swift build` 6.47s, 2 pre-existing warnings only). `./build.sh` signed + installed + launched.
  - **Verify:** Dashboard → if EventKit permission not granted → TOMORROW card now shows `· NOT CONNECTED` tag + descriptive copy + sized CONNECT CALENDAR button. Tap → toggles enabled + scanNow + reloads events; if user grants permission → events list (or "No events scheduled" empty state without prompt). PENDING section всегда там пока есть un-dated open tasks → fills card.

- ITER-023 Dashboard Today+Tomorrow split (2026-04-26):
  - **Trigger:** mockup v9 (`mockups/dashboard-v3/v9-stats-leftcol.html`) approved — replace 14-day carousel + standalone Stats|Screen HStack with a 2-column split: LEFT = Today recap + Stats|Screen sub-row, RIGHT = Tomorrow plans (CALENDAR with CONNECT button when reader off, DUE list from TaskItem). 14-day picker removed; single ‹/› arrows in TodayCard navigate while DailySummary data exists.
  - **Plan A — clean replacement:** new split section ЗАМЕНЯЕТ `DailySummaryCarousel` + `HStack(TodayStatsCard, ScreenActivityCard)`. `StatisticsView` (All Time / Today / This Week / Month) внизу нетронут. Title row + statusStrip (READY / RECORD) сверху нетронут.
  - **DashboardView — `Views/Windows/DashboardView.swift`:**
    - `+import EventKit`.
    - Body: removed `DailySummaryCarousel()` and the wide/narrow `HStack(TodayStatsCard, ScreenActivityCard)` branch — replaced both with single call `TodayTomorrowSection(isWide: isWide)`. `StatisticsView()` оставлен под ним.
    - **Removed (dead after carousel kill):** `DailySummaryCarousel` (h-scroll picker + ScrollViewReader), `MiniDayTile` (80×80 square), `DetailCard` (full-width selected-day render). `DailySummaryCard` ITER-009 — оставлен, был уже unused (отдельный cleanup-track).
    - **Added — `TodayTomorrowSection`:** wide → HStack(leftColumn, TomorrowCard) с `.frame(maxWidth: .infinity)` обе → 1:1 ratio; narrow → VStack. `leftColumn` = `VStack(TodayCard(), HStack(TodayStatsCard, ScreenActivityCard))`.
    - **Added — `TodayCard`:** `@State dayOffset: Int = 0`. Header: ‹ button (disabled когда `summaries.last?.date >= selectedDate`) + › button (видна только при `dayOffset < 0`) + dh-label `TODAY / YESTERDAY / N DAYS AGO` + dateLabel `EEE, MMM d` + `GENERATE / REGENERATE` chip. Body — same shape как old DetailCard: title 18pt + LEARNED / DECIDED / SHIPPED / energy. Empty state inline (today вариант references `dailySummaryEnabled`, past — «Tap GENERATE to build one»).
    - **Added — `TomorrowCard`:** queries `TaskItem` predicate `dueAt != nil && dueAt >= tomStart && dueAt < tomEnd` (init-time computed window) → computed `visibleDue` filters `!completed && !isDismissed && status in {committed, nil}`. Calendar section branches on `settings.calendarReaderEnabled`: off → CONNECT prompt + glassChip-styled CONNECT CALENDAR button; on → loads tomorrow's events via local `EKEventStore` (macOS 14+ `requestFullAccessToEvents`, fallback `requestAccess(to:)`), filters cancelled / declined, sorted by startDate. DUE section renders only когда `!visibleDue.isEmpty`. Header chip = `N events` if calendar populated else `N due` if tasks else nothing.
    - **CONNECT CALENDAR action:** flips `AppSettings.shared.calendarReaderEnabled = true` → fires `await AppDelegate.shared?.calendarReader.scanNow()` → reloads local events. Permission prompt comes from EventKit on first scan.
    - **Day rollover bug (known):** `dueTomorrow` predicate captured at init, `events` reloaded via `.task` — if user keeps app open past midnight, "tomorrow" becomes "today" in the predicate. Acceptable for v1; restart fixes.
  - **Files touched:** `Views/Windows/DashboardView.swift` only.
  - **Build:** clean (`swift build` 8.97s, only 2 pre-existing warnings: EmbeddingService dedupThreshold + LicenseService kIOMasterPortDefault). `./build.sh` produced signed Developer ID bundle, installed to `~/Applications/MetaWhisp.app`, launched.
  - **Verify (live):** Dashboard tab → title row READY / RECORD untouched. Below: TODAY card with ‹ arrow (› hidden at offset 0), Stats|Screen sub-row под ним. RIGHT: TOMORROW card — if `calendarReaderEnabled` off → "NOT CONNECTED" tag + CONNECT CALENDAR button. Click → toggles setting, requests EventKit permission, fetches events. StatisticsView (All Time / Today / This Week / Month) внизу как было. ‹ tap → previous-day summary (or empty + GENERATE for past day).

- ITER-022 G_dashboard v2 — Square day-picker + click-driven detail (2026-04-25):
  - **Trigger:** v1 swipe-carousel rejected by user: «карточки должны быть квадратные и переключаться по клику не по свайпу».
  - **Architecture rebuild (v1 → v2):**
    - **v1 was:** ScrollView pageable swipe with `containerRelativeFrame(count: 1)` — full-viewport rectangular cards, snap-to-card via gesture.
    - **v2 is:** `[picker row of square 80×80 mini-tiles]` + `[full-width detail card]`. Click on any tile → `selectedDay` state updates → detail card re-renders. Pure click-driven, zero swipe gestures.
  - **Components:**
    - `DailySummaryCarousel` (renamed but kept name for symmetry) — owns `@State selectedDay`, renders picker row + detail.
    - `MiniDayTile` (NEW) — 80×80 square. Layout: `[EEE day-of-week label] [day number large] [status icon]`. Selected = filled bg + accent border (textPrimary opacity 0.5). Status icons: `checkmark.circle.fill` if has summary, `circle.dotted` if past empty, `moon.zzz` for future.
    - `DetailCard` — full-width below picker. Shows full DailySummary render (headline + LEARNED / DECIDED / SHIPPED / ENERGY) for selected day, OR empty placeholder OR future placeholder. Local `@State localSummary` for instant UI updates after GENERATE.
  - **Picker:** ScrollViewReader + h-scroll, 14 days, `.onAppear { proxy.scrollTo(today, anchor: .center) }` so today centers on first show.
  - **Detail card features:**
    - Header: "TODAY'S SUMMARY / YESTERDAY / N DAYS AGO / TOMORROW" + date + REGENERATE/GENERATE button (or "scheduled HH:MM" for future).
    - Past empty day → "No summary recorded — tap GENERATE to build one from saved data" + clickable button (calls `generateForDate(_:)` retroactively).
    - Future → moon icon + "Tomorrow's recap will appear at HH:MM".
  - **Animation:** click-tile → `withAnimation(.easeInOut(0.15))` selectedDay = day → SwiftUI re-evaluates DetailCard binding.
  - **Files touched:** `Views/Windows/DashboardView.swift` (single file rewrite of carousel namespace).
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Visual confirmed (screenshot):**
    - 14 square tiles SUN 12 → TMRW 26 в горизонтальном ряду.
    - TODAY 25 selected (highlighted: filled bg + bright border).
    - YEST/TODAY/TMRW лейблы корректно различаются.
    - Status icons: ✓ для days with summary, moon for tomorrow.
    - Detail card: full-width "Memory issue and clarity review" + sections + REGENERATE.
    - Stats row + StatisticsView ниже работают.
  - **v1 (swipe) replaced cleanly** — no lingering carousel code.
- ITER-022 G_dashboard — Daily Summary как iOS-style карусель (2026-04-25):
  - **Trigger:** user-reported «главный экран бесполезный, не несёт ценности · криво пространство · хочу карусель Today/Yesterday/Tomorrow с peek краёв соседних дней (как iOS Photos gallery)».
  - **Diagnosis (Karpathy):**
    - 3 distinct problems в одной жалобе: (a) static today-only — нет navigation между днями; (b) right column (280pt) отжимает width у main card; (c) пустой today = visual clutter без value.
    - Owner layer = `DashboardView.swift` (UI) + `DailySummaryService.swift` (data access for arbitrary date).
  - **Architecture changes:**
    - **Service:** `DailySummaryService.generateNow()` теперь thin wrapper над new `generateForDate(_:)`. New `summary(for: Date) -> DailySummary?` public — UI carousel reads per day. `generateForDate` skips future dates (no data possible).
    - **UI:** `DailySummaryCard` (single static) → `DailySummaryCarousel` (full-width pageable horizontal scroll). Right column TodayStats + ScreenActivity moved BELOW carousel as horizontal split (full width reclaimed for the card).
  - **Carousel mechanics:**
    - 14 past days + today + tomorrow placeholder (15 cards total).
    - SwiftUI `ScrollView(.horizontal) { LazyHStack { ForEach … containerRelativeFrame(count: 1) } .scrollTargetLayout() } .scrollTargetBehavior(.viewAligned) .contentMargins(.horizontal, 32, for: .scrollContent) .scrollPosition(id: $currentDay)`.
    - macOS 14+ pageable scroll API — gives snap-to-card with peek of neighbours via 32pt content margin.
    - Default `currentDay = startOfDay(now)` set in @State + `.onAppear` hardening.
  - **DayCard states (per day type):**
    - **today + has summary** → full render (headline + LEARNED / DECIDED / SHIPPED / ENERGY) + REGENERATE button.
    - **today + no summary** → emptyPlaceholder + GENERATE button.
    - **past + has summary** → full render + REGENERATE.
    - **past + no summary** → empty msg "No summary recorded — tap GENERATE" + GENERATE button (works retroactively через `generateForDate(_:)`).
    - **future (tomorrow)** → "moon.zzz" icon + "Tomorrow's recap will appear at HH:MM" placeholder, no button.
  - **Day labels:** TODAY'S SUMMARY / YESTERDAY / N DAYS AGO / TOMORROW + dateLabel (e.g. "Apr 25").
  - **Local state:** `@State var localSummary` per DayCard — UI updates immediately after GENERATE without waiting for @Query refresh.
  - **Files touched:** `Services/Intelligence/DailySummaryService.swift`, `Views/Windows/DashboardView.swift`.
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Visual confirmed (screenshot):**
    - Full-width Today's Summary card with REGENERATE button.
    - Headline "Memory issue and clarity review" + LEARNED 2 items + DECIDED 1 item + ENERGY line "Low activity scattered apps".
    - Edge peek visible на левом краю (yesterday card thin sliver).
    - Stats row под carousel — TODAY (2/2/0/1) + LAST 24H ON SCREEN (Telegram 3h7m / Arc 1h55m / Claude 1h10m / loginwindow / Safari).
    - StatisticsView ниже работает (46 days streak, 90.1k words, 3.6k transcriptions).
  - **Old `DailySummaryCard` остался в файле** as dead code (no callers). Cleanup deferred.
- ITER-022 G5 — WeeklyPatternDetector cross-conversation digest (2026-04-25):
  - **Trigger:** advice audit → reference detects "3 meetings about pricing — same blocker keeps coming up" cross-context patterns. У нас DailySummary даёт single-day recap, StructuredGenerator single-conv. Никто не делает cross-week analysis. **Биguest gap** filled.
  - **Architecture (Karpathy — top-down + bottom-up):**
    - Top-down: scheduler (Sunday wall-clock) → `generate(window: 7d)` → fetch convs+memories+tasks → LLM → `PatternDigest` row → notification.
    - Bottom-up: new `@Model PatternDigest` (4 JSON arrays + counters + dates) → `WeeklyPatternDetector` service (~250 lines) → AppDelegate wire → Settings toggle + hour picker.
  - **`Models/PatternDigest.swift` (NEW @Model):** id, weekStartDate, windowDays, themesJSON, peopleJSON, stuckLoopsJSON, insightsJSON, conversationsAnalyzed, createdAt. Computed `themes/people/stuckLoops/insights` decoders. `isEmpty` для UI rendering.
  - **`Services/Data/HistoryService.swift`:** schema +`PatternDigest.self` в обе ветки.
  - **`Services/Intelligence/WeeklyPatternDetector.swift` (NEW):**
    - 5-min scheduler tick. Fires when (a) Sunday in user TZ, (b) wall-clock >= configured hour, (c) no digest within last 6 days (anti-spam).
    - `generate(postNotification:)` — fetch convs + memories + open tasks within `windowDays=7`. If <3 convs → write empty digest, post "Quiet week" notif.
    - LLM via Pro proxy. Single call (~$0.02 per weekly fire). Prompt cap 16KB.
    - Parser: 4 sections → JSON arrays with strict cleaning (trim, filter empty).
    - Notification fired on success: title "Weekly patterns ready", body summary counts + "open Insights".
  - **`Models/AppSettings.swift`:** `+weeklyPatternsEnabled: Bool = false`, `+weeklyPatternsHour: Int = 18` (Sunday 18:00 default).
  - **`App/AppDelegate.swift`:** `+let weeklyPatternDetector = WeeklyPatternDetector()` + configure + conditional `startScheduler()`.
  - **`Views/Windows/MainSettingsView.swift`:** new `weeklyPatternsSection` под dailySummarySection в AI tab. Toggle + DatePicker для hour + manual-trigger hint pointing to Insights tab.
  - **System prompt rules:** anti-fabrication aggressive («empty array better than filler»). Stuck-loop definition tight: «discussed ≥3× AND no decisions extracted». Person format: name + role/context. Themes ≥3 distinct convs.
  - **Risks mitigated:**
    - Cost: cap 30 convs × 200 chars overview + 30 memories + 30 tasks = ~12KB prompt. ~$0.02 per fire.
    - Empty week: explicit threshold check + "Quiet week" notif (sound nil чтобы не дёргало).
    - Subjective stuck-loop: prompt requires «no decisions extracted from those convs» — anchored in Conversation.decisionsJSON (ITER-021).
  - **Files touched:** `Models/PatternDigest.swift` (NEW), `Services/Data/HistoryService.swift`, `Models/AppSettings.swift`, `Services/Intelligence/WeeklyPatternDetector.swift` (NEW), `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`.
  - **Tests pass:**
    - Build clean, debug + release rebuilt.
    - Schema migration: ZPATTERNDIGEST table created с 11 columns на live DB.
    - AppDelegate wired correctly (lines 432-434).
    - Settings UI section present + DatePicker functional.
    - Setting keys: `weeklyPatternsEnabled` Bool default false, `weeklyPatternsHour` Int default 18.
    - App running, fresh launch 9:55 PM.
  - **Live verification deferred:** scheduler fires только в Sunday в configured hour. Manual GENERATE button — TODO (Insights tab UI integration отдельный mini-track).
- ITER-022 G4 — Coach mode opt-in (accountability prompt path) (2026-04-25):
  - **Trigger:** advice audit identified coach-style accountability как gap vs reference. Reference default = coach + memories proactive. Наш default = pure insight + anti-coach (банилось "Take a break / Stay hydrated"). Решение: opt-in toggle who switches prompt.
  - **Architecture decision:** keep philosophical default (anti-noise pure insight) **AND** offer opt-in coach mode for users who want push-back. Single source of switching = `AppSettings.adviceCoachMode`. Read at fire time so toggle takes effect immediately.
  - **Fix:**
    - `Models/AppSettings.swift`: `+@AppStorage("adviceCoachMode") var adviceCoachMode: Bool = false`.
    - `Services/Intelligence/AdviceService.swift`:
      - Renamed `static let systemPrompt` → `systemPromptStandard` (current behaviour, anti-coach).
      - `+static let systemPromptCoach` — accountability prompt:
        - WHEN TO PUSH: stated commitment slipping, repeated distraction pattern, goal at 0 mid-day, intent contradicted by action.
        - STILL BANNED: generic wellness ("drink water", "stretch"), mood judgment ("you seem anxious"), therapy tone, vague motivation, shaming.
        - GOOD: "Ship X promised by Friday — 6h left, you've checked Twitter 5×". BAD: "Stay focused!" / "You can do it!".
        - WHEN TO STAY SILENT: no commitment to anchor, repeats prior advice, healthy break, user in active recorded meeting (don't interrupt).
      - `+static var activePrompt: String` — runtime selector based on setting.
      - `generateAdvice` callsite uses `Self.activePrompt` + logs `mode=standard|coach`.
    - `Views/Windows/MainSettingsView.swift`: `+toggleRow("Coach mode", ...)` в adviceSection с conditional explanatory text.
  - **No external callers** of `AdviceService.systemPrompt` outside the service — rename safe.
  - **Files touched:** `AppSettings.swift`, `AdviceService.swift`, `MainSettingsView.swift`.
  - **Tests pass:**
    - Build clean. Debug + release rebuilt. App relaunched.
    - Setting key registered (Bool, default false, AppStorage).
    - Both prompts present + activePrompt selector wired.
    - UI toggle visible at `MainSettingsView.swift:1323`.
- ITER-022 G3 — Memory-weave в AdviceService (semantic memory ranking) (2026-04-25):
  - **Trigger:** advice audit identified that AdviceService включал memories в prompt **flat (15 most recent)**. Без cosine ranking → LLM видел irrelevant memory bullets ("user likes coffee" при advice про код) → tempted to shoehorn unrelated memory ИЛИ ignored entirely.
  - **Fix — `Services/Intelligence/AdviceService.swift`:**
    - `+weak var embeddingService: EmbeddingService?` — wired в AppDelegate.
    - `+fetchMemoriesForAdvice(contexts:extraContext:limit:) async -> [UserMemory]`:
      1. Build query string from latest screen context (appName + windowTitle + ≤600 chars OCR) + extraContext.
      2. Embed via Pro proxy (skip non-Pro → fall back to recent-N).
      3. Score each non-dismissed memory с embedding by cosine similarity.
      4. Threshold 0.45 — drop irrelevant. Empty array better than wrong memories.
      5. Top-`limit` (default 8) by score.
    - `buildAdviceUserContext(...)` теперь `async`, использует new ranker. Original block label updated to "USER MEMORIES (durable facts — weave only when materially relevant)".
    - `generateAdvice` callsite: `let contextBlock = await buildAdviceUserContext(...)`.
    - **System prompt: новая секция MEMORY-WEAVE** — explicit rules:
      «Reference a memory ONLY when it materially changes the advice». Concrete worked example («Stripe webhook test mode + memory 'ChatApp uses Stripe billing' → "switch to test customers"»). Forbidden: shoehorning, "you said earlier...", verbatim quoting.
  - **AppDelegate wiring:** `adviceService.embeddingService = embeddingService` after configure.
  - **Risk mitigated:** "force-weave even when irrelevant" — threshold 0.45 + explicit anti-shoehorn rule.
  - **Files touched:** `AdviceService.swift`, `AppDelegate.swift`.
  - **Tests pass:**
    - Build clean. Wired correctly: `adviceService.embeddingService = embeddingService` line 502.
    - DB: **19/19** active memories with embedding (100% coverage from ITER-008/011 backfill) → semantic ranking will engage immediately.
    - Function signature correct (async returns `[UserMemory]`).
    - App running, 0% CPU idle, fresh relaunch 9:44PM.
- ITER-022 G1 — AdviceService categories расширены 4 → 11 (2026-04-25):
  - **Trigger:** advice audit comparing our prompts vs reference revealed our advice categorization was 4 classes (productivity / communication / learning / other) vs reference 11+. Health / financial / relationships / mental / security / career — все падали в `other`, теряя filter signal.
  - **Diagnostic finding (Karpathy):** existing DB distribution showed LLM был **CREATIVE** и уже сам генерил `health` (20 items!) и `security` (1) ДО legitimization. Old whitelist был unnecessarily ограничивающим — мы downgrade'или legitimate categorical signal в `other` parser fallback'ом. Расширение **формализует** behaviour LLM который уже происходил.
  - **Fix — `Services/Intelligence/AdviceService.swift`:**
    - System prompt: новый CATEGORIES section с 11 explicitly-defined types: `productivity / communication / learning / health / finance / relationships / focus / security / career / mental / other`. Каждая с строгой scope clarification (e.g. "health — ergonomics/credentials/screen-time, NOT 'drink water'"; "mental — observed pattern, NOT therapy/mood judgment").
    - Critical anti-noise note: WHEN-TO-STAY-SILENT rules **OVERRIDE** category fit. "health" не означает можно nag'ать — advice по-прежнему must be specific/actionable/non-obvious.
    - Static `Self.validCategories: Set<String>` — whitelist для parser normalization.
    - Parser: `let normalizedCategory = validCategories.contains(candidate.lowercased()) ? candidate.lowercased() : "other"` — defends against typos / hallucinated categories.
  - **Files touched:** `Services/Intelligence/AdviceService.swift` only.
  - **Build:** clean. Debug + release rebuilt. App relaunched.
  - **Test results:**
    - Grep clean — no consumer hardcoded old 4 categories (UI render is category-agnostic)
    - DB inspection: 81 productivity / 42 learning / 28 communication / 20 health / 2 other / 1 security baseline before fix
    - Live verification deferred to next 15-min periodic fire (new categories: finance/relationships/focus/career/mental will appear when warranted)
- ITER-021.2 — Tasks staged candidates 2-tap → 1-tap UX fix (2026-04-25):
  - **Trigger:** user-reported «зачем здесь галочка и крестик когда нажимаешь галочку то таска делается и нужно еще раз нажать галочку — почему нельзя нажимать просто галочку сразу чтобы task считалась сделанной». Two-click flow for what's intuitively a single "done" tap.
  - **Diagnosis:** UX-design disconnect. Visually a checkmark = done. Functionally it was promote (move to MY TASKS), then user had to tap ✓ AGAIN in the active list to mark done. Two clicks for the most-common intent ("I already did this").
  - **Fix — `Views/Windows/TasksView.swift` `candidateCard(_:)`:** 3 actions instead of 2:
    - **✓ DONE** (was: promote) — single-click sets `completed=true`, `completedAt=now`, `status="committed"`. Counts toward Shipped/Done stats. The right default for screen-extracted tasks reflecting work the user already did.
    - **+ SAVE FOR LATER** (new) — promote to MY TASKS active without completing. Use case: "будут делать потом". Old ✓ behavior preserved on this button.
    - **✗ DISMISS** — unchanged, hide as not relevant.
  - Header hint updated: `auto-extracted · ✓ done · + save for later · ✗ skip` so the 3 actions are self-documenting.
  - Each button has a `.help(...)` tooltip for hover discovery.
  - **Why default ✓ = done makes sense:** screen-extracted candidates almost always reflect work the user is currently doing or just finished (the OCR pipeline literally watches the screen during the action). Treating ✓ as "save for later" was inverted — the rare case got the default, the common case got two clicks.
  - **Files touched:** `Views/Windows/TasksView.swift` (single function rewrite).
  - **Build:** clean. App rebuilt + signed + relaunched.
- ITER-021.1 — Project deletion (2026-04-25):
  - **Trigger:** user-reported «есть проекты которые не нужны и их не существует но я не могу поправить — надо добавить возможность удалять» on the Projects view (14 clusters including noise like "Microsoft Clarity", "Atomic", "DRUGENERATOR").
  - **Diagnosis (Karpathy):** owner-layer = `ProjectAlias` row + raw `Conversation.primaryProject`. Two states must change atomically — alias gone AND linked conversations unlinked. Conversation rows themselves stay (transcript = user data, deleting a project ≠ deleting recordings).
  - **`Services/Intelligence/ProjectAggregator.swift`:** new `deleteProject(canonicalName:) -> Int` method:
    1. Find `ProjectAlias` by canonical name (returns 0 if already gone — idempotent).
    2. Fetch all `Conversation` with `primaryProject != nil`, filter case-insensitive against `alias.aliases`, set `primaryProject = nil` + bump `updatedAt`. Predicate-side OR-of-aliases awkward in SwiftData → in-memory filter (cheap, <100 rows typical).
    3. Delete the `ProjectAlias` row.
    4. Single `ctx.save()`. Returns count of unlinked convs for UI feedback.
  - **`Views/Windows/ProjectsView.swift` (ProjectDetailView):**
    - Header: red `DELETE` button (icon `trash`, red.opacity(0.85), red border).
    - Confirmation dialog: «Delete project "X"? \(N) conversations will become uncategorized. Linked tasks (T) and memories (M) NOT affected.» Destructive button + Cancel.
    - On confirm → `deleteProject(...)` → `onBack()` returns to grid.
  - **`ProjectsView.content`:** `onBack` callback now also triggers `Task { await refresh() }` so deleted cluster disappears from the grid immediately without waiting for next .task fire.
  - **What does NOT happen:** Conversations stay (transcripts intact). TaskItem/UserMemory FK to Conversation untouched. Re-classification: at the next `StructuredGenerator.generate(_:)` (manual REGENERATE in detail view, or on close of new convs) the LLM may re-extract a project for an unlinked conv — that's correct behaviour, lets the user re-categorize naturally.
  - **Files touched:** `Services/Intelligence/ProjectAggregator.swift`, `Views/Windows/ProjectsView.swift`.
  - **Build:** clean. App rebuilt + signed + relaunched.
- ITER-021 — Conversation structured summary + bugfix Quick note (2026-04-25):
  - **Trigger:** user-reported «созвон записывается как Quick note и empty, как посмотреть полную транскрипт, надо его структурировать ещё как-то». DB inspection found 2026-04-25 13:33:07 meeting stuck with 3611-char transcript but title="Quick note" + overview="(empty)" — `backfillPlaceholders()` had only run on app launch, never re-ran.
  - **3 distinct root causes diagnosed (Karpathy):**
    1. **Bug — backfill too narrow:** query was `title == "Quick note"` only, missed `overview == "(empty)"` cases where title was set but LLM call failed.
    2. **Bug — backfill timing:** ran only on launch. If user kept app running while meetings closed during a transient proxy outage, those stayed stuck forever.
    3. **Feature gap — flat overview:** `StructuredGenerator` produced 1-3 sentence prose but no decisions / action items / participants / quotes / next steps; no way to see full transcript ergonomically.
  - **Data model — `Models/Conversation.swift`:** +5 Optional JSON fields:
    - `decisionsJSON` — concrete decisions made (≤5 items, ≤14 words each).
    - `actionItemsJSON` — explicit commitments (display-only — TaskExtractor still creates separate TaskItem rows for the Tasks tab).
    - `participantsJSON` — named people besides the speaker.
    - `keyQuotesJSON` — verbatim memorable lines (≤25 words each).
    - `nextStepsJSON` — forward-looking topics for next meeting.
    - `decisions` / `actionItems` / `participants` / `keyQuotes` / `nextSteps` — computed accessors decoding JSON arrays.
  - **`StructuredGenerator.swift` — 4 layered fixes:**
    1. **System prompt extension** — new ITER-021 section adds 5 fields with strict anti-fabrication rules («empty array better than filler»).
    2. **`StructuredJSON` parser** — 5 new optional `[String]` fields with `key_quotes` / `action_items` / `next_steps` snake_case CodingKeys.
    3. **Writeback** — 5 new fields encoded via `Self.encodeStringArray(_:)` helper which trims, filters empty, returns nil for empty array (UI distinguishes "not extracted" from "explicitly empty").
    4. **`backfillPlaceholders` query expanded** — now matches `title == "Quick note" OR overview == "(empty)"` AND not discarded.
    5. **`startPeriodicBackfill()` / `stopPeriodicBackfill()`** — runs every 30 min via `Task.sleep`. Catches conversations that close while app is running but proxy was briefly down. Cancellable.
    6. **`regenerate(conversationId:)` public** — manual force-retry for the UI button. Resets all 11 LLM-populated fields then calls `generate(_:)`.
  - **NEW `Views/Windows/ConversationDetailView.swift`** — full-screen detail view replacing the previous inline-expand pattern:
    - Header — emoji + title + category/project/source chips + dates + REGENERATE/STAR buttons + overview prose.
    - Tab bar — SUMMARY / TRANSCRIPT / LINKED.
    - SUMMARY — 5 structured sections (decisions/action items/participants/key quotes/next steps), each rendered as Liquid Glass card; empty sections hidden; if all empty → friendly empty-state telling user to click REGENERATE.
    - TRANSCRIPT — full scrollable + selectable text per HistoryItem, time + language stamps, total chars summary.
    - LINKED — pending tasks split MY / WAITING-ON (ITER-013 ownership), memories with headline + content.
    - REGENERATE button calls `structuredGenerator.regenerate(_:)` then reloads; if result still placeholder → surfaces explicit error message.
  - **`ConversationsView.swift`** — replaced inline `expandedDetails` with state-driven push to `ConversationDetailView`:
    - `@State openedDetailId: UUID?` — when non-nil, list swaps for detail view + BACK button.
    - Row tap → set `openedDetailId = conv.id`. No more confusing toggle behaviour.
    - Added `chevron.right` affordance on every row so users know it's clickable.
    - Old `expandedDetails / linkedTranscripts / linkedTasks / linkedMemories` helpers retained as dead code (referenced by future quick-peek feature, deferred to v2).
  - **`AppDelegate.swift`** — wired `startPeriodicBackfill()` after the launch backfill task.
  - **Verified post-deploy:** stuck conversation 2026-04-25 13:33 was rewritten by backfill within ~25s of relaunch — title now "Team Discusses Content Manager" + overview real prose. 6 action_items, 2 decisions, 2 participants populated across recent conversations on first sweep. Schema columns confirmed via `PRAGMA table_info`.
  - **Files touched:** `Models/Conversation.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Views/Windows/ConversationDetailView.swift` (NEW), `Views/Windows/ConversationsView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean (3 pre-existing warnings only).
  - **Deferred to v2:** quick-peek inline expand on option-click; per-section regenerate; export to Markdown; full-text transcript search.
- 2026-04-25 — Dashboard freeze fix + adaptive layout + old-build diagnostic:
  - **Diagnostic context (Karpathy top-down + bottom-up):**
    - User reported «дашборд жестко зависает + ничего не вижу из мемориес/тасков». Two distinct problems revealed by investigation.
    - **Old build running:** `/Users/android/Applications/MetaWhisp.app` was the 22-Apr binary (pre-Phase 5 G1, pre-ITER-013-017). DB had **3539 history, 19 memories, 100 tasks, 3674 screen contexts, 52 conversations** — data was fine, exe was stale. Killed via `./build.sh` rebuild + reinstall + relaunch.
    - **SwiftData migration succeeded** on first launch of fresh build: ZGOAL, ZAUDITLOG, ZPROJECTALIAS tables added; ZASSIGNEE, ZPRIMARYPROJECT, ZTOPICSJSON, ZTOOLCALLIDNATIVE etc. columns added to existing tables. Lightweight migration (all-Optional fields) worked. DB backup: `MetaWhisp.store.backup-2026-04-25` (16.2 MB).
    - Backfill kicked off automatically: ITER-011 conversation embeddings (52/52 immediate, all had been embedded earlier session by old build), ITER-014 project classification (4 → 14 → ... rolling, ~5 min for 52 convs at 300ms LLM gap), ITER-013 task assignee (won't backfill — only new tasks get assignee from new prompt).
  - **Dashboard freeze (98.9% main-thread CPU on idle):** Sample profiler caught:
    ```
    StatisticsView.body → wpm.getter → stats → PeriodStats.init
    → TextAnalyzer.fillerCount → fillerWords → String.range(of:)
    ```
    1187/1567 main-thread samples in `_stringCompareInternal`.
    - **Root cause:** `PeriodStats.init` called `TextAnalyzer.fillerCount(in: items.map(\.text).joined(separator: " "))` on EVERY render. With 3500+ history items × avg 50 chars = ~177KB string scanned through filler-word list with `String.range(of:)` for each filler — **multi-million Unicode comparisons per render frame**. SwiftUI re-evaluates every computed prop (`wpm`, `stats`, etc.) on every render, so even a single state change re-triggered the whole scan.
    - **Fix v1 — drop `fillerPct` from `PeriodStats.init`:** removed the heavy `fillerCount` call from the hot path. The single consumer (`sharePeriodStats`) recomputes percentage on-demand from the already-async-cached `fillersCache: [(word, count)]` — `fillersCache.reduce(0) { $0 + $1.count }`.
    - **Fix v2 — cache ALL Calendar-heavy derived stats:** sample after fix v1 showed `bestDay`, `peakWordsDay`, `longestStreak`, `popularHour`, `streakDays` still doing per-render Calendar.startOfDay scans of 3500+ items. Introduced `DerivedStats` struct + `@State var derivedCache: DerivedStats` populated by `recomputeDerivedStats() async` running on `Task.detached(priority: .utility)`. The 5 expensive computed props now read from cache; getters return `.empty` defaults until first compute completes.
    - **Fix v3 — pre-filter `current`/`previous`:** `currentCache`/`previousCache` populated by `recomputeFilteredItems()` so body doesn't re-run `selectedPeriod.filter(allItems)` per frame.
    - **Result:** CPU 98.9% → 73% (active backfill + initial render) → **0.0% idle**. Freeze gone.
  - **Adaptive Dashboard layout:** original `HStack(DailySummaryCard, [TodayStatsCard|ScreenActivityCard].frame(width: 280))` clipped the right column when window was < ~700pt. Wrapped body in `GeometryReader`; threshold `twoColumnThreshold = 720`:
    - Wide → 2-column (current behavior, no clip).
    - Narrow → single-column stack (DailySummaryCard full-width above; TodayStatsCard + ScreenActivityCard stack below, side-by-side at ≥480pt or stacked further at < 480pt).
    - Title + statusStrip same adaptive treatment.
  - **Files touched:** `Views/Components/StatComponents.swift` (drop fillerPct from PeriodStats), `Views/Windows/StatisticsView.swift` (DerivedStats cache + recomputeDerivedStats + filter cache + getter redirects + dead legacy removal), `Views/Windows/DashboardView.swift` (GeometryReader + adaptive single/multi-column layout).
  - **Build:** clean. `.app` rebuilt + reinstalled to `/Users/android/Applications/MetaWhisp.app` + signed + launched.
- ITER-017 v3 — Search tools + auto-execute read-only + bounded agentic loop:
  - **Goal:** превратить chat из «угадай UUID или копируй вручную» в реальный agent. Юзер: «убери задачу про Майка» → LLM сам делает `searchTasks(query="Майк")` → получает list → выбирает right id → вызывает `dismissTask` → confirm → execute. Поднимает usability на порядок.
  - **3 read-only tools** (`Services/Intelligence/ChatToolExecutor.swift`):
    - `searchTasks(query, limit?)` — top-N matching task items.
    - `searchMemories(query, limit?)` — matching user_facts.
    - `searchConversations(query, limit?)` — matching past meetings/dictations.
    - All return JSON `{items: [...], count: N}` в `ExecResult.summary` (LLM парсит из tool_result content).
  - **`isReadOnly(_:)` + `readOnlyTools` Set** — узкий whitelist. Read-only tools:
    - **auto-execute без confirm** (нет mutation = нет рисков),
    - **bypass rate-limit** (read не вредит),
    - **не пишутся в AuditLog** (нет snapshot — undo нерелевантно),
    - **не имеют валидации** (любой query валиден).
  - **`executeReadOnly(_:) async -> ExecResult`** — отдельный path в `ChatToolExecutor`, async (для embedding fetch).
  - **`rankByQuery` generic helper** — semantic ranking когда есть `embeddingService` + Pro license:
    - Embed query → cosine vs item embeddings → top-N.
    - Fallback: substring/keyword token-overlap match (когда нет embedding'а или non-Pro).
    - Threshold: items с zero matches фильтруются (substring path).
  - **`ChatToolExecutor.configure` signature update:** `+embeddingService: EmbeddingService? = nil`.
  - **Bounded agentic loop — `ChatService.runAgenticLoop(userPrompt:licenseKey:maxRounds:)`:**
    - Local `messages: [[String: Any]]` array, начинается с `[{role:"user", content:userPrompt}]`.
    - Each round: `callProChatWithTools(...)`. Branches:
      - text only → loop ends, return text.
      - read-only tool_call → `executor.executeReadOnly(call)` → append `{role:"assistant", tool_calls:[…]}` + `{role:"tool", tool_call_id, content: result.summary}` → continue loop.
      - mutation tool_call → loop ends, return `pendingMutation` (handed off to existing confirm flow).
    - Hard cap `maxRounds = 5`. На превышении → возвращаем accumulated text + soft note "Cap reached — pause and let me know if you want to continue."
    - `AgenticOutcome { text, pendingMutation, roundsUsed }` — структурированный результат, лог `[ChatService] loop done rounds=3 text=128 pending=dismissTask`.
  - **`ChatService.send`** теперь вызывает `runAgenticLoop` для Pro path вместо одиночного `callProChatWithTools`. Non-Pro path unchanged (regex без loop).
  - **AppDelegate:** `chatToolExecutor.configure(modelContainer, embeddingService: embeddingService)` — wire'ит embeddings для semantic search.
  - **System prompt update:**
    - Новая READ-ONLY секция в `<available_tools>` с описанием 3 search'ей.
    - Tool-use rules расширены: «search encouraged whenever you need an id; id MUST come from context OR prior search result; if search returns 0 → say so plainly».
    - Mutation rules unchanged (explicit verb only, no bulk, no invented UUIDs).
  - **User stories (now possible):**
    - «убери задачу про Майка» → searchTasks → 2 results → LLM picks best match → dismissTask → confirm → execute → followup (ITER-017 v2).
    - «найди мои memories про ChatApp» → searchMemories → text response с listing.
    - «о чём говорили в звонке про цены?» → searchConversations → returns top match → LLM quotes overview.
    - «забудь что я работаю в X» → searchMemories(query="X work") → dismissMemory → confirm.
  - **Files touched:** `Services/Intelligence/ChatToolExecutor.swift`, `Services/Intelligence/ChatService.swift`, `App/AppDelegate.swift`.
  - **Build:** clean.
  - **Risks (live-test):**
    - Loop cap 5 — если LLM зацикливается на search'ах, lo-fi degradation.
    - Search query LLM может generate'нуть слишком общий ("задача") → много results → LLM теряется. Решение в v4 — instruct LLM писать SPECIFIC queries (имя/проект/глагол).
    - Cost: каждый round = LLM round-trip + (для Pro) embedding round-trip. 5 rounds = до 10 API calls. Пока приемлемо при cap 5.
- ITER-017 v2 — Multi-step agentic loop (followup after tool execute):
  - **Goal:** превратить native tool-use из «one-shot» в нормальный agent-style flow. После confirm и execute LLM получает `tool_result` обратно через `{role:"tool"}` сообщение и может (а) дать осмысленный followup ("Готово, убрал. Что-то ещё?"), либо (б) вызвать ещё один tool — который снова уйдёт в confirm. Бесконечного loop пока нет (v3).
  - **Why minimum-surgical:** не делал full agent loop с auto-execute read-only search tools. Это даёт 80% value (LLM знает что tool сработал) at 30% complexity. Search-and-act цепочки — следующая итерация.
  - **Data model — `Models/ChatMessage.swift`:**
    - `+toolCallIdNative: String?` — native `tool_call_id` из Groq response. Нужен чтобы связать этот assistant turn с матчинговым `{role:"tool", tool_call_id:...}` ответом. Nil для legacy regex path (там нет native id).
    - `+originatingUserPrompt: String?` — persisted ON the assistant message (не пересобираем prompt в continuation, потому что retrieval blocks могли drift'нуть между ходами и LLM должен видеть ТОТ ЖЕ контекст).
    - `+followupOfMessageId: UUID?` — parent link для chain-rendering и chain-builder walk-back.
  - **`ChatToolExecutor.ToolCall`:** `+let id: String?` — native id, опциональное (regex path → nil → multi-step disabled для них).
  - **`parseNativeToolCall`** теперь захватывает `id` из first array element. `parseToolCall` (regex) → id = nil.
  - **`encodeToolCall` / `decodeToolCall`** roundtrip-ят native id через `pendingToolCallJSON` JSON, чтобы после restart confirmTool всё ещё знал correct id.
  - **`ChatService.send`:** при создании assistant message с pending tool — стора native call.id и full userPrompt в новых полях. Лог: `[ChatService] ✅ Got response (X chars, pendingTool=…, nativeId=call_abc123)`.
  - **`ChatService.confirmTool`:** после execute, если у нас есть native id + originating prompt + успех → fire-and-forget `Task` вызывает `continueAfterToolExecution(...)`.
  - **NEW `continueAfterToolExecution(parentMessageId:toolCall:toolResult:)`:**
    - Перечитывает parent assistant message из DB (для freshness — undo мог его поменять).
    - Билдит 3-message conversation: `user → assistant_with_tool_calls → tool_result`.
    - Вызывает `callProChatWithTools` round 2 с теми же `toolSchemas`.
    - Response branch:
      - text only → insert новый ChatMessage(text) с `followupOfMessageId = parent`.
      - text + ещё один tool_call → insert новый ChatMessage с pending state (юзер confirm'ит ещё раз; цикл стопается). Native id и originatingUserPrompt пробрасываются на followup тоже, чтобы chain мог продолжаться рекурсивно.
      - empty text + no tool → не вставляем ничего (LLM нечего добавить).
    - Errors грейсфул-логируются, не affect parent message.
  - **Какие User Stories теперь работают (примеры):**
    - «убери задачу X» → confirm → ✓ Dismissed task X → followup AI: «Убрал. Осталось Y задач, могу что-то ещё?»
    - «отметь сделанной задачу про деплой» → confirm → ✓ Marked done → followup: «Отлично, Shipped count за сегодня вырос до 4».
    - LLM может ОТКАЗАТЬСЯ продолжать (просто не вернёт followup) — это OK, мы insert'им nothing.
  - **Что НЕ работает в v1 (deferred to v3):**
    - Search tools (`searchTasks` / `searchMemories`) — без них «найди и убери таску про Майка» всё ещё требует точного UUID. Юзер должен сам сослаться на конкретный item из контекста.
    - Auto-execute read-only tools без confirm — следующий шаг.
    - Бесконечный loop с лимитом rounds — сейчас strictly 1 followup per confirm.
  - **Files touched:** `Models/ChatMessage.swift`, `Services/Intelligence/ChatToolExecutor.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (3 pre-existing warnings).
- ITER-017 — Native tool-use API + Proactive chip hover-extension:
  - **Goal A (Native tool-use):** перевести Pro-path с фрагильного `<tool_call>` regex на структурированный native function-calling protocol (Groq OpenAI-compatible API). Reliable parsing + готов к multi-step агентским паттернам в v2.
  - **Goal B (Hover-extension):** chip перестаёт исчезать пока курсор над ним — юзер успевает прочитать длинные memories.

  ### Native tool-use (Goal A)

  - **Backend — `api/src/index.js`:**
    - NEW `/api/pro/chat-with-tools` endpoint via `handleProChatWithTools(request, env)`.
    - Body: `{system, messages, tools, max_tokens?, temperature?}`. `tools` empty → plain chat без function-calling. Non-empty → `tool_choice: "auto"` + Groq parses tool_calls.
    - Response: `{text, tool_calls, finish_reason}`. Forwards Groq response verbatim для structured parsing на клиенте.
    - Validation: системный prompt required, messages array required (>= 1), tools required (`[]` ok). Payload soft cap 64000 chars.
    - Same Groq Llama-3.3-70b-versatile backend как `/advice` (no SDK switch).
    - **Deployed** to `api.metawhisp.com` через `wrangler deploy`. Smoke-test: `curl ... -d '{...fake auth...}'` → returns 401 invalid license, доказывая endpoint reachable + JSON parsing OK.
  - **Tool schemas — `Services/Intelligence/ChatToolExecutor.swift`:**
    - NEW static `toolSchemas: [[String: Any]]` — массив 6 OpenAI function schemas (dismissTask / completeTask / dismissMemory / updateGoalProgress / addTask / addMemory). Каждая: name, description (тщательно сформулировано чтобы Groq tool_choice="auto" корректно выбирал), parameters JSON Schema, required fields.
    - NEW static `parseNativeToolCall(from: [[String: Any]]?) -> ToolCall?` — извлекает первый element из `tool_calls` array, парсит nested `function.arguments` (JSON-encoded string в Groq response).
  - **Client transport — `Services/Intelligence/ChatService.swift`:**
    - NEW `NativeChatResponse` struct: `text, toolCall, finishReason`.
    - NEW `callProChatWithTools(system:messages:tools:licenseKey:)` — POSTs to `/api/pro/chat-with-tools`, parses response. 60s timeout, error includes HTTP code + body snippet.
    - NEW `buildNativeMessages(userPrompt:history:)` — v1 returns `[{role:"user", content: userPrompt}]`. История уже в `<previous_messages>` блоке внутри userPrompt — не дублируем. Multi-turn (v2 deferred) добавит `{role:"tool", tool_call_id:..., content:...}` после execute.
    - **`send(...)` rewrite:** Pro path → native tool-use. Non-Pro path → старый regex `<tool_call>` (backward compat, без backend dependency).
      - Унифицировано: оба пути собирают `nativeToolCall: ToolCall?` → одинаковая validate/queue логика → одинаковый pending-bubble UX.
      - Лог: `[ChatService] native finish=tool_calls text=0 toolCall=dismissTask` для diagnostic.
  - **Что лучше становится сразу:**
    - LLM не может «забыть» закрыть тег / вернуть broken JSON (теперь structured parsing).
    - Меньше промпт-инжиниринга: `<available_tools>` блок в system prompt можно ужать (deferred — оставил как есть пока, structured tool_choice="auto" работает с обоими instruction styles).
    - Финиш-reason `tool_calls` явно отделён от `stop` — UI/logging видит intent.
  - **Что НЕ делал в v1 (deferred to ITER-017 v2):**
    - Multi-step agentic loop (после execute → push tool_result в messages → продолжить inference). Сейчас один inference per send. Хочется когда юзер пишет «найди и убери таску про Майка» — LLM сделает search → dismiss с правильным id.
    - Settings toggle `useNativeToolCalling` — пока всегда native для Pro. Вынесем как opt-out если Groq косячит.

  ### Hover-extension (Goal B)

  - **Files:** `Views/Proactive/ProactiveChipView.swift` + `Views/Proactive/ProactiveChipWindow.swift`.
  - **`ProactiveChipView`:** `+onHoverChange: ((Bool) -> Void)?` callback, `.onHover { ... onHoverChange?($0) }` пробрасывает enter/exit наверх.
  - **`ProactiveChipWindow`:** `+handleHoverChange(_:)`. Enter → cancel `fadeTask`. Exit → `armFadeTimer()` (re-arm полным `visibleSeconds` окном, не leftover).
  - Семантика: пока курсор НА chip — таймер заморожен. Когда уходишь — стартует свежее 8s окно. Удобно если юзер случайно навёлся, потом ушёл — ещё успеет глянуть.

  - **Build:** clean (3 pre-existing unrelated warnings).
- ITER-016 v2 — Tool-calling polish: undo + rate-limit + audit log:
  - **Goal:** перевести client-side tool-calling из v1 «best effort» в production-grade. Undo для recovery от ошибочных confirm'ов, rate-limit от runaway loops, audit log для review «что AI сделал сегодня».
  - **Undo (in-bubble button):**
    - Каждая успешная execute() сохраняет PRE-MUTATION snapshot в `AuditLog.snapshotJSON` (минимально для revert: e.g. dismissTask → `{taskId, wasIsDismissed, wasStatus}`).
    - Окно 60s от момента execute (не LLM-ответа) — `ChatMessage.toolExecutedAt` set'ится при confirm.
    - UI: inline UNDO button в outcome-bubble, рендер обёрнут в `TimelineView(.periodic(by: 5))` чтобы кнопка автоматом исчезала по истечении окна без манипуляций юзера.
    - Click → `ChatService.undoTool(messageId:)` → `ChatToolExecutor.undo(auditId:)` → restore из snapshot, audit row помечается `undone = true` (append-only — не удаляем).
    - Refused undo (expired / already done / failed action) — surface'им reason в bubble (`✗ Already undone`, etc.).
  - **Rate limit:**
    - In-memory rolling window (60s, max 5 mutations) в `ChatToolExecutor.recentExecutionTimestamps`.
    - Проверка ДО side-effect, отказ с человеко-читаемым summary `Rate-limited (max 5 actions per minute)`.
    - Rejected attempts ВСЁ РАВНО audit'ятся (success: false) — для review «AI пытался спамить».
  - **Audit log (`Models/AuditLog.swift` NEW @Model):**
    - Поля: `id, timestamp, tool, argsJSON, resultSummary, success, snapshotJSON, undone, chatMessageId`.
    - Append-only: ни одной DELETE / mutate операции после insert (только `undone` flip).
    - Schema добавлен в `HistoryService` (main + in-memory fallback).
    - Static `AuditLog.undoWindowSeconds = 60` + computed `isUndoable: Bool` инкапсулируют политику.
  - **ChatToolExecutor signature:**
    - `execute(_ call: ToolCall, chatMessageId: UUID? = nil) -> ExecResult` — chatMessageId binds audit row к сообщению для UI undo lookup.
    - `ExecResult(ok, summary, auditId)` — auditId доступен caller'у для прямой ссылки.
    - `undo(auditId:)`, `auditEntry(forChatMessage:)` — публичный API для ChatService.
    - Helpers: `writeAudit`, `encodeSnapshot`, `decodeSnapshot` (JSONSerialization-based, толерантны к heterogeneous values).
  - **Files:** `Models/AuditLog.swift` (NEW), `Models/ChatMessage.swift` (+toolExecutedAt), `Services/Data/HistoryService.swift` (+AuditLog в schema), `Services/Intelligence/ChatToolExecutor.swift` (rate-limit + audit + snapshot + undo для всех 6 tools), `Services/Intelligence/ChatService.swift` (+undoTool, передаёт chatMessageId в execute), `Views/Windows/ChatView.swift` (UNDO button + TimelineView wrapper + undoVisible helper).
  - **Build:** clean.
  - **Что НЕ покрыл (deferred to v3):**
    - Audit View (отдельный экран «история действий AI») — данные есть в DB, UI ждёт.
    - Bulk undo (revert всех мутаций сессии) — обычно overkill, на запрос.
    - Native Anthropic tool-use API (вместо `<tool_call>` regex) — будет ITER-017 когда backend extend.
- ITER-015 — Proactive in-the-moment surfacing (peripheral chip в углу экрана):
  - **Goal:** пока юзер отвечает в Slack/Mail/Notion → в правом верхнем углу тихо появляется chip с 2-3 relevant memories / past decisions / waiting-on tasks. НЕ нотиф, НЕ sound, НЕ воровство фокуса. 8s auto-fade, click item → MetaChat с pre-filled query.
  - **Design decisions (Karpathy-style, explicit):**
    - Opt-in (feature off by default, high wow → high annoyance risk).
    - Whitelist-based composing-intent detection (not classifier) — короткий список апок (Slack/Mail/Messages/Notion/Linear/Figma/Obsidian/Outlook/Discord/Telegram/Loom/Spark/Airmail/Superhuman). Tighter than blacklist, ~zero false-positives.
    - Relevance threshold 0.55 cosine — лучше пустой чип чем шум.
    - Cooldown 5 мин default — никогда не spammy.
    - Sensitive-app blacklist в Settings (1Password / Keychain / Terminal / iTerm / Activity Monitor / System Settings default).
    - Min 80 chars OCR — маленькие окна не триггерят.
    - Chip — borderless `NSPanel` + `.nonactivatingPanel` stylemask + override `canBecomeKey/Main → false` (non-activating). User's frontmost app НЕ теряет фокус.
    - `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` — чип виден на любом Space + поверх fullscreen.
  - **Files:**
    - `Services/Intelligence/ProactiveContextService.swift` (NEW) — основной пайп. `onNewContext(_:)` → gates → embed query → rank 3 types параллельно → threshold filter → top-3 → `ProactiveChipWindow.shared.show(...)`.
      - 3 retrievers: `rankedMemories` (все UserMemory с embedding'ом, cosine filter), `rankedConversations` (все Conversation с embedding'ом), `rankedWaitingTasks` (boost: только waiting-on tasks где имя assignee встречается в current OCR — когда ты пишешь Васе, напомнит что он должен).
      - SurfaceItem DTO с kind/title/subtitle/relevance/tapAction.
    - `Views/Proactive/ProactiveChipWindow.swift` (NEW) — `NonActivatingPanel` subclass + singleton controller. `show(items:source:)`, `hide()`, auto-fade Task (8s), positionTopRight.
    - `Views/Proactive/ProactiveChipView.swift` (NEW) — SwiftUI content. CONTEXT header + dismiss (×) + item rows (icon+title+subtitle). `.thinMaterial` glass + shadow.
    - `Models/AppSettings.swift` — `+proactiveEnabled`, `+proactiveCooldownMinutes` (default 5), `+proactiveBlacklist` (default "1Password,Keychain Access,Terminal,iTerm,Activity Monitor,System Settings").
    - `Views/Windows/MainSettingsView.swift` — NEW `proactiveSection` под screen-context в Integrations tab. Toggle + cooldown slider (1-30) + blacklist textfield + warning если Screen Context off.
    - `App/AppDelegate.swift` — `+let proactiveContextService`, configure с embeddingService, `screenContext.onContextPersisted` ветка зовёт `proactiveContextService.onNewContext(ctx)` после `realtimeScreenReactor.react`.
    - `Views/Windows/ChatView.swift` — `.onReceive(.proactivePrefillChat)` pre-fills input text когда chip item тапнут.
  - **Tap action:** `SurfaceTapAction.openChat(query:)` — chip скрывается, открывается MetaChat, через новый `Notification.Name.proactivePrefillChat` ChatView получает заготовленный вопрос типа `"Напомни что я жду от Сэм"` / `"Расскажи про созвон \"Q2 budget sync\""`.
  - **Build:** clean (только pre-existing Sendable warning в MainWindowController, не от этой фичи).
  - **Risks (live-test):**
    - **Privacy:** OCR первых 1500 chars улетает в Pro-proxy для embedding'а. Opt-in + blacklist + cooldown снижают expose. В Settings явный дисклеймер не помешал бы (v2 todo).
    - **Composing-intent heuristic** не распознает непопулярные мессенджеры — добавятся в whitelist по фидбеку.
    - **NSPanel + level .statusBar + Chrome/tier-"read"** — на тиер-read браузерах клики должны работать потому что chip — OUR window (не их), но live-test подтвердит.
    - **Hover-extension** визуального таймера не реализован в v1 — чип жёстко 8s. Mouse-enter extends — это v2.
    - Пустой DB (Pro user без накопленных memories / conversations) → retrieval вернёт []  → chip никогда не покажется. Правильное поведение.
- ITER-016 — Conversational mutation v1 (client-side tool-calling без backend extend):
  - **Goal:** убрать hallucination ("убрано" когда не убрано) — дать MetaChat реально мутировать данные. Юзер пишет «убери задачу X» → confirm bubble → execute → видит результат.
  - **Approach:** client-side tool-call через structured JSON в тексте (`<tool_call>{"tool":"…","args":{…}}</tool_call>`). Pro-proxy не трогаем. Upgrade path: замена парсера на native Anthropic/OpenAI tools дропином.
  - **Tools (6 в v1):** dismissTask, completeTask, dismissMemory, updateGoalProgress, addTask, addMemory. Каждая — validate → confirm UI → execute → result.
  - **Data model — `Models/ChatMessage.swift`:** `+pendingToolCallJSON: String?`, `+pendingToolPreview: String?`, `+toolResultSummary: String?`. Optional → SwiftData lightweight migration. Pending ≠ nil → UI рисует confirm bubble. toolResultSummary ≠ nil → бабл в resolved state с outcome line.
  - **New service — `Services/Intelligence/ChatToolExecutor.swift` (NEW):**
    - `ToolCall` struct + `parseToolCall(from:)` (regex extract `<tool_call>…</tool_call>`).
    - `validate(_:) -> Result<String, ToolError>` — pre-flight (target exists + not already in state). Возвращает preview string типа `"Dismiss task \"Reply to Mike\""` для confirm UI.
    - `execute(_:) -> ExecResult` — actual SwiftData mutation + human-readable summary для followup bubble.
    - 6 tools полноценно implemented, с нормализацией args (dueAt ISO, assignee capitalization, etc.).
  - **ChatService изменения:**
    - `+weak var toolExecutor: ChatToolExecutor?`
    - В `send()` после LLM response: parseToolCall → если найден → validate → success → save message в PENDING state (strip `<tool_call>` из displayed text, set preview). Если validate fails → показать inline ошибку в тексте, no confirm.
    - `confirmTool(messageId:)` / `cancelTool(messageId:)` API — вызываются из UI buttons. Confirm → execute → flip message в resolved state.
    - TTS skipped для pending messages (юзер должен прочитать confirm).
    - IDs теперь ПРОБРАСЫВАЮТСЯ в prompt — `<my_tasks>/<waiting_on>/<user_facts>/<active_goals>` каждая строка префиксится `[id:<uuid>]` / `[<uuid>]` чтобы LLM мог референсить в tool_call.
  - **System prompt rewrite — ChatService.swift:**
    - `<capabilities>` переосмыслен: YOU CAN → добавлен «CALL TOOLS на explicit action». YOU STILL CANNOT: web, DMs, multi-tool, unasked deletes.
    - Новый блок `<available_tools>` с schema всех 6 tools + strict rules: explicit verb only, no bulk, no invented UUIDs, ask-before-ambiguous, no self-confirmation (UI handles).
  - **UI — `Views/Windows/ChatView.swift`:**
    - messageRow: если `pendingToolPreview != nil && pendingToolCallJSON != nil` → рендер preview + [YES, DO IT] / [CANCEL] buttons.
    - Если `toolResultSummary != nil` (уже execute'нут) → показать outcome line (`✓ …` зеленоватый или `✗ …` красный) вместо кнопок.
    - Кнопки вызывают `AppDelegate.shared?.chatService.confirmTool(messageId:)` / `cancelTool(messageId:)`.
  - **AppDelegate wiring:** `+let chatToolExecutor = ChatToolExecutor()`, configure + `chatService.toolExecutor = chatToolExecutor`.
  - **Files touched:** `Models/ChatMessage.swift`, `Services/Intelligence/ChatToolExecutor.swift` (NEW), `Services/Intelligence/ChatService.swift`, `Views/Windows/ChatView.swift`, `App/AppDelegate.swift`.
  - **Build:** clean (3 pre-existing warnings).
  - **v2 deferred (следующая сессия):** undo toast (10s window + snapshot), per-session rate-limit (max 5 mutations/min), `Models/AuditLog.swift` (append-only `{timestamp, tool, argsJSON, resultJSON}` для audit review), switch на native tool-use API когда backend extend.
  - **Risks (live-test):**
    - LLM может вырезать `<tool_call>` частично (broken JSON) → parser возвращает nil → chat показывает raw text. Acceptable fallback.
    - LLM может галлюцинировать UUID не из контекста → validate возвращает notFound → surface "Not found: abc123…". No mutation.
    - Edge: user пишет «убери таску» не указав конкретную → LLM по правилу 4 должен clarify в plain text, не tool_call. Зависит от LLM following rules.
- ITER-014 — Topic / project auto-clustering (Projects tab + MetaChat world map):
  - **Goal:** превратить плоский список созвонов в Projects-view с auto-detected кластерами. MetaChat получает `<active_projects>` блок чтобы отвечать «что у меня с ChatApp» точно.
  - **Approach:** не k-means по embeddings (слепые кластеры без имён). Вместо — explicit label от LLM на close + merge aliases через centroid embeddings.
  - **Data model:**
    - `Models/Conversation.swift` — `+var primaryProject: String?`, `+var topicsJSON: String?` (JSON `[String]`). Оба Optional → SwiftData lightweight migration.
    - `Models/ProjectAlias.swift` — NEW @Model. `canonicalName`, `aliasesJSON` (включает canonical), `centroidEmbedding: Data?`. Helper `addAlias(_:)` с case-insensitive dedup.
    - `Services/Data/HistoryService.swift` — schema list включает `ProjectAlias.self` в обоих местах (main + in-memory fallback).
  - **Prompt — `Services/Intelligence/StructuredGenerator.swift`:**
    - Добавлены PROJECT и TOPICS секции с критериями («most concrete recurring entity, not category»). Ru/en примеры GOOD/BAD.
    - JSON schema `+"project": "..."|null, "topics": [...]`.
    - Parser `StructuredJSON` — оба поля optional (graceful downgrade для старых промптов).
    - Writeback в Conversation: тримит `project`, лёйтерит к lowercase + фильтрует empty topics.
  - **Service — `Services/Intelligence/ProjectAggregator.swift` (NEW):**
    - `listProjects() -> [ProjectSummary]` — агрегирует raw `Conversation.primaryProject` через raw→canonical map из `ProjectAlias`; считает linked tasks (my vs waiting-on) + memories + last activity + members (assignees от ITER-013).
    - `details(for: canonical) -> ProjectDetails` — выдаёт конкретные conversations + tasks + memories для detail view.
    - `resolveCanonical(_:)` — cheap path: exact-match case-insensitive across all aliases → reuse. Miss → новый `ProjectAlias`.
    - `backfillProjects(structuredGenerator:)` — re-run structured-gen для legacy `primaryProject == nil && status == "completed"` convs; seeds `ProjectAlias` через resolveCanonical. 300ms пауза между вызовами чтобы не DDOSить proxy.
    - `mergeAliases()` — periodic embedding-similarity pass: обновляет centroid на базе conv embeddings; пары с `cosine ≥ 0.88` мёрджатся (smaller → larger). Threshold 0.88 (looser чем dedup'овский 0.92 потому что project names короткие и контекст шире).
  - **UI — `Views/Windows/ProjectsView.swift` (NEW):**
    - Grid карточек (adaptive 280-360px), click → inline detail view.
    - Карточка: canonical name, counts (tasks/done/memories/conversations), relative last-activity, top members (assignees). REFRESH button.
    - Detail view — back button + 3 секции: CONVERSATIONS (emoji + title + overview), PENDING TASKS (description + «waiting on X»), KEY MEMORIES (headline + content).
    - EnvironmentObject(ProjectAggregator) через `MainWindowController.open(projectAggregator:)`.
  - **MainWindowView — `Views/Windows/MainWindowView.swift`:**
    - `SidebarTab.projects` (icon `folder.badge.person.crop`) между Library и Goals.
    - Routing в `detailContent` → ProjectsView().
  - **AppDelegate wiring:**
    - `let projectAggregator = ProjectAggregator()` + `configure(modelContainer:)`.
    - `structuredGenerator.projectAggregator = projectAggregator` — eager seed alias row на close.
    - `chatService.projectAggregator = projectAggregator` — listProjects() в send().
    - `mainWindow.open(..., projectAggregator:)` — прокидывает EnvironmentObject.
    - Launch task (15s delay, после embeddings backfill): `backfillProjects(structuredGenerator:)` → `mergeAliases()`.
  - **MetaChat — `Services/Intelligence/ChatService.swift`:**
    - `activeProjects = projectAggregator?.listProjects().prefix(8)` в send() → prompt block `<active_projects>`.
    - Render: `- ChatApp (7 conv, 3 pending, 2 memories, last: 2d ago) · with: Sam, Alex`.
    - System prompt: `<task>` list расширен, `<active_projects>` упомянут в GROUND TRUTH, fallback-empty rule, PROJECTS routing rule усилен («START from <active_projects>»).
    - `buildUserPrompt` signature: `+projects: [ProjectSummary]`.
  - **Files touched:** `Models/Conversation.swift`, `Models/ProjectAlias.swift` (NEW), `Services/Data/HistoryService.swift`, `Services/Intelligence/StructuredGenerator.swift`, `Services/Intelligence/ProjectAggregator.swift` (NEW), `Views/Windows/ProjectsView.swift` (NEW), `Views/Windows/MainWindowView.swift`, `Views/Windows/MainWindowController.swift`, `App/AppDelegate.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (3 pre-existing warnings).
  - **Risks (live-test):**
    - Backfill cost: 100-500 LLM вызовов для юзера с существующей базой. Pro proxy ~$0.25 на 500 convs. Batched sequentially с 300ms паузой → ~5 мин на 500. Не блокирует UI.
    - Merge threshold 0.88: может ложно слить «ChatApp» + «Overmind» (семантически близкие короткие имена). Митигация — manual override в v2 (эта фича не в скоупе).
    - `primaryProject` остаётся raw (не canonical) в `Conversation` — это audit trail. Canonical resolve только на read-path. Если alias row удалят, conversations не потеряются.
- ITER-013 — Action Items с owners (My / Waiting-on split):
  - **Goal:** разделить «что Я должен сделать» от «что мне должны». PM-style, два списка вместо одной кучи. Меняет фундаментальное правило старого extractor'а («только мои таски» — class C+ → SKIP).
  - **Data model — `Models/TaskItem.swift`:** `+var assignee: String?` (Optional → SwiftData lightweight migration). `nil` = MY task, non-empty = WAITING-ON owner. `+var isMyTask: Bool` computed для удобства филтрации в UI.
  - **Prompt rewrite — `Services/Intelligence/TaskExtractor.swift`:**
    - Заменил USER-IS-SUBJECT CHECK на OWNERSHIP CLASSIFICATION (3 класса A/B/C):
      - A — user is subject → assignee = null (MY)
      - B — explicit delegation OR user co-committed in "мы" → assignee = "<Name>" (WAITING-ON)
      - C — bare third-party mention with no link to user → SKIP (drops from output)
    - Добавлены примеры для русского + английского по каждому классу.
    - WORKFLOW обновлён (step 3 теперь classify, step 4 — назначить assignee).
    - JSON schema: `+ "assignee": "<Name>"|null` поле в каждой таске.
    - Parser нормализует assignee: trim + capitalize first letter, "null"/empty/whitespace → nil.
  - **UI — `Views/Windows/TasksView.swift`:**
    - `+var myTasks: [TaskItem]` + `+var waitingOnGroups: [(name, items)]` (groupБy assignee, sort by group size desc, tiebreak alphabetically).
    - Render — две новые секции внутри committed списка: «MY TASKS» сверху, потом «WAITING ON <NAME>» по группам.
    - `ownershipSectionHeader(label:count:)` — компактный uppercase-mono divider с counter chip.
    - Staged bin не трогается, остаётся отдельной REVIEW секцией.
  - **MetaChat — `Services/Intelligence/ChatService.swift`:**
    - `fetchPendingTasksForQuery` теперь возвращает `PendingTaskBundle { myTasks, waitingOn }` вместо `[String]`. Ranking всё ещё единый по relevance — partition в bundle ПОСЛЕ ранкинга, чтобы top-K приходил из самого релевантного среза.
    - Старый блок `<pending_tasks>` разделён на `<my_tasks>` + `<waiting_on>` (с группировкой по имени).
    - `buildUserPrompt` сигнатура обновлена (`tasks: PendingTaskBundle`).
    - System prompt: новое правило «TASKS — MY vs WAITING-ON» с ru/en примерами; GROUND TRUTH RULE и LANGUAGE RULE обновлены ссылаться на 2 новых блока.
  - **Backfill:** не нужен. Existing rows имеют `assignee == nil` → автоматически становятся MY tasks (корректно — старый extractor скипал не-юзер-таски).
  - **Other extractors (ScreenExtractor / RealtimeScreenReactor / CalendarReader):** не меняются. Их источники всегда MY tasks (default `assignee: nil` в TaskItem init).
  - **Files touched:** `Models/TaskItem.swift`, `Services/Intelligence/TaskExtractor.swift`, `Views/Windows/TasksView.swift`, `Services/Intelligence/ChatService.swift`.
  - **Build:** clean (only 3 pre-existing unrelated warnings).
  - **Risks (для live-теста):**
    - LLM может слишком жадно вытаскивать класс B из обычных упоминаний. Жёсткий критерий «explicit delegation OR co-commitment» — митигация в промпте, проверять на реальных диктовках.
    - Aliases: «Вася»/«Sam»/«Сэмалий» → 3 разные секции. Для v1 принято — будем мерджить в ITER-014 через ProjectAlias-style canonicalization.
- ITER-012 — Meeting auto-stop guarantee + per-meeting recap notification:
  - **Symptom (user 2026-04-23):** "созвон сейчас 7 часов записывался и не останавливался автоматически". User wants stop-within-1-min after any call ends + post-meeting summary with next steps.
  - **Root causes (3 layers):** (1) `AppDelegate.handleCallContext` else-branch was a no-op for manually-started recordings — only auto-recorded ones got auto-stopped on call-end transition; (2) call-end signal relies on a window-title transition that never fires when Chrome tab stays open after meeting ends; (3) no upper duration bound — could record indefinitely.
  - **Fix (3-layer defense in depth):**
    - Layer A — `AppDelegate.handleCallContext`: drop the `didAutoStartRecording` gate in the call-ended branch. Now ANY active recording stops within ~1s of the window-title transition. Posts `postMeetingAutoStopped(reason: .callEnded)` notification.
    - Layer B — `MeetingRecorder` silence backstop: new `armSilenceGuard()` watches `audioLevel` via 1Hz Combine timer. After `meetingSilenceStopMinutes` (default 3) of consecutive sub-threshold (`< 0.005` RMS) audio → fires `onAutoStop(.silenceTimeout)`. Catches "browser tab still open after meeting ended".
    - Layer C — `MeetingRecorder` max-duration safety: new `armMaxDurationGuard()` Task sleeps `meetingMaxDurationMinutes * 60` seconds, then fires `onAutoStop(.maxDurationReached)`. Hard cap at user-configurable 30-480 min (default 240 = 4h). Floor 5 min for sanity.
    - All three guards disarm on `stop()` (manual or auto) so a stale timer never fires against a fresh recording.
  - **Per-meeting recap (the "summary + next steps" ask):**
    - `NotificationService.postMeetingRecap(title:overview:taskCount:memoryCount:conversationId:)` — fires after extractors finish. Title: "Meeting recap: <conv.title>". Body: overview prefix(140) + " · X tasks · Y memories". Click → opens Library tab.
    - `AppDelegate.fireMeetingRecap(for:)` — runs ~8s after `conversationGrouper.assign` (gives StructuredGenerator + MemoryExtractor + TaskExtractor time to populate). Counts only committed (non-staged) tasks. Even with empty title/overview sends a minimal "Transcript saved" recap.
    - Click router updated: `NotificationService` checks `userInfo["target"]` and routes recap → `.library`, defaults → `.tasks`.
  - **Settings (3 new):**
    - `meetingMaxDurationMinutes: Double = 240` — slider 30-480.
    - `meetingSilenceStopMinutes: Double = 3` — slider 1-15.
    - `meetingRecapNotifications: Bool = true` — toggle.
    - All in MAIN SETTINGS → Meeting Recording section, gated by `meetingRecordingEnabled`.
  - **Files touched:** `Models/AppSettings.swift`, `Services/Audio/MeetingRecorder.swift`, `Services/System/NotificationService.swift`, `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`.
  - **Build:** clean (3 pre-existing unrelated warnings only).
- MetaChat hallucination fix (system prompt rewrite at `ChatService.swift:167+`):
  - **Symptom (user report 2026-04-23):** AI claimed «Задачу 'Ответить Майку' убрано из списка» when user said "убери ее", then doubled down with «была ранее убрана» when asked to show it. Also failed to resolve "го" after a weather refusal as "try anyway / give your best guess". Net: assistant fabricated actions + ignored ellipsis context.
  - **Root cause (3 holes in the system prompt):** (1) no explicit READ-ONLY contract — LLM treated `<pending_tasks>` as something it could mutate; (2) the "DO NOT use AI's own prior messages as factual references" line was too weak — when AI's past message claimed an action, AI re-read it and treated it as fact in the next turn; (3) "Refine question based on <previous_messages>" rule had no ellipsis examples, so 1-2 word follow-ups like "го" got the "I don't understand" cop-out.
  - **Fix (3 prompt sections):** (a) new `<capabilities>` block enumerates CAN (read/quote/list) vs CANNOT (mutate/create/send/browse/run) and explicitly forbids fake-action claims like "Задача убрана"; (b) new GROUND TRUTH RULE replaces the weak prior-message rule with: "live context blocks win — your past assistant words may be hallucinations or fake-action claims; if a task still appears in current `<pending_tasks>`, you did NOT remove it"; (c) new ELLIPSIS / SHORT FOLLOW-UP RULE with concrete worked examples ("го" after refusal → try best non-live estimate, "да" after offer → fulfill, "и?" → expand last point). Built clean.
  - **Files touched:** `Services/Intelligence/ChatService.swift` (only systemPrompt block).
- ITER-011 — Conversation embeddings shipped:
  - `Models/Conversation.swift` — `+var embedding: Data?` (1536d Float32 from text-embedding-3-small).
  - `Services/Intelligence/EmbeddingService.swift` — new `embedConversationInBackground(_:sourceText:in:)` for fire-and-forget on close + extended `backfillMissing()` to include conversations with `status == "completed"`. Source text built via static `buildConversationEmbeddingSource(for:in:transcriptCharLimit:)` = `title · overview · transcript-prefix(≤1200)`. New generic `backfillPaired(pairs:assign:ctx:kind:)` helper for items whose source text needs DB lookups.
  - `Services/Intelligence/StructuredGenerator.swift` — `+weak var embeddingService: EmbeddingService?`. After title/overview/category/emoji populate, fires `embedConversationInBackground` so the conversation is searchable in MetaChat immediately.
  - `App/AppDelegate.swift` — wires `structuredGenerator.embeddingService = embeddingService` after both configure.
  - `Services/Intelligence/ChatService.swift` — replaced `fetchRecentMeetings(limit:charsPerMeeting:)` with `fetchMeetingsForQuery(queryVector:limit:charsPerMeeting:)`. Strategy: pull last 50 meeting candidates → if query vector exists, rank by cosine on conversation embeddings, take top-K → ALWAYS force-include the literal latest meeting (preserves "transcribe last call"). Fall back to pure recency when no query vector or no embeddings yet.
  - **Net effect:** MetaChat questions like "что я решил про цены?" find the right call even when the transcript said "тарифы" / "pricing" / "стоимость" — bilingual semantic match. "Transcribe my last call" still hits the literal latest because of force-include.
  - **Cost:** one-time backfill ~$0.0005 for 50 conversations; ongoing ~$0.000004 per new meeting close. Effectively free under Pro proxy.
- Phase 5 G1 — Goals system shipped end-to-end:
  - `Models/Goal.swift` (boolean / scale / numeric, with `progressFraction`, `progressLabel`, `resetIfNewDay`).
  - Schema registered in `HistoryService` for both real and in-memory configs.
  - `Views/Windows/GoalsView.swift` — top-level tab with list + editor sheet (3 type-aware fields), checkbox / slider / +/- counter controls, archive + delete via menu, daily reset for boolean/scale at first read of the day.
  - Sidebar: 6→7 tabs (added `.goals` after Library).
  - ChatService: new `<active_goals>` block in user prompt right after `<pending_tasks>`; system prompt updated in 3 places (context list, GOALS handler instruction, "all empty" check).
  - DailySummaryService: `fetchActiveGoals` snapshots feed `energyAgent` (can comment "Behind on writing goal", "Quiet build day, all daily goals done") and `headlineAgent` (only when a goal crosses a meaningful threshold).
- Build green throughout (no new warnings beyond two pre-existing: Swift 6 isolation on `EmbeddingService.dedupThreshold` + deprecated `kIOMasterPortDefault` in LicenseService).

## Current Phase
**Iteration 3: Screen-Aware Intelligence** — дали ChatService / MemoryExtractor / TaskExtractor доступ к ScreenContext OCR (см. spec `iterations/ITER-003-screen-aware-intelligence.md`). Build green, ждёт live-теста: MetaChat "что я читал на экране?" + voice "купи это" глядя на Amazon. Dashboard card "LAST 24H ON SCREEN" сверху StatisticsView.

**Предыдущая (Iteration 2):** Call Auto-Detection — build green, ждёт live-теста на Google Meet.
**Iteration 1:** Memory system + Insights — имплементировано, ждёт live-теста.

## Completed
- [voice-to-text core]: работает стабильно, не трогать — mic → WhisperKit → clipboard
- [FEAT-0001§audio-source]: `AudioSource` протокол, conform `AudioRecordingService`, `TranscriptionCoordinator` принимает `any AudioSource`
- [FEAT-0001§hallucination-filter]: exposed `TranscriptionCoordinator.isAlwaysHallucination` + `isHallucination` + `calculateRMS` как internal static — переиспользуются meeting recording
- [FEAT-0001§meeting-mix]: `MeetingRecorder` микширует mic + system audio, soft-clip, graceful degradation в micOnlyMode
- [FEAT-0002§screen-context]: `ScreenContextService` — ScreenCaptureKit + Apple Vision OCR, SwiftData persistence, blacklist по умолчанию
- [FEAT-0003§advice-core]: `AdviceService` — периодический + trigger на транскрипцию, SwiftData модель `AdviceItem`
- [FEAT-0004§permissions]: `PermissionsService` — `CGRequestScreenCaptureAccess` + `SCShareableContent`, активный триггер TCC
- [build-pipeline]: `build.sh` — единый .app в `~/Applications`, подписан ad-hoc с entitlements
- [insights-ui]: таб "Insights" с секциями Advice / Meetings / Screen Context, dismiss + mark-read
- [realtime-toggle]: Settings toggle → запрос permission → запуск/остановка сервиса без перезапуска app
- [meeting-timer-fix]: заменил `Timer.publish` на `TimelineView` — не ресетится от re-render из-за audioLevel updates
- [permission-ux-fix]: убрал авто-открытие System Settings при permission denial — steals focus и закрывает popover. Теперь error banner кликабельный → пользователь сам открывает Settings. Логи: `[SystemAudio] No Screen Recording permission — requesting...` → `[Permissions] ScreenCaptureKit: The user declined TCCs...` → раньше popover закрывался молча. Теперь остаётся открытым с красным бэннером.
- [appdelegate-shared-fix]: EXTRACT NOW / GENERATE NOW падали с "SwiftUI context issue" — `NSApp.delegate as? AppDelegate` runtime-cast failed (SwiftUI @NSApplicationDelegateAdaptor бриджит через Obj-C protocol, dynamic cast не проходит). Fix: `AppDelegate.shared` weak static, устанавливается в `applicationDidFinishLaunching`. MemoriesView + InsightsView теперь берут ссылку через него. Лог подтверждения в `~/Library/Logs/MetaWhisp.log`: `[InsightsView] ❌ AppDelegate cast failed. NSApp.delegate class = Optional<NSApplicationDelegate>` (до fix).
- [developer-id-signing]: `build.sh` теперь подписывает всё под `Developer ID Application: Alex Dyuzhov (6D6948Z4MW)` вместо ad-hoc. Sparkle nested binaries (XPCServices, Autoupdate, Updater.app, Sparkle) подписываются снизу вверх с `--preserve-metadata=identifier,entitlements,flags` чтобы сохранить `org.sparkle-project.*` identifier. Hardened runtime (`--options runtime`) включён. Fallback на ad-hoc если cert отсутствует (CI). **Эффект:** TeamIdentifier стабилен (6D6948Z4MW) между rebuild'ами → TCC больше не сбрасывается, weekly-reprompt больше не триггерится. **Одноразовая боль:** при переходе с ad-hoc на Developer ID system-wide TCC помнит старый "deny" для Screen Recording → dialog не появляется. Решение один раз: System Settings → Privacy → Screen Recording → добавить через `+`. После этого grant прилип к Developer ID sig, rebuild не сбрасывает.
- [b1-tasks-parity]: Advice→Tasks implemented . Новый `TaskItem` model + `TaskExtractor` service копирует `extract_action_items` (`backend/utils/llm/conversation_processing.py:301`). Trigger: voice transcription ≥20 chars (mirror memory trigger). Prompt: copied verbatim 345-540, удалены sections про Speaker 0/1/2 и CalendarMeetingContext (single-user adaptation). 2-day dedup window, future-only due_at parsing. UI: Insights → Tasks section с checkbox + due badges (TODAY/TOMORROW/OVERDUE). `AdviceService.startPeriodicAdvice` полностью отключён. `AdviceItem` records остаются в БД (138 шт) но скрыты от UI. Build green. Awaiting user verification scenarios (see BACKLOG#B1).
- [ITER-003§screen-aware-intelligence]: дал intelligence-сервисам доступ к screen OCR. **Проблема:** `ScreenContext` пишется каждые 30с (778+ строк) но `ChatService` не читал вообще, `MemoryExtractor`/`TaskExtractor` читали только metadata (appName/windowTitle), не OCR — надиктовал "купи это" → task без контекста. **Изменения:** (1) `ChatService` — `+weak var screenContext`, `+fetchScreenContextLast24h(limit:30, maxCharsPerSnippet:200)` → новый блок `<recent_screen_activity>` в промпте после `<pending_tasks>` (cap ~6KB). System prompt обновлён: "consult <recent_screen_activity>… do NOT invent details OCR doesn't contain". (2) `MemoryExtractor` + `TaskExtractor` — в `buildPrompt` splice `<on_screen_right_now app="" window="">` (≤500 chars, latest snapshot only). Prompts обновлены: "USE ONLY to resolve ambiguous references (this/that). DO NOT extract from screen alone — voice is source of truth". Пример: voice "remind me to order this" + OCR "iPhone 15 Pro Max" → task "Order iPhone 15 Pro Max". (3) `AppDelegate.setupServices` — `chatService.screenContext = screenContext` after configure. (4) `DashboardView` — new `ScreenActivityCard` subview (`@Query<ScreenObservation>` last 24h → group by appName → sum durations → top-5 tiles с durationLabel "3h 12m"). Empty state "No screen activity yet. Enable Screen Context in Settings." **Cost guard:** 30×200=6KB в chat prompt (в пределах 24KB cap); 500 chars в memory/task — почти бесплатно. Privacy: blacklist (Passwords/1Password) уже enforced в `ScreenContextService` → в промпты не попадёт. **Не сделано (отдельные треки):** realtime per-window-change extraction (гэп #3), embeddings (гэп #4), retention (#5), video chunks (#6). **Файлы:** `Services/Intelligence/ChatService.swift`, `Services/Intelligence/MemoryExtractor.swift`, `Services/Intelligence/TaskExtractor.swift`, `App/AppDelegate.swift`, `Views/Windows/DashboardView.swift`. Build green (2.81s). Spec: `specs/iterations/ITER-003-screen-aware-intelligence.md`. Awaiting live verify.
- [ITER-002§arc-meet-fix]: **Baseline ITER-002 shipped to source, user reported "не записываются звонки".** Diagnostic показал 2 RC: (RC1 primary) user запускал старый бинарь Apr 19 22:32 до ITER-002 — нужен `./build.sh`. (RC2) логи раскрыли Arc edge case — Arc window title для Google Meet = **только room code** ("gpq-mmkq-iaz"), без строки "Google Meet" → keyword lookup fails. Reference тоже этот case не ловит. **Fix:** добавил `meetRoomCodeRegex` (`^[a-z]{3}-[a-z]{3,4}-[a-z]{3}$`) как fallback в `SystemAudioCaptureService.detectCallContext` когда app is browser и keyword-match fail. Formato room code стабильный (Google Meet всегда 3-{3,4}-3 lowercase). Build green. Awaiting rebuild + test.
- [ITER-002§call-auto-detection]: auto-detect созвона → нотификейшн → optional 5s auto-start. **Hook:** `ScreenContextService.captureIfChanged` (piggy-back на существующий window-polling loop, у пользователя screen context всегда ON). **Детекция:** `SystemAudioCaptureService.detectCallContext(bundleID:appName:windowTitle:)` — native call apps (Zoom/Teams/FaceTime/Slack/Discord/Webex/GoToMeeting) + browser apps (Chrome/Safari/Arc/Firefox/Edge/Brave/Opera) + title keywords ("Google Meet", "meet.google.com", "Teams - Microsoft", "Zoom Meeting"). **State machine:** `lastCallContext` — callback `onCallContext(name?)` фаерит только на transition (nil→name, name→nil), debounce built-in. **Settings (2 toggles под MEETING RECORDING):** `autoDetectCalls` (existing dead toggle → wired) = показать нотификейшн; `callsAutoStartEnabled` (NEW) = через 5s start recording. **AppDelegate:** `handleCallContext` → `NotificationService.postCallDetected(appName:autoStart:)` + `autoRecordCountdownTask` 5s sleep → `meetingRecorder.start()`. `didAutoStartRecording` флаг отличает auto-record от manual → auto-stop только для auto-record. Skip если уже recording. Countdown cancellable если call ended до 5s. **Файлы:** `Models/AppSettings.swift`, `Services/Audio/SystemAudioCaptureService.swift`, `Services/Screen/ScreenContextService.swift`, `Services/System/NotificationService.swift`, `App/AppDelegate.swift`, `Views/Windows/MainSettingsView.swift`. Build green. Awaiting live test on Google Meet in Chrome.
- [memory-extractor-align]: MemoryExtractor переписан под проверенный pattern. **Trigger:** fires on each voice transcription ≥20 chars (mirror `AdviceService.triggerOnTranscription`), НЕ periodic timer каждые 10 мин. **Input:** voice transcript, screen OCR больше не input для memories (garbage in → garbage out, prompt отвергал UI junk типа "0 clawd / SEO SKILL ~ 口、"). **Prompt:** adapted из — categorization test Q1→Q2, temporal ban ("Thursday"/"next week"), transient verb ban ("is working on"/"is building"), hedging ban, strict dedup with "contradiction is EXCEPTION → extract", mandatory double-check. **Cap:** max 2 memories per extraction. **Dedup window:** все non-dismissed memories (было 20, 1000). **Verify:** diagnostic script `/tmp/mw_test_extractor.py` — на idealfactual transcript ("Я CTO ChatApp, использую Swift strict concurrency") вернул 2 memories с confidence=1.0. На non-factual ("я думаю", "покажи html") вернул [] — корректно. **Files:** `Services/Intelligence/MemoryExtractor.swift`, `Services/System/TranscriptionCoordinator.swift:37-41`, `App/AppDelegate.swift:90-93, 286-289, 382-388`. EXTRACT NOW кнопка теперь extract'ит из последнего transcript в History.

## In Progress
- [FEAT-0001§meeting-recording] (UX polish):
  - DONE: mic+system mix (Services/Audio/MeetingRecorder.swift)
  - DONE: фильтр галлюцинаций (App/AppDelegate.swift § stopMeetingRecording)
  - DONE: RMS < 0.0005 skip, RMS < 0.003 + isHallucination pattern match
  - DONE: waveform indicator во время записи — `MeetingWaveform` в Views/MenuBar/MenuBarView.swift (spec://audio/FEAT-0001#ui-contract.waveform)
  - DONE: Copy/Export/Delete на карточках meetings — `MeetingCardView` в Views/Windows/InsightsView.swift (spec://audio/FEAT-0001#ui-contract.copy-export)
  - DONE: auto-detection созвона → нотификация + optional 5s auto-start (см. [ITER-002§call-auto-detection] в Completed). Ждёт live-теста на Google Meet.

- [FEAT-0002§screen-context] (верификация):
  - DONE: базовый pipeline (capture → OCR → persist)
  - DONE: UI для blacklist/whitelist — `AppPickerView` + `AppPickerRow` + `InstalledApps` в Views/Components/AppPickerView.swift, wired в MainSettingsView `screenContextAppList` (spec://intelligence/FEAT-0002#app-picker)
  - TODO: протестировать в реальности — пользователь включил, но не подтвердил работу
  - TODO: кнопка "Clear all contexts" в Insights

- [FEAT-0003§advice] (верификация):
  - DONE: каркас (трigger на транскрипцию + периодический)
  - DONE: wired `triggerOnTranscription` в `TranscriptionCoordinator` + meeting pipeline (spec://intelligence/FEAT-0003#triggers.transcription) — fire-and-forget, min 20 символов
  - DONE: macOS UserNotifications с click → Insights + markAsRead (spec://intelligence/FEAT-0003#notifications) — NotificationService, rate limit 1/min
  - DONE: Pro proxy — `/api/pro/advice` endpoint (api/src/index.js) + `callProProxy` в AdviceService + убрал warning для Pro в Settings. Pro-юзеры не вводят никаких ключей. Non-Pro — свой OpenAI/Cerebras ключ. Deployed к api.metawhisp.com
  - TODO: реально протестировать в life — advice не сгенерирован ни разу на живых данных
  - TODO: fallback на Apple Foundation Models (macOS 26+) когда нет API ключа

## Deferred Technical Debt

- **Apple Developer signing** (user has account, approved 2026-04-17)
  - Replace ad-hoc signing in `build.sh` → use Developer ID cert
  - Removes TCC permission reset on every rebuild (major UX annoyance)
  - Simplifies notifications (no more UNErrorDomain error 1 issues)
  - When: после завершения текущих итераций, до первого внешнего релиза

## Known Issues
1. **Дубликат "MEETING RECORDING" label** — пользователь сообщил, в коде только один (MenuBarView меню-бар strip). Не воспроизведён, жду скриншот.
   Affects: `Views/MenuBar/MenuBarView.swift` § meetingStrip

2. **Accessibility permission не автодобавляется** — TCC не регистрирует app в Accessibility списке после rebuild. Пользователю надо добавлять вручную через `+` в System Settings.
   Affects: `App/AppDelegate.swift` § setupServices (AXIsProcessTrustedWithOptions)

3. **Mic + main coordinator конфликт** — если meeting recording активно, Right ⌘ не запустит обычную запись (AudioRecordingService.start() в `isRecording=true` state). Не критично, но не задокументировано.
   Affects: `Services/Audio/AudioRecordingService.swift:117`

## Decisions Pending
- spec://audio/FEAT-0001#continuous-mode: включать ли непрерывный meeting mode с авто-сегментацией по VAD?
- spec://intelligence/FEAT-0003#local-llm: интегрировать Apple Foundation Models (требует macOS 26) для local advice без API ключей?
- spec://audio/PROP-0001#ble-wearable: делать ли BLE интеграцию с wearable reference как третий AudioSource?

## Iteration 1 (Memory + Insights) — implemented, ждёт user-теста

Реализовано всё по `specs/iterations/ITER-001.md`:
- `UserMemory` model + `MemoryExtractor` (prompt, strict accept/reject lists, 10-min timer)
- `MemoriesView` отдельным табом в sidebar + toggle `memoriesEnabled` (независимый от advice)
- `AdviceService` переписан : <100 chars, BAD EXAMPLES, `no_advice` escape, memory injection, окно previous advice = 20
- `EXTRACT NOW` / `GENERATE NOW` кнопки для instant-теста
- Backend `/api/pro/advice` — `MAX_PROMPT_LEN` 8000→32000, `maxBalance` 600→1800
- Auto-restart ScreenContext когда permission grant'ится в runtime (applicationDidBecomeActive)

## Что на столе — 3 опции для следующей сессии

1. **Self-signed cert в Keychain** — стабильная подпись между rebuild'ами, TCC permissions больше не сбрасываются (самая большая боль недавней сессии). Пользователь создаёт cert в Keychain Access, build.sh подписывает им.
2. **Live тест GENERATE NOW / EXTRACT NOW** — проверить что советы короткие/конкретные, memories не тривиальные, no_advice срабатывает
3. **Iteration 2: File Indexing** — user picks папки → extract text → write в UserMemory (обогащение personalization)

User предпочитает продуктовые фичи > infrastructure polish, но self-signed cert сэкономит часы в следующих итерациях.

## Session Context
**Start here:** Прочитать `specs/KARPATHY.md` (правила) + `specs/iterations/ITER-001.md` (текущий state реализации).
**User preference:** Karpathy principles, minimal visible changes, no speculation, each feature = verifiable success criteria.
**Recent session pain points:** TCC permissions сбрасывались 4-5 раз из-за ad-hoc signature changes. Apple Developer paid — нет. Self-signed cert — решение (deferred).
**Watch out:**
- НЕ ТРОГАЙ `TranscriptionCoordinator.isAlwaysHallucination` / `isHallucination` — используются meeting recording
- НЕ ЛОМАЙ существующий обычный pipeline (Right ⌘ → mic → clipboard) — основной flow пользователя
- НЕ ДОБАВЛЯЙ sudo в build scripts — блокирует rebuild из-за root-owned файлов
- НЕ городи архитектуру на будущее (Karpathy Simplicity First) — только то что нужно для текущей задачи
