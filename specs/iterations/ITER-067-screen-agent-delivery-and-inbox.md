# ITER-067 — Persistent delivery and MetaChat Inbox

**Status:** planned.
**Depends on:** ITER-064..066 complete; grounded director proven in shadow.
**User outcome:** a useful comment is never only a six-second popup and never disappears because of DND, stack overflow, restart, or missed click.

## 0. Goal and Definition of Done

Make `ScreenAgentItem` the durable user object, the popup a non-focus-stealing preview, and `MetaChat -> Inbox` the persistent place to review New, Later, and All items. One delivery authority owns final policy and lifecycle truth.

This iteration does not yet implement conversational follow-up or task mutations; those are ITER-068. Popup/Inbox actions may open the item detail and mark Later/dismiss.

## 1. User stories

### US-067-1 — do not lose the comment

As a user, I want to find a comment after its popup disappears or the app restarts.

**Acceptance:** timeout closes only the popup; the same item ID remains in Inbox with source/time and its interaction outcome.

### US-067-2 — no stale backlog after DND

As a user in a meeting or manual pause, I do not want old popups flooding me afterward.

**Acceptance:** DND suppresses presentation at the final check, persists the item/outcome in Inbox, and never replays the stale popup automatically after DND ends.

### US-067-3 — delivery truth

As a user, I want the product to distinguish a generated idea from a comment I actually saw.

**Acceptance:** run, item, presentation outcome, and later interaction are separate records/states.

### US-067-4 — accessible recovery

As a keyboard/VoiceOver user, I want to open the newest Screen Agent item without trying to focus a non-activating popup.

**Acceptance:** the app menu and MetaChat Inbox expose the complete item-detail flow by keyboard and VoiceOver.

## 2. Information architecture

Do not add a new top-level destination.

Inside existing MetaChat add a compact selector:

```text
[ Chat ] [ Inbox ]
```

Inbox filters:

```text
New | Later | All
```

One row shows source label, age/capture time, headline/body, item state, and action receipt when available. Item detail contains safe source summary and placeholders for `Why this?`/conversation/actions completed in ITER-068.

Library/Rewind remains the source-history surface. Workspace remains the confirmed-task surface.

## 3. Delivery authority

Create `ScreenAgentDeliveryService` behind `NotificationService` or make `NotificationService` delegate to it. Do not create two user-visible notification owners.

Flow:

1. Director produces a validated non-silence decision.
2. Persist one `ScreenAgentItem` idempotently by run ID.
3. Create one delivery attempt.
4. Recheck feature, owner scope, visit freshness/deadline, DND, pacing, license/provider state, persistence health, and popup capacity.
5. Persist terminal delivery outcome.
6. Only for `presented`, push an `MWNotification` carrying item/delivery IDs.
7. Persist subsequent interaction separately.

No screen intelligence service may call `MWNotificationStack.push` directly. Meeting/call/sign-in notifications remain outside this scope.

### DND MVP

- manual `Pause Screen Agent`;
- `Pause during recorded meetings`, default on;
- final recheck immediately before presentation;
- no macOS Focus integration yet;
- suppressed item remains visible in Inbox with a safe reason label;
- no automatic catch-up popup.

### Stack capacity

Current popup cap may remain four. If an already presented popup is displaced by a fifth, its delivery remains `presented` and interaction becomes `replaced`. If an item is rejected before presentation because capacity/policy changed, terminal delivery is `suppressed(stackFull)`.

No persistent item is deleted by popup capacity.

## 4. Popup contract

Keep the pure AppKit non-activating implementation to avoid focus theft and the known Tahoe SwiftUI crash.

Compact preview contains:

- MetaWhisp/Screen Agent label;
- source app/window label;
- age of original frame, not card creation time;
- one concrete headline/body;
- click/open affordance and close.

Full multi-action UI lives in Inbox because the non-activating panel cannot provide a reliable complete keyboard workflow. Add app-menu command `Open latest Screen Agent item`.

Timeout:

- visible popup default may remain six seconds during this iteration;
- hover pauses it;
- timeout records `interaction=timedOut`;
- item stays `new` until Inbox/card is opened.

Close is neutral:

- popup closes;
- interaction is `dismissed`;
- no negative feedback reason is inferred;
- item remains in All and may be marked seen.

## 5. Persistence and retention

- Item must be saved before presentation.
- Store failure means no popup and terminal `failed(persistenceFailed)` where recordability permits; never claim success.
- On restart, Inbox reconstructs entirely from SwiftData, not notification closures.
- Normal raw-screen retention may make the full source unavailable; item shows safe summary plus `Source no longer available`.
- `Delete screen history` removes unconfirmed screen-derived items, deliveries, threads, and linked chat rows; confirmed tasks remain with `Source deleted`.
- Legacy `UserMemory(tag=insight)` items are not backfilled into Inbox. Stop creating new ones only when v2 dogfood path is enabled.

## 6. Accessibility contract

- Popup never changes active app/focused control.
- VoiceOver announcement is short: source, headline, `available in MetaWhisp Inbox`.
- App menu command opens newest item without mouse.
- Inbox supports Tab/Shift-Tab/Space/Return/Escape with visible focus rings.
- Buttons have semantic text labels.
- Reduce Motion suppresses optional transitions.
- large text does not truncate the source and primary item body into uselessness.
- timeout cannot destroy an item during VoiceOver review.

## 7. Master checklist — one atomic commit per item

- [ ] **067.1 Delivery state machine persistence.** RED double terminal, generated=presented, persist failure, retry/idempotency; implement item-before-attempt contract.
- [ ] **067.2 One screen delivery authority.** Route director through service; remove v2 direct pushes; retain unrelated notifications.
- [ ] **067.3 DND/final policy recheck.** RED meeting/manual pause/settings/owner/freshness change between queue and show; suppress without catch-up.
- [ ] **067.4 Popup ID bridge.** Carry item/delivery IDs, record presented/opened/dismissed/timedOut/replaced exactly once, preserve focus.
- [ ] **067.5 MetaChat Inbox persistence.** Add Chat/Inbox selector and New/Later/All list/detail; restart and source-expiry states.
- [ ] **067.6 Later and neutral dismiss.** Later changes item state and never auto-backlogs in MVP; close is not negative feedback.
- [ ] **067.7 Stack overflow and failure truth.** Fifth-card/replacement, save failure, popup construction failure, and app quit paths.
- [ ] **067.8 Retention/delete cascade.** Extend `ScreenRetention` and external artifact cleanup for new records without deleting confirmed tasks.
- [ ] **067.9 Keyboard/VoiceOver/Reduce Motion.** App menu route plus complete Inbox flow.
- [ ] **067.10 Named signed-app QA.** Timeout/restart, DND, fifth card, focus theft, menu/VoiceOver, and source deletion.

## 8. Required tests

```text
ScreenAgentDeliveryServiceTests
ScreenAgentDeliveryPersistenceTests
ScreenAgentInboxQueryTests
ScreenAgentPopupInteractionTests
ScreenAgentDNDTests
ScreenRetentionTests
```

Required cases:

1. non-silence run creates one item before delivery;
2. generated but failed persistence cannot present;
3. DND activated after generation but before show suppresses;
4. ending DND does not show the stale suppressed item;
5. timeout leaves same item after restart;
6. close is neutral and distinct from feedback;
7. Later is distinct from dismiss and does not auto-resurface;
8. fifth popup never deletes an item or rewrites generated as presented;
9. duplicate delivery callback cannot create a second terminal/interaction event;
10. delete-all removes unconfirmed items/deliveries/threads and preserves confirmed task;
11. no direct screen-intelligence stack push remains;
12. popup does not activate MetaWhisp or change focused application.

## 9. Live QA

1. Inject one deterministic grounded dogfood item.
2. Let popup time out; open MetaChat -> Inbox; verify identical item/source/time.
3. Restart; verify item persists.
4. Begin delayed run, start a meeting/manual pause before result; no popup, suppressed item in Inbox, no catch-up after pause.
5. Produce five deterministic items; verify capacity and persistent records.
6. Click and close popups; verify distinct opened/dismissed/timedOut states.
7. Keep typing in TextEdit; popup must not steal focus.
8. Use app menu and keyboard only to open latest item; repeat with VoiceOver/Reduce Motion/large text.
9. Delete screen history; verify unconfirmed item/source disappears and confirmed task survives.

## 10. Definition of Done

- [ ] All ten checklist items closed.
- [ ] Screen Agent has one delivery authority and no direct v2 pushes.
- [ ] Every popup maps to one persisted item/delivery ID.
- [ ] Generated, presented, and interaction metrics are separate.
- [ ] Timeout/DND/restart/fifth-card cannot lose a persistent item.
- [ ] No stale catch-up popup after DND.
- [ ] Keyboard/VoiceOver can recover and inspect the item without focusing popup.
- [ ] Retention/delete policy and confirmed-task exception proven.
- [ ] Full build/tests and named live QA recorded before ITER-068.
