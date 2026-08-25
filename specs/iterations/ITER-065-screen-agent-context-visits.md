# ITER-065 — Context visits, focused capture, privacy, and freshness

**Status:** planned.
**Depends on:** ITER-064 complete and reviewed.
**User outcome:** Screen Agent can no longer confuse an old/wrong window with the context it is about to analyze.

## 0. Goal and Definition of Done

Make one authoritative, cancellable `ContextVisit` stream from the exact focused window. Detect meaningful content changes even when the title stays stable, ignore cosmetic title noise, and guarantee newest-value processing with a hard freshness deadline.

The iteration is done when rapid switching, stable-title changes, multi-display focus, capture failure, permission loss, feature-off, purge, and persistence failure cannot result in an old frame entering or completing an agent run.

## 1. User stories

### US-065-1 — current screen only

As a user, I want a comment to refer only to the exact window I am still viewing.

**Acceptance:** switching A -> B -> C while A is slow can produce only a C item; A/B finish as `staleVisit` or cancellation.

### US-065-2 — stable title content

As a user, I want new Slack messages, form errors, and page content noticed even when the app and window title do not change.

**Acceptance:** a meaningful same-window content hash change increments the visit generation and can enqueue the newest frame; unchanged content does not rerun OCR/model work.

### US-065-3 — privacy fails closed

As a user, I want an empty allowlist, excluded app, revoked permission, screen lock, or disabled toggle to mean no capture and no pending delivery.

**Acceptance:** no ScreenContext, model request, item, or popup occurs in those states.

### US-065-4 — exact focused window

As a multi-monitor user, I want MetaWhisp to analyze the focused window, not the first display or another window of the same app.

**Acceptance:** focused display/window identifiers and source label match the active AX window in the named live test.

## 2. Architecture boundary

Keep `ScreenContextService` as the public facade and owner of existing call-detection behavior. Extract new concerns instead of rewriting the class wholesale:

```text
ScreenContextService
  -> ScreenAgentPrivacyPolicy
  -> FocusedWindowCaptureWorker (non-MainActor capture/OCR)
  -> ContextVisitCoordinator (pure identity/generation state machine)
  -> ScreenAgentRunQueue (one active + newest pending)
```

`captureNow()` for voice questions remains supported and must obey the same privacy/focused-window policy, but it does not silently join or replace a notification's frozen context.

## 3. Starting timing policy

Put values in one tested `ScreenAgentTimingPolicy`, not magic numbers spread across services:

- identity settle/dwell: 750 ms after a focus/content event;
- same-window safety probe: 3 seconds while Screen Agent is active;
- history persistence interval may remain separately configurable;
- end-to-end settled-context -> presentation deadline: 10 seconds;
- one active run plus one newest pending token; a newer pending token replaces the older pending token.

These are proposed product targets, not measured current performance. Record baseline and change them only through replay/live evidence.

## 4. Focused capture contract

### Identity

One visit identity uses:

- owner scope;
- front app bundle ID;
- authoritative focused window ID when available;
- normalized title for fallback identity;
- focused display ID;
- visit start/gap policy.

`WindowTitleNormalizer` must be called by production identity code. Cosmetic spinner/timer/unread changes do not create a visit.

### Same-window change

Capture a small focused-window image for a local content fingerprint. If its meaningful hash is unchanged, do not run Vision OCR or persist another frame. If changed, increment visit generation and capture OCR.

Do not treat every animation/cursor blink as a meaningful change. The hash/difference threshold must be pure and fixture-tested. Prefer false negatives to continuous reruns until measured.

### Window selection

Extend `ActiveAppCaptureFilter` to select one `SCWindow` matching the front PID and focused AX window/bounds. Use the display containing that window, not `content.displays.first`. If identity is ambiguous, return a capture outcome and stay silent rather than OCR all front-app windows.

### OCR

- Run ScreenCaptureKit and Vision work outside `MainActor` behind an actor/worker.
- Retain `VNRecognizedTextObservation` bounds as local Codable OCR blocks.
- Continue producing flat text for legacy consumers.
- Keep the current downscaled frame in a bounded in-memory cache only; V4 has no image field.
- Capture/OCR failure is a typed outcome. Do not create an empty persisted context as a substitute for success.

### Persistence

- Pre-create frame ID if useful, but fire the accepted-frame callback only after `ModelContext.save()` succeeds.
- Link accepted frame IDs from `ContextVisit.frameIDsJSON`.
- A failed save produces `persistenceFailed` and no agent run.
- Purge and feature-off bump a shared generation/cancellation token before deletion/stop.

## 5. Privacy/settings policy

Change `ScreenContextPolicy.resolve`:

- whitelist mode + empty list = empty allowlist, capture nothing;
- hard denylist (password managers, banking/authentication and system secret surfaces) always wins;
- high-risk developer surfaces such as Terminal are excluded by default and require an explicit per-app opt-in; that opt-in does not imply cloud-text or visual-image consent;
- screen master off cancels capture, queued work, and tool access;
- allowed local history and allowed cloud analysis are separate decisions; no cloud request is authorized in this iteration.

Do not silently migrate a legacy empty whitelist to broad consent. Existing users land in `setupRequired` until they choose apps.

## 6. Master checklist — one atomic commit per item

- [ ] **065.1 Pure visit state machine.** RED A/B/C, normalized-title noise, window close, owner change; implement ContextVisit ID/generation/invalidation.
- [ ] **065.2 Fail-closed policy.** Flip the existing unsafe empty-whitelist test; add sensitive/default and feature-off matrix.
- [ ] **065.3 Focused window/display selection.** RED second-display/two-window/ambiguous cases; extend `ActiveAppCaptureFilter` without invoking ScreenCaptureKit in tests.
- [ ] **065.4 Content fingerprint and settle policy.** RED same-title changed content, unchanged frame, spinner/cursor noise; implement pure threshold and debounce.
- [ ] **065.5 Off-main capture/OCR worker.** Preserve flat OCR output, add bounds, typed outcomes, and memory-only image cache.
- [ ] **065.6 Save-before-callback and retention links.** RED failed save/no callback, purge in flight, bounded frame IDs.
- [ ] **065.7 Latest-value queue and deadline.** RED A -> B -> C, slow run, timeout, disable/purge; implement one active plus newest pending and rechecks after every await.
- [ ] **065.8 Production wiring.** Replace sequential reactor-then-proactive callback with one accepted-frame coordinator. Keep v2 mode `shadow`; do not change user-visible decisions yet.
- [ ] **065.9 Named signed-app live matrix.** Focused window on display 1/2, same-title change, rapid switch, close, permission revoke, sleep/wake, empty allowlist.

## 7. Required tests

```text
Tests/MetaWhispTests/Services/Screen/ContextVisitCoordinatorTests.swift
Tests/MetaWhispTests/Services/Screen/ScreenAgentTimingPolicyTests.swift
Tests/MetaWhispTests/Services/Screen/ScreenContentFingerprintTests.swift
Tests/MetaWhispTests/Services/Screen/ScreenContextPolicyTests.swift
Tests/MetaWhispTests/Services/Screen/ActiveAppCaptureFilterTests.swift
Tests/MetaWhispTests/Services/Screen/ScreenContextPersistenceTests.swift
Tests/MetaWhispTests/Services/Intelligence/ScreenAgentRunQueueTests.swift
```

Required assertions:

1. A/B/C delivers no A/B accepted token after C becomes current.
2. Same app/title with meaningful new content increments generation.
3. Cosmetic normalized-title change plus unchanged hash does not enqueue.
4. Display 2 focused window is selected; another same-app window is excluded.
5. Ambiguous/no focused window returns a failure state, not full-display OCR.
6. Empty whitelist never reaches capture.
7. Save failure never calls the agent callback.
8. Screenshot/OCR failure never reuses the previous frame.
9. Deadline expiry never creates a late pending item.
10. screen off, purge, lock, permission revoke, or owner change cancel active and pending tokens.

## 8. Live QA

Use a named Developer-ID-signed dev app so TCC behavior is real. Do not run `build.sh` or replace the installed app without the normal project approval/runbook.

1. Allow only TextEdit and a browser test page.
2. Verify the status/source on display 1 and display 2.
3. Change text in a stable-title TextEdit/browser window; observe a new accepted generation.
4. Leave the frame unchanged through multiple probes; observe no new OCR/run.
5. Switch Slack/TextEdit/browser rapidly while a test run is delayed; no old item may appear.
6. Close the source window during the delay; old work is cancelled.
7. Revoke Screen Recording, sleep/wake, and clear allowlist; no capture/model request occurs.
8. Simulate or inject a save failure through a test seam; callback stays absent.

Logs/metrics may show IDs, generation, timings, capture outcome, and reason codes only. They must not show OCR, titles containing private content, or image data.

## 9. Regression boundaries

- Call auto-detection still reacts quickly and is not tied to OCR success.
- Voice `captureNow` obeys privacy and continues to answer current-screen questions when explicitly used.
- Dictation, meeting recording, layout fixer, task extraction, and existing notifications behave unchanged in `off` mode.
- Screen history delete still fences every old capture.

## 10. Definition of Done

- [ ] All nine checklist items closed with RED/GREEN evidence.
- [ ] Replay hard freshness/privacy cases pass 100%.
- [ ] `WindowTitleNormalizer` has a production caller.
- [ ] Focused window/display and same-title changes are proven in tests and signed app.
- [ ] OCR/capture no longer performs its heavy work on `MainActor`.
- [ ] Empty whitelist is fail-closed and legacy users are not silently broadened.
- [ ] Accepted-frame callback happens only after successful persistence.
- [ ] One active + newest pending queue and 10-second deadline are enforced.
- [ ] User-visible v2 delivery remains shadow/off; no prompt tuning occurred.
- [ ] Full build/test counts and live artifact recorded before ITER-066.
