# ITER-058: Onboarding hardening — first run that sells the whole product {#root}

> Status: PLAN — awaiting founder OK. Created 2026-07-24.
> Source: full onboarding UX audit 2026-07-24 (code deep-read, every screen mapped
> with file:line refs) + open items inherited from ITER-051 §1/§3 and ITER-053.6.
> All UI copy in this iteration is English-only (founder directive).

---

## 0. Audit verdict {#verdict}

The wizard's skeleton is right (7 pages, real engine-readiness gate before
"Try It") but five failures poison a new user's first minutes:

1. `transcriptionLanguage = "ru"` hardcoded (Models/AppSettings.swift:9), no
   language step → every non-Russian user's FIRST transcript is garbage at the
   exact trust-building moment.
2. Contextless permission race: `setupServices()` fires the macOS mic +
   Accessibility dialogs at launch, on top of the Welcome screen
   (AppDelegate.swift:562, 569-572); the wizard's Permissions page then re-asks,
   its ALLOW is a silent no-op after denial, and the page is un-gated
   (`allGranted` dead code) → a denied user reaches Try It which fails silently.
3. The 950 MB model download is a serial wall: NEXT dead the whole time; a
   swallowed CoreML load failure (AppDelegate.swift:499-519 silent catch) blocks
   the wizard forever next to a ✓-marked model.
4. Flagship features (screen intelligence, second brain, meetings, chat) are
   never mentioned and all default OFF → the user meets "just another dictation
   app" and never learns why we're different.
5. Free-tier copy teaches Translate/Rewrite which silently paste raw text on
   Free with no key — a broken promise right after onboarding.

## 1. User stories {#stories}

- **US1.** As a new non-Russian user, I want my first dictation to come out in
  my language, so the "It works!" moment actually works.
  *Acceptance:* language step in the wizard (Auto default); first Try It
  transcript correct for an English speaker with zero manual setup.
- **US2.** As a new user, I want permission requests to happen when I understand
  why, so I don't deny out of confusion.
  *Acceptance:* zero system dialogs before the wizard's Permissions page; after
  a denial the page shows a working "Open System Settings" path with guidance;
  the page blocks NEXT until the microphone is granted.
- **US3.** As a user on slow Wi-Fi, I want to keep going through the wizard
  while the model downloads, so I don't stare at a dead NEXT button.
  *Acceptance:* download continues in background through Permissions; the
  readiness gate moves to Try It entry; download/load errors are visible with a
  retry, never silently swallowed.
- **US4.** As a new user, I want to learn what makes MetaWhisp different
  (meetings, screen memory, tasks that surface themselves, chat), so I enable
  the flagship instead of never discovering it.
  *Acceptance:* one wizard page presents the flagship honestly (text-not-
  screenshots privacy story) with one-click enable + in-context Screen
  Recording request (ITER-053.6 content).
- **US5.** As a Free user, I want honest labels, so tapping Translate never
  silently pastes untranslated text.
  *Acceptance:* wizard marks Translate/Rewrite as Pro-or-API-key; on Free with
  no key the shortcut surfaces "needs Pro or an API key" instead of raw paste.

## 2. Invariants {#invariants}

- **I1 — No system dialog before its context.** TCC prompts fire only from the
  wizard's Permissions page (or later feature toggles), never at launch while
  `!hasCompletedOnboarding`. Existing users (flag already true) keep today's
  launch behavior.
- **I2 — The wizard can always be finished.** Closing the window must not
  strand the user: reopening path exists; menubar shows "Finish setup" until
  completed.
- **I3 — Engine gate stays honest.** We move WHERE the gate applies (Try It
  entry instead of page-2 NEXT); we never fake readiness (keep
  OnboardingReadiness semantics + its tests).
- **I4 — English-only UI copy** across all onboarding screens.

## 3. Sub-iterations {#plan}

### 058.1 — Language step + kill the "ru" default {#i1}
> **Mechanism:** `"auto"` becomes a first-class value of
> `transcriptionLanguage`. Local path: WhisperKit DecodingOptions.language =
> nil → Whisper's built-in language detection. Cloud path: omit the `language`
> query param on /api/pro/transcribe → Groq Whisper auto-detects. Every call
> site that reads the setting goes through one resolver
> (`resolvedTranscriptionLanguage: String?` — nil means auto) so "auto" can't
> leak as a literal string into an API call.
- [ ] `transcriptionLanguage` default → `"auto"` for FRESH installs only;
      existing users keep their stored value untouched (founder unaffected).
- [ ] Settings picker gains "Auto (detect)" as the first option.
- [ ] Wizard Model page: compact "Language: Auto (recommended) ▾" selector,
      persisted immediately on change.
- [ ] Tests: resolver (auto→nil, "ru"→"ru"), fresh-default vs stored-value
      migration, cloud URL builder omits the param on auto.

### 058.2 — Permission flow done right {#i2}
> **Mechanism:** in `setupServices()` (AppDelegate.swift:556-575) wrap the two
> launch-time requests in `if AppSettings.shared.hasCompletedOnboarding` — new
> users get ZERO system dialogs until the wizard's Permissions page, where the
> same two calls fire from the ALLOW buttons (context first, dialog second).
> Each permission row is a 3-state machine driven by the existing 1 s TCC poll:
> `notAsked` (button ALLOW → fires the system prompt) → `denied` (button
> becomes OPEN SETTINGS → deep-links the exact Privacy pane, inline hint
> "find MetaWhisp in the list → toggle on → come back, this page updates
> itself") → `granted` (✓, row locks).
- [ ] Launch-time requests gated on `hasCompletedOnboarding` (existing users:
      zero behavior change).
- [ ] Permissions page: revive dead `allGranted` (OnboardingPermissionsPage
      .swift:12) — NEXT disabled until **microphone** granted; Accessibility
      encouraged but non-blocking (clipboard fallback exists — say so on the
      page: "without it, text lands in your clipboard instead of typing").
- [ ] Try It gets explicit failure states: `.noSpeech` ("Nothing came through —
      check the mic and try again" + RETRY) and `.error` (message + RETRY);
      the recording aura always resolves (fixes the stuck state at
      OnboardingTryItPage.swift:188-207).
- [ ] Tests: 3-state row machine (pure), NEXT gate, TryIt state resolution on
      empty/error results.

### 058.3 — Instant light model, big model in background — DONE 2026-07-24 {#i3}
> Founder decision 2026-07-24: the fix is NOT "let the wizard scroll past the
> download" — it's "the user must never wait for 950 MB at all".
>
> **Mechanism:**
> 1. The moment the Model page appears (Local tab is default), the app
>    AUTO-STARTS downloading **Base (~80 MB)** — no click needed. On typical
>    Wi-Fi that's 10–30 s; by the time the user reaches Try It it's loaded.
>    (Base, not Tiny: Tiny is English-only quality — our own wizard warns so.)
> 2. Try It runs on Base → first working dictation in under a minute.
> 3. **Large V3 Turbo (950 MB) downloads in the background** — during the rest
>    of the wizard and after it closes. When downloaded AND CoreML-loaded, the
>    engine hot-swaps silently; the menubar popover shows a one-line note
>    "Model upgraded to Large V3 Turbo ✓". Recording in progress → swap waits
>    for idle.
> 4. The Model page shows this as the default plan in plain words:
>    "Quick model now (80 MB) · best model auto-installs in background".
>    Advanced users can still pick a specific model / cloud key / Pro — an
>    explicit pick disables the background upgrade.
- [x] Auto-start Base download on Model page entry; readiness gate satisfied
      by Base (OnboardingReadiness unchanged semantics — a REAL engine).
- [x] Background Large V3 Turbo download + idle hot-swap + upgrade note;
      persisted across relaunch (resume, not restart).
- [x] Surface swallowed load failures (AppDelegate.swift:499-519): error card
      + RETRY; a failed background upgrade keeps Base silently working and
      retries next launch — the user is never blocked by the big model.
- [x] Disk preflight: <2.5 GB free → stay on Base, show "free up space to get
      the best model" note instead of failing.
- [x] Tests: auto-download trigger, upgrade-swap gating (idle only, explicit
      pick disables), failure→Base-keeps-working, resume state machine.

### 058.4 — Flagship discovery page (ITER-053.6 lands here) {#i4}
> **Mechanism:** one new wizard page between Try It and MenuBar, three cards:
> 1. **Screen memory + tasks** — "MetaWhisp reads the TEXT on your screen
>    (never stores screenshots), finds commitments you typed («I'll send it
>    tomorrow»), and reminds you — all on your Mac, 30-day retention,
>    delete-all anytime." Toggle **ON by card button** →
>    `PermissionsService.requestScreenRecording()` fires HERE with context;
>    on grant: `screenContextEnabled = true` + `memoriesEnabled = true`
>    (extraction/promotion pipelines are already default-on downstream).
>    On deny: card shows OPEN SETTINGS, wizard continues.
> 2. **Meetings** — "Record and transcribe calls, get a recap." Button flips
>    `meetingRecordingEnabled + autoDetectCalls = true` (system-audio
>    permission is requested later, on first actual recording — its own
>    context).
> 3. **Chat** — no toggle, just "Ask your Mac what you worked on — ⌘-click
>    the menubar icon" (teaches the surface).
> Everything skippable via "Later in Settings" — nothing force-enabled.
- [ ] Build the page + wiring exactly as above; each card's enable fires its
      permission AT the card, never before.
- [ ] Done page shortcuts recap: add voice-question long-press and meeting
      start/stop; remove taught-but-broken promises (see 058.5 Free honesty).
- [ ] Tests: card enable → toggle+permission wiring (fired once, correct
      order), deny path leaves toggles off.

### 058.5 — Small strands and dead ends {#i5}
- [ ] **Closing the wizard no longer strands.** windowShouldClose → the window
      hides and a "Finish setup…" row appears at the top of the menubar
      popover (visible while `!hasCompletedOnboarding`); clicking it reopens
      the wizard at the saved page (persist `onboardingPage` in AppSettings).
- [ ] **MenuBar page shows the real icon:** render `createMWMenuBarIcon()`
      output (waveform glyph) in the simulated menubar instead of the "MW"
      text badge (AppDelegate.swift:1994-2034 is the source of truth).
- [ ] **No dead air after START:** `complete()` additionally calls
      `openMainWindow(tab: .dashboard)` — respecting the Space rules
      (`.fullScreenAuxiliary` intact, plain `NSApp.activate()`).
- [ ] **Pro activation feedback:** the `metawhisp://auth` deep-link handler
      posts `.proActivated`; the wizard's Pro tab observes it and flips to
      "✓ Pro active — you're all set". Plus a manual "Check activation"
      button that re-runs license verify (FREE-5 from ITER-045).
- [ ] **Free honesty:** Features demo + Done pages label Translate/Rewrite
      "PRO · or your API key"; when a Free user with no key triggers them, the
      pill/popover shows "Translation needs Pro or an API key → Settings"
      instead of silently pasting raw text (ITER-051 §1 P2 close-out).
- [ ] Tests: reopen-at-saved-page, proActivated observer, Free-trigger error
      surface (pure message routing).

## 4. Corner cases {#corners}

Mic denied at OS level before install (MDM) → Permissions page explains, links
Settings · model download interrupted mid-wizard → resumable retry, state
survives relaunch · user closes wizard mid-download → download continues,
"Finish setup" reopens · Pro deep link arrives while wizard is on another page
→ Pro tab shows activated state on return · existing users (flag true) see NO
behavior change at launch · Try It with Accessibility denied → transcript shown
in-wizard with "copied to clipboard" note instead of typing.

## 5. Definition of Done {#dod}

1. Fresh-profile run (new macOS user account): DMG → wizard → first correct
   English dictation in ≤3 min on fast Wi-Fi, zero contextless dialogs.
2. Every failure injected (deny mic, kill network mid-download, bad model load)
   produces a visible, actionable state — no silent dead ends.
3. Flagship page enables screen intelligence with one click incl. permission.
4. All copy English; `swift test` green; adversarial review passed; shipped as
   a Sparkle release (founder + users on the same version).

## Changelog
- [2026-07-24] Plan created from the onboarding audit (screens mapped from
  code with file:line refs; open ITER-051/053.6 items folded in).

## 058.3 review log — shipped as 1.3.20 (2026-07-25)

Six adversarial review rounds (2 internal, 4 Codex `gpt-5.5` high) on top of the
1.3.19 quick-start bootstrap. 11 defects found and fixed; `swift test` 686/686.

| # | Defect | Fix |
|---|---|---|
| 1 | `cancelPlan` didn't cancel a real cloud/Pro switch | plan + in-flight download cancelled at both call sites |
| 2 | Post-await plan re-check ran after the engine already served Large | load first, record reality, then re-check |
| 3 | Corrupt Base still handed the download slot to the 950 MB model | `upgradeAction` gates on `quickModelLoaded` |
| 4 | Mid-swap cloud/Pro race left ~1 GB resident and a lying state | unload the captured engine, clear the loaded id |
| 5 | No RETRY in Settings for a broken ACTIVE model | `isLoadFailure` row → RETRY |
| 6 | Stale swap task spoke for a replaced engine | engine identity verified after every load |
| 7 | Cloud/Pro cancelled only the best model, not a quick-start Base | `ModelBootstrap.shouldCancelDownload` (ownership) |
| 8 | Load failure rode on the download `phase` — hidden by, and erased by, unrelated downloads | dedicated per-model `failedToLoadModelId` |
| 9 | Swap catches set no marker; a failed retry never restored it | marker set in both catches, round-trips through a retry |
| 10 | Marker cleared even when the cleanup delete failed | cleared only once the files are gone |
| 11 | Failed download froze its Settings row; on-disk model unpickable in setup | row falls back to DOWNLOAD; unselected on-disk model offers USE |
