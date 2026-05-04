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
