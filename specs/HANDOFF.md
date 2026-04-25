# Session Handoff — 2026-04-19

Pick-up document for a fresh Claude session. Read **in this order**:
1. `specs/BOOT.md` → `specs/KARPATHY.md` → `specs/WAL.md` → `specs/BACKLOG.md` (mandatory, do NOT shortcut).
2. This file for recent-session context.
3. `memory/MEMORY.md` (auto-loaded) for feedback + references.

---

## Current state (what shipped)

**Phase 0 — Foundation** ✅ deployed
- Memory extraction: voice-trigger prompt, robust JSON parser.
- Developer ID signing (Andrey Dyuzhov, team `6D6948Z4MW`). Stable TCC between rebuilds.
- `AppDelegate.shared` weak static fix.

**Phase 1 — Conversations as root** ✅ deployed
- `Conversation` SwiftData entity, `ConversationGrouper` (10-min silence, meetings single-shot).
- `StructuredGenerator` → title/overview/category/icon on close. Monochrome SF Symbols (diverged color emoji).
- `conversationId` FK across HistoryItem / UserMemory / TaskItem / ScreenContext.
- `ConversationsView` with date grouping, filter chips ALL/STARRED/MEETINGS/DICTATIONS, inline expand.

**Phase 2 — Screen pipeline (Rewind)** ✅ deployed
- `ScreenObservation` model. `ScreenExtractor` hourly batches visits → observations + memories + tasks in one LLM call.
- `screenContextId` FK on UserMemory and TaskItem.
- `RewindView` (now "SCREEN" in Library) with date grouping + search + filter chips + click-expand OCR.

**Phase 3 — External readers** ✅ deployed (E1/E2/E3), E4/E5 deferred
- E1 File Indexing: `FileIndexerService` + `FileMemoryExtractor` for user-picked folders (Obsidian vault etc.).
- E2 Apple Notes: `AppleNotesReaderService` via AppleScript (diverged 's SQLite GRDB — Automation permission instead of Full Disk Access).
- E3 Calendar: `CalendarReaderService` via EventKit (diverged 's browser-cookie scraping).
- E4 Gmail / E5 unified runner — **deferred per user decision**.

**Sidebar reorg** ✅ deployed
- 9 tabs → 6: Dashboard / Library / Tasks / MetaChat / Dictionary / Settings.
- Library hub has segmented sections: Conversations / Screen / Files / Memories / History.
- MetaChat (user-named) with RAG + 3-dot typing animation + Meetings filter chip.

**Phase 6 — Voice questions + TTS** ✅ deployed (MVP)
- `TTSService` via AVSpeechSynthesizer (premium cloud TTS in Phase 6+).
- `HotkeyService` Right ⌘ tap/long-press split: tap < 0.4s = dictation as before; long-press ≥ 500ms = voice question.
- `TranscriptionCoordinator.voiceQuestionMode` routes finalText to ChatService instead of clipboard.
- `ChatService.send(text, source:)` with `.typed`/`.voice`. Speaks AI reply via TTS per toggles.
- `VoiceQuestionState` (ObservableObject singleton) — phase state machine: idle / listening / transcribing / thinking / answered / error.
- `FloatingVoiceWindowController` — borderless floating NSPanel at top-center.
- `FloatingVoiceView` — redesigned: rounded 14pt, METACHAT brand, phase-specific animated icons (SF Symbol `.symbolEffect`), pulsing ring for LISTENING, speech bubble blocks for YOU/METACHAT, drop shadow, auto-size.
- **Stop controls:** STOP button (visible while speaking), Space to silence without closing, Esc to close + silence.
- `RecordingOverlayController` — suppresses dictation pill when `VoiceQuestionState.isVisible` (no UI stacking).

---

## Testing pending (user-side verify still needed)

- [ ] B1 Tasks — explicit/vague/dedup 3-scenario flow
- [x] B2 MetaChat — verified by user 2026-04-19 (8 ChatMessage rows)
- [ ] C1.1 Conversation grouping (3 dictations < 5 min → 1 conversation)
- [ ] C1.2 Structured generation (title/overview/category/icon after close)
- [ ] C1.3 FK wiring (new UserMemory/TaskItem carry conversationId)
- [ ] C1.4 Conversations tab UI + Meetings filter
- [ ] R1 observations (after 1h of screen activity)
- [ ] R2 auto-memories/tasks from screen
- [ ] R3 Rewind/Screen tab UI
- [ ] E1 File indexing (pick Obsidian vault, verify memories appear)
- [ ] E2 Apple Notes (Automation permission flow)
- [ ] E3 Calendar (EventKit permission flow, pattern memories)
- [ ] Phase 6 voice questions end-to-end (hold Right ⌘, speak, TTS answer)
- [ ] Phase 6 UI redesign + stop controls

---

## Git + PR state

**Local branch:** `architecture-phase-1-3` — diverged from `main` with everything above.
**Last commit:** `f2247a0` "Add Conversations/Tasks/Screen/MetaChat + readers" (68 files, 11,129+ lines).
**Push state:** pushed to `origin/architecture-phase-1-3`.
**PR state:** **NOT created yet** — both gh accounts on this machine failed "must be a collaborator" on `MetaWhisp/MetaWhisp`. User must open PR manually:

> https://github.com/MetaWhisp/MetaWhisp/compare/main...architecture-phase-1-3?quick_pull=1

**Subsequent Phase 6 + UI redesign + stop controls** are LOCAL only — not yet committed. New session should:
1. Run `git status` to see pending Phase 6 changes.
2. Commit them to same branch (`architecture-phase-1-3`) as a follow-up commit.
3. Push (`git push`).

---

## ⚠️ Security — rotate secrets

During initial PR attempt, `how-to-build/README.md` was staged containing **LIVE credentials**:
- Stripe `sk_live_51SHA7REAhf4KFEHq...` + `pk_live_51SHA7REAhf4KFEHq...`
- Resend `re_ZLZfYhah_...`
- Cloudflare DNS token

Push was blocked by GitHub secret scanning — credentials did NOT reach the remote. File was removed via `git rm --cached` + amend + added to `.gitignore`. GitHub still logged the attempt (webhook → provider notification likely).

**User must rotate ASAP:**
- Stripe (both live keys) → https://dashboard.stripe.com/apikeys
- Resend → https://resend.com/api-keys
- Cloudflare DNS Edit token → https://dash.cloudflare.com/profile/api-tokens

The local `how-to-build/README.md` on disk is now gitignored but still contains the plain-text credentials. Move to 1Password / external secure storage when user has time.

---

## User preferences picked up this session

- **Methodology:** copy-first , never invent, never shortcut instructions. Saved as `memory/feedback_no_shortcuts.md` + `memory/feedback_copy_first_methodology.md`.
- **UI aesthetic:** monochrome SF Symbols only, no color Unicode emoji. Minimal desktop design.
- **Branding:** "MetaChat" is the product name for the chat feature.
- **Screen reorg priority:** unified Library hub; Tasks promoted top-level; Dictionary left alone.
- **Voice hotkey:** Right ⌘ long-press only (no left ⌘).
- **Voice question flow:** auto-send after release (no typed confirmation step).
- **Premium voice:** deferred — AVSpeechSynthesizer MVP is fine, premium "Sloane" voice can wait.

---

## Recommended next track

Per BACKLOG, next by-phase order:
1. **Phase 4 — Knowledge Graph (Brain Map)** — entity extraction across memories → nodes/edges → force-directed visualization. Matches Memories tab screenshot.
2. **Phase 5 — Task richness** — priority / tags / recurrence / indent (all fields already in `ActionItemRecord`, missing from ours).
3. **Phase 6+ follow-ups** — premium TTS (OpenAI cloud voice, Pro-proxy endpoint), research more voice-communication features (streaming transcription, wake-word, voice commands).
4. **Phase 7 — Daily Summary** at scheduled time (10PM recap).

User may also want to test/verify accumulated testing-pending items instead of continuing forward.

---

## Quick commands for new session

```bash
cd /Users/android/Code/MetaWhisp
git status                                   # see Phase 6 uncommitted work
git log --oneline -5                         # last 5 commits
swift build                                  # quick compile check
./build.sh                                   # production build + install + launch
tail -f ~/Library/Logs/MetaWhisp.log         # watch logs live

# Verify key DB state:
sqlite3 ~/Library/Application\ Support/MetaWhisp.store \
  "SELECT ZSTATUS, ZSOURCE, ZTITLE FROM ZCONVERSATION ORDER BY ZSTARTEDAT DESC LIMIT 5;"
sqlite3 ~/Library/Application\ Support/MetaWhisp.store \
  "SELECT ZCONTENT, ZSOURCEAPP FROM ZUSERMEMORY WHERE ZISDISMISSED=0 ORDER BY ZCREATEDAT DESC LIMIT 10;"
```

---

## Files most likely to be referenced next

Architecture references:
- `specs/BACKLOG.md` — full 9-phase roadmap with feature inventory
- `specs/KARPATHY.md` — process discipline rules

Recently-shipped code you'll want to revisit:
- `Services/TTS/TTSService.swift` (Phase 6 — premium TTS swap point)
- `Services/UI/VoiceQuestionState.swift` (state machine for floating voice panel)
- `Views/FloatingVoice/FloatingVoiceView.swift` (UI redesign — reference for future floating UIs)
- `Services/Intelligence/ChatService.swift` (RAG implementation + source-based TTS routing)
- `Services/Indexing/` — four readers (File / FileMemory / AppleNotes / Calendar) all follow similar pattern

