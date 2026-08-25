# ITER-072 — Unified activation, onboarding, rollout, and release proof

**Status:** planned.
**Depends on:** ITER-064..071 complete with reports and no open critical privacy/freshness/action defect.
**User outcome:** the user understands what Screen Agent observes, where processing happens, how to control it, and whether it is currently working; the product reaches users only after measured shadow/dogfood proof.

## 0. Goal and Definition of Done

Turn the completed internal architecture into one honest product flow. Consolidate fragmented settings, add optional value-first onboarding and explicit permissions, expose actionable health, migrate existing users without silently broadening capture, and execute `off -> shadow -> dogfood -> beta/live` gates with a signed artifact.

This iteration does not make Screen Agent default-on by developer decision. Product-owner approval is an explicit release input.

## 1. User stories

### US-072-1 — understand the value before permission

As a new user, I want to see a concrete example of Screen Agent help before macOS asks for Screen Recording.

**Acceptance:** onboarding demonstrates a grounded comment and continuation flow, then explains the permission and offers `Enable` or `Not now` without blocking dictation setup.

### US-072-2 — know what leaves the Mac

As a user, I want to know whether text or an image is processed locally or by a cloud model.

**Acceptance:** Settings/onboarding accurately show the active route and separate text-cloud from visual-image consent; copy matches observed runtime traffic.

### US-072-3 — one control center

As a user, I want one Screen Agent settings section instead of guessing how Screen Context, Realtime task detection, Proactive Chip, and AI Advice interact.

**Acceptance:** one master state controls capture/intelligence; advanced settings expose apps, mode, pacing, pause/DND, history, route, health, and deletion with no contradictory toggles.

### US-072-4 — actionable status

As a user, I want to know why Screen Agent is not helping and what to do next.

**Acceptance:** status distinguishes off, permission missing, no allowed apps, paused/DND, model unavailable, quota/provider failure, capture failure, shadow/dogfood, and ready; each actionable state has one next step.

### US-072-5 — safe upgrade

As an existing MetaWhisp user, I do not want an update to start broader screen capture or cloud/visual processing silently.

**Acceptance:** migration preserves the narrowest prior consent; ambiguous legacy combinations remain off and show an upgrade card.

## 2. Final product information architecture

Keep existing top-level navigation. Screen Agent appears in:

- onboarding as an optional capability after core dictation is usable;
- one consolidated `Settings -> Screen Agent` section;
- MetaChat `Chat | Inbox`;
- Library/Rewind as source history;
- Workspace only for confirmed tasks;
- menu bar quick actions: `Open latest`, `Pause/Resume`, and status.

Remove/hide user-facing duplicate terms after migration:

- `Screen Context` becomes an implementation/history concept inside Screen Agent settings;
- `Realtime task detection`, `Proactive Chip`, and screen-scoped `AI Advice` become capabilities governed by Screen Agent rather than independent master switches;
- meeting AI Advice not powered by Screen Agent retains its own accurate scope if still present.

Do not delete legacy stored data or rollback flags during this iteration.

## 3. Unified settings contract

### Primary section

```text
Screen Agent                         [Off / On]
Understands allowed apps and offers grounded help.

Status: Ready — Text processed with <route label>
Apps: 4 allowed                         [Manage]
Help frequency: Balanced                [Change]
Pause during recorded meetings: On
[Open Inbox] [Delete screen history]
```

### Advanced controls

- allowed-app list, never an implicit capture-all empty state;
- text processing route/status and explicit cloud-text consent where applicable;
- separate visual consent and exact image disclosure;
- Quiet/Balanced/Frequent policy explanation;
- manual Pause/Resume and meeting DND;
- screen/OCR retention duration and current storage estimate where existing APIs can prove it;
- health/last successful accepted frame and last run outcome using safe enums/timestamps only;
- `Why am I not seeing suggestions?` diagnostic path;
- delete history with accurate confirmed-task/source-unavailable exception.

Copy must not say `never leaves your Mac` if OCR is sent to a Pro/BYOK/cloud route. Use route-specific truth:

- `Local: screen text is analyzed on this Mac.`
- `Cloud text: text from allowed windows may be sent to <provider/MetaWhisp service>. Screenshots are not sent.`
- `Visual: one downscaled image from the current allowed window may be sent when visual understanding is needed; it is not saved by Screen Agent.`

Provider names and retention statements must come from the actual configured route, not hard-coded marketing assumptions.

## 4. Route and availability contract

Create or finalize one `ScreenAgentLLMRouter` over existing approved capabilities:

- **Local** — uses the supported local/Foundation Models path only when the required structured-output/tool contract is actually available;
- **Pro** — uses the existing authenticated MetaWhisp backend route and quota/health reporting;
- **BYOK** — uses the existing provider/client path only for providers proven to support the required schema/model; never logs the key;
- **Unavailable** — produces a health state and silence, not a fake local fallback.

Routing rules:

- privacy/consent/owner policy runs before provider selection;
- image route is separate and requires visual consent;
- cloud failure never causes a different provider or image send without existing user authorization;
- route/model/prompt/schema version is recorded in `ScreenAgentRun` using non-secret identifiers;
- final evidence/freshness validator is route-independent;
- provider failure or quota exhaustion is visible in health and remains `failed/unavailable`, not presented success;
- changing route cancels in-flight work and increments visit generation/purge epoch as appropriate.

Dogfood may begin with one supported route, but beta/live must honestly gate unsupported configurations rather than expose a broken On state.

## 5. Onboarding flow

Screen Agent onboarding is optional and does not delay the first successful dictation.

### Step A — value demonstration

Use a local, synthetic, privacy-safe example:

```text
You are viewing a pricing page.
MetaWhisp remembers that SSO is required.

Screen Agent:
“The $49 plan on this page does not list SSO, which your launch requirement needs.”
[Why this?] [Ask MetaWhisp]
```

Explain: it normally stays silent, saves useful items to Inbox, and never performs an action without confirmation.

### Step B — choose scope and processing

- choose from currently installed apps with recommended safe categories only as suggestions;
- no `Allow all` default;
- default-excluded password, banking, authentication, Terminal/developer-secret surfaces remain explicit;
- show selected text route disclosure and optional visual consent separately;
- user may continue with text-only or `Not now`.

### Step C — macOS permission

- request Screen Recording only after value/scope explanation;
- show precise System Settings instructions and live permission status;
- permission denial/close/return does not trap the user;
- offer a deterministic local test page/window to prove capture without exposing personal content.

### Existing-user upgrade card

Users with legacy screen features see one non-blocking card explaining the unified Screen Agent. It previews migrated app scope and processing route, requires confirmation for any new cloud/visual capability, and offers `Keep current behavior/off` until rollout cutover.

## 6. Legacy preference migration

Use a one-time, versioned migration with an idempotency test. Preserve the most restrictive interpretation:

| Legacy state | New state |
|---|---|
| Screen capture off | Screen Agent off |
| Screen capture on + explicit non-empty allowlist | Preserve allowlist; Screen Agent remains off until upgrade confirmation unless prior visible agent consent is provable |
| Empty allowlist | Off / needs app selection; never capture all |
| Proactive off | No popup activation; may remain eligible only for approved shadow without private export |
| Proactive on but processing disclosure ambiguous | Upgrade confirmation required before new director delivery |
| No prior image/visual consent | Visual off |
| Legacy task extraction on | No silent task commit in new mode; candidates require confirmation |

Migration never deletes existing history. Rollback restores legacy flag reading only while rollout mode is not live and never re-enables a broader allowlist.

## 7. Status and diagnostics

One observable `ScreenAgentHealth` projects lower-level state into user language:

| State | User message | Primary action |
|---|---|---|
| Off | Screen Agent is off | Turn on |
| Needs setup | Choose allowed apps | Manage apps |
| Permission missing | Screen Recording permission is required | Open System Settings |
| Paused | Paused by you | Resume |
| Meeting DND | Paused during this recording | Open Inbox |
| Model unavailable | Selected AI route is unavailable | Review AI settings |
| Quota/provider failure | Screen Agent cannot analyze right now | Retry/review plan |
| Capture degraded | No recent readable frame | Test capture |
| Shadow/dogfood | Evaluation mode — no/bounded visible help | Learn more |
| Ready | Watching allowed apps; normally stays silent | Open Inbox |

`Ready` does not promise that a suggestion will appear. Diagnostics show safe timestamps/reason codes, never raw screen text.

## 8. Rollout stages and decision gates

### Stage 0 — off/replay

- all 60 catalogued fixtures executable;
- hard privacy/freshness/evidence/action cases pass 100%;
- schema migration and delete-all proven;
- current behavior remains mutually exclusive.

### Stage 1 — shadow

- no items, popups, tasks, memories, or user-visible mutations;
- measure eligible runs, silence reasons, latency, provider failure, and manually reviewed candidate samples;
- zero excluded/no-consent/stale/unknown-evidence candidate accepted by the validator;
- review at least 100 eligible settled contexts across the named scenario matrix before dogfood.

### Stage 2 — internal dogfood

- explicit local cohort and kill switch;
- at least 50 **presented and reviewed** items, not merely generated;
- proposed usefulness target >=80%; unreviewed remains unmeasured;
- zero privacy, stale, ungrounded, wrong-owner, duplicate mutation, or silent task-commit incident;
- p95 accepted-settled-context-to-popup <=10 seconds;
- popup -> Inbox -> same thread succeeds for 100% of presented reviewed items;
- every action attempt has confirmed/cancelled/failed receipt truth.

### Stage 3 — opt-in beta

- Settings/onboarding/migration/accessibility QA complete;
- supported route/platform matrix documented in-app;
- crash-free and provider failure behavior measured for an approved observation window;
- user can disable, purge, and recover permissions without stale delivery;
- owner explicitly approves cohort and support/rollback procedure.

### Stage 4 — live/default decision

- default-on is a separate product decision after opt-in evidence;
- no unresolved P0/P1 privacy/freshness/action/accessibility issue;
- exact signed artifact passes the full matrix;
- public privacy/help copy matches actual network/storage behavior;
- owner records explicit `live`, `opt-in only`, or `hold` decision with date/build/metrics.

Any hard privacy/freshness/owner/action violation immediately returns rollout to off/shadow and invalidates the release candidate. A usefulness miss does not permit relaxing safety gates.

## 9. Master checklist — one atomic commit per item

- [ ] **072.1 Route/health truth.** RED local/Pro/BYOK/unavailable, consent, quota, provider failure, route switch mid-run; implement one route-independent validator and safe health projection.
- [ ] **072.2 Unified preference model.** One master state, apps, text/visual consent, pacing, DND, retention, rollout mode; competing settings no longer own behavior.
- [ ] **072.3 Legacy migration.** RED every table row, rerun/idempotency, downgrade/rollback, empty allowlist, ambiguous cloud consent; preserve narrowest scope.
- [ ] **072.4 Consolidated Settings UI.** Accurate route disclosures, Manage Apps, status/diagnostics, Inbox, retention/delete, Pause, accessibility and narrow width.
- [ ] **072.5 Value-first new-user onboarding.** Synthetic demo -> scope/route -> permission/test; dictation usable first; skip/deny/return paths.
- [ ] **072.6 Existing-user upgrade flow.** Preview migrated behavior, require any new consent, no automatic broader capture/delivery.
- [ ] **072.7 Shadow instrumentation/report.** >=100 named eligible contexts, zero hard-gate acceptance, latency/failure/current-baseline comparison with no private content.
- [ ] **072.8 Internal dogfood gate.** >=50 presented+reviewed, usefulness and hard-zero metrics, end-to-end/action receipts, issue triage, explicit go/hold.
- [ ] **072.9 Opt-in beta and kill-switch drill.** Cohort/health/support/rollback, purge/permission/provider outage, no stale presentation after remote/local off.
- [ ] **072.10 Exact signed release proof.** Full unit/build/static checks plus named Developer-ID-signed app QA, privacy/help copy review, owner approval record.

## 10. Required automated verification

```text
ScreenAgentLLMRouterTests
ScreenAgentHealthTests
ScreenAgentPreferencesTests
ScreenAgentLegacyMigrationTests
ScreenAgentOnboardingStateTests
ScreenAgentSettingsViewModelTests
ScreenAgentRolloutTests
ScreenAgentMetricsPrivacyTests
ScreenAgentFullReplayTests
```

Required cases include:

1. empty allowlist never becomes capture-all;
2. legacy capture/proactive permutations map to the narrowest new state exactly once;
3. text-cloud consent never enables visual/image processing;
4. route switch/revoke/feature off cancels in-flight work before presentation;
5. unavailable/quota/provider failure is visible and never reported as success;
6. onboarding skip/deny/permission return leaves dictation usable;
7. screen permission granted for MetaWhisp does not imply allowed-app or cloud consent;
8. Settings copy/state matches injected Local/Pro/BYOK/Visual runtime route;
9. delete history and kill switch cancel work, purge unconfirmed links, and preserve confirmed task receipts as source unavailable;
10. shadow cannot create item/task/memory/popup under any route;
11. dogfood metrics use presented+reviewed denominator and reject raw content;
12. rollback paths are mutually exclusive and cannot double-run legacy/new agents.

## 11. Full signed-app QA matrix

Run on the exact Developer-ID-signed development/release-candidate app, not only SwiftUI preview or `swift run`:

1. fresh install: dictation first, Screen Agent skip, later Settings enable;
2. fresh install: value demo, app selection, permission denied/granted/return;
3. existing-user migration for each legacy state in section 6;
4. Local/Pro/BYOK supported and unavailable/provider-failure states;
5. text-only versus visual consent and network/storage inspection;
6. Slack -> Figma -> Browser slow response, stable-title content update, two same-app windows, second display;
7. lock/sleep, TCC revoke, app exclusion, owner/license change, delete-all mid-run;
8. DND/Pause/all pacing modes/fifth popup/restart;
9. popup -> Inbox -> same thread -> Why -> explicit recapture;
10. task propose/edit/confirm/double-click/receipt/undo and fulfillment proposal;
11. work-day analysis with excluded/capture-gap intervals;
12. keyboard only, VoiceOver, Reduce Motion, large text, narrow window;
13. kill switch while model/delivery/action is in flight;
14. reinstall/update and rollback rehearsal with stored V3/V4 data.

Record:

- exact app path, build number, commit, code-sign identity/notarization state;
- test counts and named failures/skips;
- replay prompt/schema/model/policy versions;
- current presented/reviewed/helpful/harmful/unmeasured counts;
- latency distribution and hard-zero incidents;
- rollout decision and approver.

Static checks, a successful build, a generated candidate, and a submitted/notarized artifact remain distinct from a live passed flow.

## 12. Definition of Done

- [ ] All ten checklist items closed.
- [ ] One honest Screen Agent settings/health model replaces fragmented controls.
- [ ] New and existing users see value, scope, route, and permission before activation; no new consent is inferred.
- [ ] Local/Pro/BYOK/visual/unavailable runtime behavior and copy agree.
- [ ] All 60 replay fixtures execute; hard safety cases pass 100%.
- [ ] Shadow and dogfood sample/quality/latency/end-to-end gates are met with exact denominators.
- [ ] Zero stale/private/ungrounded/wrong-owner/unconfirmed-mutation incident remains open.
- [ ] Kill switch, purge, permission loss, provider failure, migration, and rollback drills pass.
- [ ] Exact signed app passes the full live matrix and accessibility review.
- [ ] Product owner explicitly records `live`, `opt-in only`, or `hold`; no implicit default-on release.
