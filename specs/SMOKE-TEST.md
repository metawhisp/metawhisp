# Smoke Test Checklist

**Run before every `swift build` + `bash hot-swap.sh`.**
Live verification of critical user stories. If anything below regresses,
fix before shipping. Add new cases when bugs surface.

Last updated: 2026-05-01

---

## How to use

1. **Static check (free):** `swift build` — compile clean, no errors.
2. **Unit tests (~30s):** `swift test` — all retroactive coverage green.
3. **Live verify (5 min):** walk through Critical Path below in the running
   app. If any step fails — DO NOT push to `~/Applications/MetaWhisp.app`.
4. **Commit smoke result:** "✓ smoke 2026-05-01" in the commit message
   (or session WAL note).

---

## Critical Path — must pass before every ship

### Dictation (the core feature)

- [ ] **D1.** Tap Right ⌘ → speak 5s → release → text auto-pasted into
      active app (Slack/Notion/Cursor — whatever's frontmost).
- [ ] **D2.** Tap Right ⌘ → speak 30s → release → 30s of audio
      transcribes within ~3s, full text pastes correctly.
- [ ] **D3.** Tap Right ⌘ → speak 1s, pause 5s, speak 5s → release →
      no text loss to hallucination filter; full text in clipboard +
      pasted.
- [ ] **D4.** After dictation, manual ⌘V also pastes the same text
      (clipboard verified populated, not silent-failed).

### Voice question (long-press Right ⌘)

- [ ] **V1.** Hold ⌘ ≥0.5s → "What time is it in Belgrade?" →
      release → TTS answer within 5s; popup shows Q + A.
- [ ] **V2.** Multi-turn: while popup open, hold ⌘ → "And in Tokyo?" →
      LLM understands "Tokyo" relative to Belgrade question.
- [ ] **V3.** Esc / auto-dismiss closes popup; next ⌘ long-press starts
      a fresh session (no memory of previous Q).
- [ ] **V4.** Hold ⌘ for 200ms (too short, no audio) → release →
      popup either dismisses cleanly OR shows error — does NOT hang.
- [ ] **V5.** After V4 (failed voice question), short tap Right ⌘ →
      dictation goes to clipboard (NOT into voice popup).
- [ ] **V6.** Hold ⌘ → "what's on my screen?" → answer references the
      current frontmost app's content.

### Projects: curative pass + free-form rename (ITER-032.2)

- [ ] **P-cur1.** First launch after ITER-032.2 hot-swap: log shows
      `[ProjectAggregator] curative pass — first run after upgrade` and
      subsequent `reclassify: N suspect conversations` /
      `recanonicalize: 'X' → 'Y'` / `prune: 'Z'` lines.
- [ ] **P-cur2.** After curative pass, `HallucinatedName`-style hallucinations
      are gone from Projects view (or only visible via `ALL` toggle as
      0-conversation orphans about to be pruned).
- [ ] **P-cur3.** Highest-conv-count variant becomes canonical: e.g.
      a cluster with `Example Project` (24 convs) and `HallucinatedName` (0 convs)
      should now display as `Example Project`.
- [ ] **P-cur4.** `didCurativePass_iter032_2` flag in UserDefaults flips
      to `true` after the pass; second app launch does NOT re-run the
      migration (no `curative pass — first run` log line).
- [ ] **P-cur5.** Free-form rename: ProjectDetailView shows RENAME text
      field below ALIASES. Type any string + click RENAME → canonical
      updates immediately, new name added to aliases list, Library/
      Obsidian rows reflect the new display name on next refresh.
- [ ] **P-cur6.** Rename with empty/whitespace-only input → button is
      disabled, no action.

### Calendar-end auto-stop (ITER-034)

- [ ] **M-ce1.** Calendar event 9:30-10:00, recording auto-starts at 9:30,
      meeting ends at 10:00 (everyone leaves Meet, audio quiet). At
      ~10:01 (60s grace) recording stops automatically. Log shows
      `[CalendarEndStop] fire eventID=… rms=0.000X attempts=0 decision=stopNow`
      and `stopMeetingRecording reason=calendar-end-grace:<eventID>`.
- [ ] **M-ce2.** Calendar event ends but audio still active (overrun,
      e.g. ongoing discussion). At end+60s, MWNotification card pushes
      "Meeting overrunning — Tap to stop now or it will re-check in 5 min".
      Log: `decision=notifyAndExtend(...)`. After 5 min, re-evaluates.
- [ ] **M-ce3.** User taps the overrun card → recording stops with
      reason `calendar-end-overrun-card-tap:<eventID>`.
- [ ] **M-ce4.** Audio active for 3+ extension rounds (15+ min past
      end) → hard-stop fires automatically with reason
      `calendar-end-hard-stop:<eventID>`. Prevents indefinite recording.
- [ ] **M-ce5.** Manual recording (RECORD button) — NO calendar-end
      task armed. Recording continues until user STOP / 2h heartbeat.
      Log shows no `[CalendarEndStop] armed` line.
- [ ] **M-ce6.** All-day calendar event (duration > 6h, e.g. holiday)
      auto-detection triggers — NO end task armed. Log shows
      `[CalendarEndStop] skip arming … treated as all-day`.

### Projects: rename + split + LLM canonical-aware (ITER-032.1)

- [ ] **P-rs1.** ProjectDetailView shows ALIASES section when cluster has
      ≥ 2 variants. Each row: star (filled = canonical), variant text,
      `MAKE CANONICAL` (or `CANONICAL` tag), `SPLIT OUT` button.
- [ ] **P-rs2.** Tap `MAKE CANONICAL` on a non-canonical variant → that
      variant becomes the displayed canonical; star moves; `CANONICAL`
      tag appears next to it. Library row + Obsidian filename for
      conversations stay correct (mapping preserved).
- [ ] **P-rs3.** Tap `SPLIT OUT` on a variant → it's extracted into its
      OWN ProjectAlias row; refresh ALIASES list shows it gone from the
      current cluster. The split-out alias appears in Projects view if
      it accumulates ≥ 2 conversations (or via ALL toggle).
- [ ] **P-rs4.** Tap `SPLIT OUT` on the CURRENT canonical — the cluster
      promotes another variant to canonical first, then splits. No
      orphaned-canonical state.
- [ ] **P-rs5.** LLM canonical awareness: with several conversations
      tagged `Example Project`, recording a NEW conversation that mentions
      `Example Project` (in transcript) → `primaryProject` ends up as
      `Example Project` exactly, NOT a variant like `ExampleProject.ai`,
      `ExampleProjecta`, or new invention. Verifiable via
      `[StructuredGenerator] ✅ ... project=Example Project ...` log line.

### Projects auto-dedup (ITER-032)

- [ ] **P-dd1.** Pre-creation merge: when LLM produces a variant of an
      existing project (case fold `CHATAPP` ↔ `ChatApp`, emoji prefix
      `🚀 ChatApp` ↔ `ChatApp`, single-char typo `Island Expand` ↔
      `Island Expend`, Apple-translit `Голосок` ↔ `Golosok`) — no new
      ProjectAlias row is created; the new variant is appended to the
      existing alias's `aliases` list. Log: `[ProjectAggregator] dedup:
      '<variant>' → '<canonical>'`.
- [ ] **P-dd2.** Distinct projects stay distinct: `CryptoWallet`,
      `ExampleMail`, `API`, `AWS`, `Q3 Planning`, `Q4 Planning`,
      `CryptoWallet 2.0`, `CryptoWallet 3.0`, `ChatApp 2026`,
      `ChatApp` — all preserved as separate aliases. No false merges.
- [ ] **P-dd3.** Display threshold: Projects view by default hides
      aliases with conversationCount < 2. Toggle in header switches
      label between `≥2` (default) and `ALL` (shows singletons).
- [ ] **P-dd4.** App-startup merge pass: legacy duplicate aliases
      (created before ITER-032) auto-collapse on next launch via
      `mergeAliases()` Stage 1 deterministic pass. Log shows
      `deterministic merge: '<winner>' ← '<loser>'` for each.

### Meeting title — calendar event name has priority

- [ ] **M-tt1.** Calendar event named `Daily Sync` → after recording
      stops, conversation in Library shows EXACTLY `Daily Sync`.
      Obsidian file is `YYYY-MM-DD · Daily Sync.md`. Recap popup
      shows the same title. NO LLM-invented theme like "Video Generator
      Finalized" overrides it.
- [ ] **M-tt2.** Manual recording (no calendar event) — LLM-generated title
      is used as before. (Resolver falls back when calendarEventTitle is nil.)

### Meeting recording — back-to-back via calendar eventID (ITER-028.2)

- [ ] **M-bb1.** Two adjacent calendar meetings: A at HH:30-HH:00, B at HH:00-HH:30
      next slot. Auto-start at HH:30, recording continues past HH:00, gate fires
      `.calendarReady(B)` at HH:00 → log shows `back-to-back via eventID: newID=…
      → stop A, immediately fire B countdown`. B records as its own conversation.
- [ ] **M-bb2.** Same calendar event re-emitted (gate ticks) — recording is NOT
      stopped. Log shows no `back-to-back` line for the re-emit.
- [ ] **M-bb3.** Manual recording (RECORD button) is NEVER killed by gate
      transitions, even when calendar events fire while it runs.
- [ ] **M-bb4.** Stop reason is logged on every meeting stop:
      `[MetaWhisp] ▶️ stopMeetingRecording reason=<X>` where X is one of
      `recorder-auto-stop:…`, `user-toggle`, `dictation-end-card-tap`,
      `back-to-back-eventID:…`. No more "unknown stop after 86s" mysteries.

### Meeting recording

- [ ] **M1.** Open Google Meet in browser → wait 30s for ScreenContext
      polling → "Google Meet detected" notification appears → 5s
      countdown → recording auto-starts.
- [ ] **M2.** While recording, Tab to Slack → back to Meet → no
      duplicate "detected" notification (CallSession dedup).
- [ ] **M3.** Stop recording manually mid-call via menu bar → no
      auto-restart while still in Meet (userDeclined honored).
- [ ] **M4.** End real call → window dropped → 180s debounce → recording
      auto-stops, recap popup shows ~8s after.
- [ ] **M5.** Recap title comes from calendar event name (if Cal-linked),
      else LLM summary title. Overview is non-empty (not "(empty)").
- [ ] **M6.** Lid bounce / sleep <10 min → resume continues into
      same Conversation row, not a new one.

### Dashboard

- [ ] **B1.** TODAY card shows non-zero counters when there's real
      activity in last 24h (real-time, not DailySummary cache).
- [ ] **B2.** Drag window edge horizontally → smooth, no per-pixel
      lag (onGeometryChange threshold-only re-render).
- [ ] **B3.** Default window opens at ~1440×1000 first launch.
      Resize sticks across re-opens (`setFrameAutosaveName`).

### Settings

- [ ] **S1.** Settings → Dictation → MICROPHONE picker lists actual
      input devices; selecting one persists across recordings.
- [ ] **S2.** Settings → Hotkeys panel shows 4 rows with TAP/HOLD
      badges — TRANSCRIBE / TRANSLATE / VOICE QUESTION / AUTO-TRANSLATE.
- [ ] **S3.** Settings → OPTIONS → LAUNCH AT LOGIN toggle ON →
      reboot Mac → MetaWhisp auto-launches on login (menu-bar icon
      appears within ~30s). Toggle OFF + reboot → does NOT auto-launch.
- [ ] **S4.** Launch-at-login toggle reflects external changes:
      toggle ON in MetaWhisp Settings → System Settings → General →
      Login Items → uncheck MetaWhisp → return to MetaWhisp Settings
      window (didBecomeActive) → toggle has snapped to OFF, caption
      reads "won't start automatically".

### MetaChat

- [ ] **C1.** Tool-call tags (`<searchMemories>{...}</searchMemories>`)
      do NOT appear in chat — they execute and produce a real answer.
- [ ] **C2.** Voice popup ↔ chat thread isolation: voice questions
      don't leak prior Q&A from old popup sessions into new ones.

---

## Diagnostics on failure

### "Запись пропала" / nothing in clipboard
1. `~/Library/Logs/MetaWhisp.log` — search `[TextInserter]` near time of
   failure. Look for `clipboard write FAILED` (root-cause) vs
   `Auto-pasted via Cmd+V` (succeeded but landed off-target).
2. `Library → History` — text is in DB even if clipboard race lost it.

### Recap "Quick note (empty)"
1. `[StructuredGenerator] Short transcript (0 chars)` in log → cross-context
   race. Should be impossible after `knownTranscript` plumbing.
2. `[StructuredGenerator] Using caller transcript (N chars) — no DB fetch`
   → fix is working.

### Auto-record didn't start on a real call
1. Check `[ScreenContext] Call context changed: Google Meet` log line —
   without it, ScreenContext never noticed (call window wasn't
   frontmost or polling tick missed). NOT a code bug.
2. With it but no `[CallDetect] ▶️ Auto-start` after — check
   `Settings → Integrations → callsAutoStartEnabled`.

### Voice popup hanging
1. `[Coordinator] 🎤 voice question aborted: …` in log → abort path
   working. Popup transitions to `.error` then auto-dismisses.
2. No abort log → bug. Add `abortVoiceQuestionIfActive()` call to the
   missing early-return path.

---

## Pre-build checklist (3-minute version)

For tiny patches that don't touch core flows:

```
[ ] swift build      — green
[ ] swift test       — all green (or accept failures with note)
[ ] manual D1        — 1 dictation works end-to-end
```

For changes touching `TranscriptionCoordinator` / `MeetingRecorder` /
`ChatService` / `TextInsertionService` / `ConversationGrouper` —
run the **full Critical Path** above.
