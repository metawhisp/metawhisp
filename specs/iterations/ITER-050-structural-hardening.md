# ITER-050 — Structural hardening (full-app audit 2026-07-06)

> Source: 5-axis multi-agent audit (windows/focus, error-swallowing, client↔worker
> contract, runtime logs, UI dead-ends), every finding adversarially verified.
> 30 confirmed findings + 6 previously-known open items, grouped into batches so
> the whole thing ships as a structured update, not point-fixes.
> Full machine-readable findings: /tmp/audit-result.json (session artifact).

## Batch 1 — data-loss & trust (P1, do first)

- [ ] **B1.1 ProjectAggregator wipes titles/overviews BEFORE checking LLM access** —
      `Services/Intelligence/ProjectAggregator.swift:553`. Runtime logs show **196
      conversations stripped of title/overview in one pass** when access was down.
      Fix: guard `hasLLMAccess` before touching rows; wipe only after successful
      generation. Investigate restore path for the already-wiped 196.
- [ ] **B1.2 LicenseService.verify() signs out on ANY non-200** —
      `Services/License/LicenseService.swift:139`. A transient worker 5xx logs a
      paying user out (this is the upstream trigger of B1.1 cascade + a lost 40s
      dictation per logs). Fix: sign out only on 401/403; 5xx/429/timeout keep
      cached Pro like the offline branch. Surface real sign-outs visibly.
- [ ] **B1.3 Uncapped transcript → worker 400 → long meetings never get titled** —
      `StructuredGenerator.swift:670` (advice path, 32k limit) and `:807` (proxy
      path; log shows a 78,837-char meeting left permanently untitled). Fix:
      head+tail trim like ChatService's sandwich.
- [ ] **B1.4 Calendar auto-stop uses first-occurrence endDate for recurring events**
      — `App/AppDelegate.swift:2124` — fires ~1s into the meeting; auto-stop is
      effectively disabled for recurring meetings. Fix: resolve today's occurrence.
- [ ] **B1.5 chat-with-tools 502 (core MetaChat broken)** — worker: Cerebras heavy
      model `llama-3.3-70b` = 404 (dead fallback) + Groq `tool_use_failed` on the
      full 9-tool schema. Fix (built, awaiting deploy go): Cerebras heavy →
      `qwen-3-235b-a22b`; retry Groq once on tool_use_failed. Verify with the
      saved repro payload (/tmp/mw-cwt/payload.json).

## Batch 2 — windows & focus (the recurring Space-throw class, structural)

- [ ] **B2.1 Main-window Space-throw (recurred on Tahoe)** — MainWindowController:
      `.moveToActiveSpace`+policy flip → `.canJoinAllSpaces` like the never-throwing
      overlays. Single source-of-truth constant for collectionBehavior used by ALL
      windows + guard test (build fails if any collectionBehavior lacks
      `.fullScreenAuxiliary` or a new `.activate(ignoringOtherApps:)` appears).
- [ ] **B2.2 ClickThroughHostingView `.inVisibleRect` makes the WHOLE invisible
      panel click-opaque** (P1) — `Views/Components/ClickThroughHostingView.swift:92`.
      FloatingVoice + MeetingRecap silently eat clicks/drags in a top-center band.
      Fix: remove `.inVisibleRect` (one word); MeetingCoach already documents this
      exact bug.
- [ ] **B2.3 Overlays visible in screen share** — no `sharingType = .none` anywhere;
      Meeting Coach hints readable by call counterparties. Fix: set on all 5 panels.
- [ ] **B2.4 FloatingVoice local Esc/Space monitor** — swallows Space while TTS
      speaks + Esc app-wide; and Esc-dismiss never works when focus is in another
      app. Fix: global monitor for Esc, guard when a MetaWhisp window is key.
- [ ] **B2.5 Overlays position on NSScreen.main, not the active display** — shared
      screen-under-cursor helper for the 5 position functions.
- [ ] **B2.6 Onboarding: add `isRestorable = false`** (Tahoe restoration-crash class)
      + remove/scope its `NSApp.activate(ignoringOtherApps: true)` (latent mine).
- [ ] **B2.7 Settings scene closes `NSApp.keyWindow` by identity assumption** —
      `App/MetaWhispApp.swift:16`. Resolve the actual hosting window.

## Batch 3 — silent errors / fake success

- [ ] **B3.1 EXTRACT NOW fake success** — `MemoriesView.swift:132`: reports "nothing
      valuable" when extraction FAILED. Check extractor.lastError.
- [ ] **B3.2 FileMemoryExtractor**: `try? ctx.save()` then "added N memories"
      (`:119`) + lastError never cleared → stuck orange error forever (`:114`).
- [ ] **B3.3 Dashboard GENERATE NOW silent no-op** — `DashboardView.swift:435` +
      Pro-gate silence at `:1088`: publish lastError/requiresPro, render it.
- [ ] **B3.4 Local-LLM "Make active" swallows loadModel errors via `try?`** —
      `MainSettingsView.swift:1872`; LocalLLMService.lastError is a dead channel.
- [ ] **B3.5 History delete / Clear All swallow save failures** —
      `HistoryView.swift:167`: rows vanish, resurrect next launch. rollback+error.
- [ ] **B3.6 SystemAudio (known)** — retry ×5 on empty `SCShareableContent.displays`
      + MeetingRecorder sink must forward nil (stuck red banner fix).

## Batch 4 — worker contract & cost

- [ ] **B4.1 Gate context mismatch** — client sends 20k, worker 400s at 8k →
      fail-open fires the heavy call every time (`GateClient.swift:92`). Cap at
      owner layer. Related: **B4.2 gate fail-open on network errors**
      (`GateClient.swift:118`) — fail closed for proactive/reactor (= backlog #39).
- [ ] **B4.3 TextProcessor never sends tier** — the app's most frequent LLM call
      always runs the most expensive default model (`TextProcessor.swift:179`).
      Add tier medium + service_id (direct cost lever).
- [ ] **B4.4 MCP snapshot `.completeFileProtection`** — 110 write failures/day
      while screen locked (`MCPSnapshotService.swift:190`). Use `[.atomic]`.
- [ ] **B4.5 Transcribe prompt query unescaped** — dictionary term with `&`/`+`
      truncates the bias prompt (`CloudWhisperEngine.swift:94`). URLComponents.
- [ ] **B4.6 device_mismatch ignored** — license on another Mac shows as "no active
      subscription" and silently wipes the local key (`LicenseService.swift:233`).
- [ ] **B4.7 Minutes quota not hard-enforced in worker (known)** — used=11530 >
      limit=5400 still transcribes. Design + enforce (separate deploy).

## Batch 5 — UI truth & dead code

- [ ] **B5.1 Weekly Patterns toggle un-gated but generation Pro-only** — tab can
      never fill for non-Pro (`MainSettingsView.swift:2047`). Align both layers.
- [ ] **B5.2 "Pro only" copy on un-gated toggles** (Meeting Coach) — free users get
      a dead overlay; BYOK users wrongly told no access (`MainSettingsView.swift:1249`).
- [ ] **B5.3 Library → Screen empty state can never fill on default install** —
      point to the setting like FilesView does (`RewindView.swift:397`).
- [ ] **B5.4 Menu-bar recording timer restarts at 00:00 when popover reopens** —
      derive from a recordingStartedAt date (`MenuBarView.swift:472`).
- [ ] **B5.5 Five dead view structs** (incl. stale duplicate daily-summary card) —
      delete (`DashboardView.swift:308` + StatComponents + MenuBarView).

## Verification per batch
Each batch: failing test first where testable (B1.1/B1.2/B3.x are unit-testable;
B2.x mostly runtime — user verifies after hot-swap), build + full test suite,
hot-swap, user confirms, atomic commits (one commit per checklist item).

## PROGRESS
- 2026-07-06: audit complete (30 confirmed + 6 known), plan written.
- 2026-07-06 (batch 1): SHIPPED to user's machine (hot-swap, PID 40531) +
  worker deployed. Done: B1.5 (worker: Cerebras heavy → qwen-3-235b-a22b +
  Groq retry on tool_use_failed; live repro 3/3 green), B1.1 (backfill +
  reclassify: hasLLMAccess guard + snapshot/restore via fresh ctx), B1.2
  (sign-out only on 401/403 + SessionVerifyPolicyTests), B2.1 (MWWindowBehavior
  single source of truth + transient join-all-Spaces on main window +
  WindowBehaviorGuardTests), B2.2 (FloatingVoice + MeetingRecap → two-window
  pattern; ClickThroughHostingView + CardFrameKey deleted; height clamps +
  ScrollView cap), B2.4 (global Esc monitor + per-key guards), B2.6
  (onboarding: gentle activate + isRestorable=false; guard allowlist emptied),
  B3.6 (SCK retry ×5 with AUD-008 gen checks + nil-forwarding sink +
  MeetingRecorderErrorRelayTests + recorder give-up stops systemAudio).
  Multi-agent diff review (3 lenses, adversarial): 16 confirmed findings →
  all fixed (unbounded pill height, Esc keyWindow overshoot, sticky
  main window → transient, stale-ctx restore, retry vs gen-cancellation).
  Tests 547/547 green. NOT committed yet — awaiting user's manual test pass.
  Remaining: B1.3, B1.4, B2.3, B2.5, B2.7, B3.1-B3.5, B4.*, B5.*.
