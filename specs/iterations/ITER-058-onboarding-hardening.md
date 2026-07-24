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
- [ ] `transcriptionLanguage` default → `"auto"` (Whisper auto-detect); expose
      "Auto" in Settings picker (it's absent today).
- [ ] Wizard: compact language selector on the Model page ("Auto (recommended)"
      + common languages), persisted immediately.
- [ ] Migration: existing users KEEP their current stored value; only the
      default for fresh installs changes. Founder's machine unaffected.
- [ ] Tests: default resolution (fresh install → auto), migration no-op for
      stored values, prompt-language plumbing (whatever call sites read the
      setting must accept "auto").

### 058.2 — Permission flow done right {#i2}
- [ ] Remove launch-time mic/AX requests when `!hasCompletedOnboarding`
      (AppDelegate.swift:556-575) — the ITER-051 §1 root-cause fix.
- [ ] Permissions page: gate NEXT on microphone granted (Accessibility strongly
      encouraged, not blocking — clipboard fallback exists); revive dead
      `allGranted` wiring.
- [ ] ALLOW after denial → deep-link to the right Privacy pane + inline
      step-by-step hint ("find MetaWhisp in the list → toggle on → come back");
      live 1s polling already exists, keep it.
- [ ] Try It failure path: error/empty result → visible "Nothing came through —
      check the mic and try again" + retry; never a stuck recording aura
      (OnboardingTryItPage.swift:188-207).
- [ ] Tests: gate logic (pure), denial→guidance state machine.

### 058.3 — Un-wall the model download {#i3}
- [ ] Let the wizard advance during download: engine gate moves from page-2
      NEXT to Try It entry ("Your model is still downloading — N% · ETA" if the
      user gets there first).
- [ ] Surface swallowed load failures (AppDelegate.swift:499-519): error state
      on the model card + retry; NEXT never blocked by an invisible error.
- [ ] Disk-space preflight before download (need ~2× model size free).
- [ ] Tests: gate relocation (readiness at TryIt entry), failure surfacing.

### 058.4 — Flagship discovery page (ITER-053.6 lands here) {#i4}
- [ ] New wizard page after Try It: "MetaWhisp remembers" — meetings recap,
      screen memory, tasks that surface themselves, chat over your history.
      Honest privacy block: "reads TEXT on your screen (no screenshots stored),
      stays on your Mac, N-day retention, delete everything anytime."
- [ ] One-click "Enable screen intelligence" → in-context Screen Recording
      permission request; skippable with "Later in Settings".
- [ ] Done page: add the voice-question long-press + meetings hotkeys to the
      shortcuts recap; drop the untaught-feature dead ends.
- [ ] Tests: enable-path wiring (toggle flips + permission request fired once).

### 058.5 — Small strands and dead ends {#i5}
- [ ] Closing the onboarding window → menubar item shows "Finish setup…" which
      reopens the wizard at the last page (I2).
- [ ] MenuBar page: render the REAL status-item icon (waveform glyph from
      createMWMenuBarIcon), not the fake "MW" badge.
- [ ] After final START: open the main window once on Dashboard so the app
      doesn't vanish (respect the Space-throw rules: `.fullScreenAuxiliary`,
      no `activate(ignoringOtherApps:)`).
- [ ] Pro tab: "Check activation" affordance + success checkmark when the
      metawhisp://auth deep link lands (FREE-5 from ITER-045).
- [ ] Free honesty: Translate/Rewrite labeled "PRO / API key" in the Features
      demo and Done pages; Free-with-no-key shortcut use surfaces an
      actionable error instead of silent raw paste (ITER-051 §1 P2).

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
