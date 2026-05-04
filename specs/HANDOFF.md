# Session Handoff — 2026-05-03 (latest)

Pick-up document for a fresh Claude session. Read **in this order**:
1. `specs/BOOT.md` → `specs/KARPATHY.md` → `specs/TDD.md` → `specs/WAL.md` → `specs/BACKLOG.md` (mandatory).
2. **`specs/RELEASE-PLAYBOOK.md`** — full release/deploy procedure + token requirements + architecture diagram + lessons learned (NEW 2026-05-03).
3. **`specs/ROADMAP.md`** — Phase 3-7 future direction: voice-everywhere capture, Obsidian as second brain, chat as portal, MCP interop (NEW 2026-05-03).
4. This file for the last-session context.
5. `memory/MEMORY.md` (auto-loaded) for feedback + references — includes the **HARD RULES** below.

---

## Live state at 2026-05-03 handoff

- **Last running PID**: `21010` (after manual `ditto` + relaunch of release-build 1.3.1).
- **Bundle**: `/Applications/MetaWhisp.app` is **v1.3.1 (build 6)**, Apple-notarized release-build, Sparkle-signed. Contains all Phase 1 + Phase 2 ITER-026 v2 fixes (gate, calendar awareness, dictation pause, manual mode, back-to-back, dual-stream merger fix, unified notification stack, calendar-task pipeline removed).
- **DMG distribution**: lives at GitHub Release `v1.3.1` of `metawhisp/metawhisp` repo. `metawhisp.com/downloads/MetaWhisp.dmg` → Cloudflare Page Rule → 302 → GitHub. **Marketing site (Pages) is rolled back to deployment `199df86e` (the safe pre-experiment state with all 13 blog posts).** See RELEASE-PLAYBOOK for the architecture and `specs/WAL.md` 2026-05-02/03 entry for the full release saga (incl. TSA-flake bug fix, near-disaster wipe of 6 blog posts via atomic Pages deploy + recovery).
- **Working tree**: heavily modified, NOT committed. All Phase 2 + ITER-026 v2 + release-related changes are uncommitted on branch `architecture-phase-1-3`. User has been live-testing via hot-swap; commit when stable.
- **Tokens used during 2026-05-03 release session ARE compromised** (appeared in chat logs): 2x GitHub PATs + 4x Cloudflare API tokens. User to revoke.

---

---

## HARD RULES (don't violate)

| Rule | Why |
|---|---|
| **Never run `swift build` / `swift test` / `bash hot-swap.sh` / `bash build.sh` without explicit user ask.** | Cold builds take 5-15 min. User estimated ~90% of session time was burning on builds. Edits-on-disk is the default state. See `memory/feedback_never_build_without_ask.md`. |
| **Always fix root cause, not symptom.** | User screams about this. Don't propose backfills, polls, retries-as-bandaids. Find where the data dies; fix THERE. |
| **Run `specs/SMOKE-TEST.md` before every build.** | 18 critical user stories. Catch regressions before push. |
| **TDD pair-locked with Karpathy.** | Pure-function changes need RED test first, then GREEN. View body / TCC / network are excluded — see TDD.md. Retroactive tests count when batch was unavoidable, but flag the violation honestly. |
| **No external-reference mentions in commits / branches / shipping docs.** | The reference project's name and any `desktop/`-style local clone paths stay out of identifiers, comments that ship, spec text. OK in private session chat. See `memory/feedback_no_external_reference_mentions.md`. |
| **Copy-first methodology.** | Read reference Swift code first; copy structure / prompt / model as-is; adapt only to MetaWhisp constraints; improve only after parity. See `memory/feedback_copy_first_methodology.md`. |
| **Read full instruction files; propose-then-wait-for-OK before acting.** | No skimming. See `memory/feedback_no_shortcuts.md`. |

---

## Live state (previous session — 2026-05-02 marathon, see "2026-05-03 handoff" above for current state)

- **Last running PID** (at the time of 2026-05-02 session end): `47365` (after `bash hot-swap.sh` on 2026-05-02 around 00:15). Long-superseded by 2026-05-03 release-build PID 21010.
- **Bundle**: `/Applications/MetaWhisp.app` (Developer ID signed). Hot-swap chain: `swift build` → `bash hot-swap.sh` (re-signs outer with Developer ID, no TCC reset).
- **DB**: `~/Library/Application Support/MetaWhisp.store` (SwiftData store).
- **Logs**: `~/Library/Logs/MetaWhisp.log` (NSLog).

---

## Just shipped in PID 47365 (full list in WAL section "2026-04-30 / 2026-05-01" — historical)

Big buckets:
- **Mic instance separation** — `meetingMic` is its own `AudioRecordingService`, separate from top-level `recorder`. Fixed three cascading bugs (voice question 950s buffer, mic=0 in meetings, MeetingCoach "Turn on microphone" loop).
- **Voice popup multi-turn boundary** — `VoiceQuestionState.voiceSessionStartedAt` anchors the session; `ChatService.fetchVoiceSessionHistory` filters chat history to the open popup only. Closes popup → next ask is fresh.
- **Voice question screen-aware** — `<current_screen>` block in user prompt with live OCR via `screenContext.captureNow()`. "What's on my screen?" / "fill this form" actually work.
- **Tool XML strip + drift recovery** — `<searchMemories>{...}</searchMemories>` no longer leaks to chat.
- **abortVoiceQuestionIfActive** — popup never gets stuck in `.listening` / `.transcribing` if long-press too short; subsequent dictation goes to clipboard, not voice block.
- **CallSession state machine** — 1 call = 1 notify; user-stopped sessions don't auto-restart; DND of MetaWhisp's own notifications during recording (NEVER touches macOS Focus).
- **dur=0 fix** — `assign(meetingDurationSec:)` back-dates startedAt; recap popup `durationSec >= 60` guard works on real values.
- **Calendar title priority + link-before-LLM** — recap shows the EKEvent name; the linker awaits before the LLM call (no race with the 8s recap delay).
- **StructuredGenerator transcript race fix** — `scheduleOnClose(knownTranscript:)` plumbs the in-memory text past the cross-`ModelContext` race that had caused "Quick note (empty)" placeholders.
- **Recap popup — 5 missing sections rendered** — `WITH (N)`, `DECISIONS (N)`, `NEXT STEPS (N)` added to `Payload` + `MeetingRecapView`. Data was always saved (`participantsJSON` / `decisionsJSON` / `nextStepsJSON`), UI just wasn't reading.
- **Dashboard real-time TODAY counters** + onGeometryChange resize-lag fix (was per-pixel re-render under outer `GeometryReader`).
- **Clipboard verified write + retry** — `writeToClipboardVerified` checks `setString` return + reads back + retries 3×. Catches NSPasteboard ownership race (Universal Clipboard / clipboard managers). New `InsertOutcome` enum exposes `.clipboardFailed` for honest banner.
- **Dictation hallucination filter recovery** — filter discard now saves text to clipboard + lastResult; `containsExcessivePhraseRepetition` moved to silence-only path so real dictations with brief mid-pauses survive. Empty-result branch now surfaces a banner. `saveSamplesAsWav(_:)` writes wav recovery on Cloud HTTP fail.
- **Default window 1440×1000 + setFrameAutosaveName**.
- **MenuBar Variant A redesign** + **FloatingVoiceView Liquid Glass redesign** (mockup `mockups/voice-and-hotkeys.html`).
- **Settings — Hotkey panel 4 rows + TAP/HOLD badges** + **Microphone picker** (`AudioInputCatalog` / CoreAudio enumerator).
- **Retroactive TDD coverage** — fetchHistoryItems (3 tests), saveSamplesAsWav (3 tests), writeToClipboardVerified (4 tests), CallSessionMachine (7 tests), DualStreamMerger (4 tests).
- **`specs/SMOKE-TEST.md`** — 18 critical user stories check-list.

---

## On disk, NOT yet built (next build will pick up)

### Shrek pill — 5th option in `AppSettings.pillStyle`

Mockup at `mockups/shrek-pill.html` (open in browser to preview). State → playback rate / color:

| Stage | Rate | Color |
|---|---|---|
| `.idle` | 0.4× | grey/desat |
| `.recording` | 1.0× | full color |
| `.processing` (transcribing) | 0.35× | red tint (800 ms ease) |
| `.postProcessing` (answered/translating) | 2.0× | back to color |

Files touched:
- `Resources/shrek-pill.mov` — 412 KB HEVC + alpha (transparent BG). Generated from `~/Downloads/shrek-dançando-shrek-meme.gif` via `ffmpeg -c:v hevc_videotoolbox -alpha_quality 1 -tag:v hvc1 -pix_fmt yuva420p`.
- `Package.swift` — `.copy("Resources/shrek-pill.mov")` added to resources.
- `Views/Components/ShrekPillView.swift` (NEW) — `NSViewRepresentable` over `AVPlayerLayer` + `Color.red` overlay with `.blendMode(.sourceAtop)` so red tint hits only the visible Shrek silhouette, not transparent background. `player.rate` driven by stage.
- `Views/Components/RecordingOverlay.swift` — `case "shrek"` in `PillRouterView`; `panelSize` returns `(220, 220)`.
- `Views/Windows/MainSettingsView.swift` — 5th entry in `pillStyles`: `("SHREK", "shrek", "Dancing avatar — tints red while transcribing")`.

Mockup demos: `mockups/voice-and-hotkeys.html` (MenuBar Variant A + Settings hotkey panel) and `mockups/shrek-pill.html` (Shrek pill 4 phases).

---

## Open / next session

1. **DailySummaryService.tasksCompleted always 0** — the field never picks up `TaskItem.completedAt`. Real-time TODAY counter side-stepped this for the dashboard, but DailySummary's narrative agents still see 0. Root cause hunt — separate session.
2. **ScreenContext call-detect latency** — currently 30s polling. Subscribe to `NSWorkspace.didActivateApplicationNotification` for instant detect on app focus change. ~10 lines.
3. **ProjectAggregator clutter** — 52 alias rows; 46 are 1-conv noise (VoiceTool/VoiceTool dup, Island/Island Expand/Island Expend typos, Atomic-zoo). Plan: threshold ≥ 2 conv before showing in Projects view + delete-button per row + Latin/Cyrillic transliteration dedup at alias-creation time.
4. **Phase B chunk overlap** (35s with 5s overlap, dedupe at merge boundary) — original Phase B plan, deprioritized while addressing user pains. Revisit.
5. **Phase C Deepgram streaming WebSocket** — still budget-pending (~$0.0043/min direct Deepgram).
6. **Auto-paste promahnulsa mimo input** — `prev.activate()` + 0.2s + `CGEvent ⌘V` fires into whatever's frontResponder, not necessarily the text field. Real fix path = AX direct insert via `kAXSelectedTextAttribute` (Raycast-style), 80 lines. Mitigation today: clipboard always populated (verified), user can ⌘V manually.

---

## Memories you must respect

`memory/MEMORY.md` index points to:
- `feedback_never_build_without_ask.md`
- `feedback_no_shortcuts.md`
- `feedback_copy_first_methodology.md`
- `feedback_no_external_reference_mentions.md`
- `feedback_run_commands_yourself.md`
- `feedback_dont_jump_to_tcc.md`
- `feedback_hot_swap_signing.md`
- `feedback_tdd_karpathy.md`
- `project_distribution.md`
- `project_iphone_app.md`
- `reference_design_handoff.md`
- `reference_omi_architecture.md`
- `reference_backlog.md`
- `reference_google_stitch.md`

---

## What to do at session start

```
1. Read BOOT / KARPATHY / TDD / WAL / BACKLOG (mandatory).
2. Read this HANDOFF.md.
3. Skim `specs/SMOKE-TEST.md`.
4. If user asks for ANYTHING that needs build → propose plan, wait for OK, never build implicitly.
5. First action when ANY work touches a code file: open the related reference Swift file FIRST.
6. Surface assumptions; don't guess; ask before designing.
```

PID 47365 is the current truth. All edits since the WAL update are on disk only — not in the running app. Most prominent: the **Shrek pill** code listed above. Next build picks them up.
