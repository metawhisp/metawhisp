# ITER-042 — People ↔ Workspace structuring for MetaChat {#root}

> Real company/person names are **redacted** per repo policy (open-source).
> Placeholders: `CompanyA`, `CompanyB`, `PersonX`, `PersonY`, `Self` (= the app's owner/user).

## 0. Invariants (read first — these win over everything below) {#invariants}

- **INV-1 — No unfounded company binding.** Never state a person belongs to a
  company/workspace they were not *observed under*. Unknown company → say so.
- **INV-2 — No cross-workspace merge.** Never merge people from different
  workspaces into one roster/relationship. `PersonX@CompanyA` and
  `PersonY@CompanyB` are never presented as the same group.
- **INV-3 — Self is not an employee (best-effort, NOT absolute).** Never list the
  user (`Self`) as a colleague/employee. ⚠️ Enforceability check (2026-05-30): the
  app exposes `LicenseService.email` but has **no user-name field anywhere**. So
  self-exclusion is *exact* only after the user supplies name variants in a NEW
  settings field (042.2 adds it); without it, exclusion is best-effort from the
  email local-part. Do not promise absolute self-exclusion from existing data.
- **INV-4 — No invented names.** Only name people present in the observed data.
  No fabricated names, no fabricated actions between people ("X added Y").
- **INV-5 — Workspace dictionary is data-driven, never hardcoded.** The set of
  known workspaces is built **at runtime** from the user's own project catalog
  (`ZPROJECTALIAS` / `ExistingProjectCatalog`). No company name is ever written
  into source, tests, or this spec (privacy / open-source rule).
- **INV-6 — Feedback-loop + system-chrome OCR is noise (graded, not blanket).**
  HARD-deny only: the app's **own window** (`MetaWhisp`) and system chrome
  (`loginwindow`, `Finder`, `System Settings`, `Preview`, `Xcode`). ⚠️ Reality
  check (2026-05-30): AI tools are huge in the store — `Claude` 2920, `ChatGPT
  Atlas` 717, `ChatGPT` 211 OCR rows — and contain *real* people-discussion as
  well as echoes. Hard-denying them loses signal, so they are **low-trust**
  (kept, down-ranked, source-labelled), NOT denied. The pure self-echo for the
  screenshot people was only ~8 `MetaWhisp` rows — the feedback loop is real but
  small; it is NOT the main driver (see §1.1.3).

## 1. Problem {#problem}

MetaChat mixes people from different companies into one answer and invents
relationships. Reproduction (user screenshot, 2026-05-30): the chat listed one
person from `CompanyA` together with five people from `CompanyB` as if one group,
then emitted a circular non-fact ("X added Y / Y was added by X"), and listed
`Self` as if an employee.

### 1.1. Root cause — verified against the production store {#problem.root}

Direct SwiftData queries (`~/Library/Application Support/MetaWhisp.store`) on
2026-05-30:

1. **People live in screen OCR, not in meetings.** The screenshot's people have
   **0** hits in `ZCONVERSATION` (participants / overview / title) and **0** in
   `ZUSERMEMORY` content. They appear only in `ZSCREENCONTEXT.ZOCRTEXT` —
   messenger / mail windows (Telegram, Mattermost, web mail).
   → Consequence: any fix that reads *meeting participants* (the earlier
   ITER plan) does **not** touch these people. Retracted.

2. **No person → company binding exists in the data.** OCR rows carry the name
   plus `ZAPPNAME` + `ZWINDOWTITLE`. The window title *sometimes* contains a
   workspace token (`"<CompanyA> Mail"`, a `"<CompanyA> | Product"` channel),
   and *often* does not (`"Mattermost Desktop App"`, `"Telegram @ <dm>"`,
   `"(no title)"`). So the company is **partially** recoverable, never fully.

3. **The mentions are mostly genuine; echo is small.** For one frequently-seen
   name, **825/861** OCR rows are genuine `Telegram` — real, repeated messaging.
   Self-echo from the app's own window was only **~8** rows. So the driver is NOT
   noise inflation — it is **many genuine mentions with zero company structure**.
   (Earlier draft overstated echo; corrected.) `Self`'s own name does leak via
   own-tools OCR (17 rows) and gets mistaken for a third-party person.

4. **The chat already gets the window title — but raw, un-normalized, un-ruled.**
   `<recent_screen_activity>` is rendered as `[time] <app> — <windowTitle>: <ocr>`
   (verified in `ChatService.buildUserPrompt`). So the model *already sees*
   `Mattermost — <CompanyA> | Product: …`. The gap is NOT a missing signal; it is:
   (a) the title is messy free-text, not a canonical workspace tag; (b) there is
   **no rule** forbidding cross-workspace merge; (c) self + own-window echo are
   not filtered. The fix is normalize-tag + hard rule + filter, not "add data."

### 1.2. Honest limit (state up front, not buried) {#problem.limit}

Company is recoverable **only where the window/channel title names a known
workspace**. For DMs and generic app titles it is genuinely absent. Therefore the
correct output for some people is *"seen in your messages — company unclear"*.
That is the **truthful** answer, not a gap to paper over. We optimize for
*structured truth*, not for always-having-an-answer.

⚠️ Second limit (verified 2026-05-30): the workspace dictionary contains **only
the user's tracked MetaWhisp projects** (`ZPROJECTALIAS`, 28 rows: `Overchat`,
`SkyGen.ai`, …). A company that appears in a window title but is **not** a tracked
project (e.g. an external vendor's workspace seen in the title) will NOT be
recognized and its people go to `unclear`. So "separate by company" works for
*tracked-project* companies; everything else is honestly `unclear`. Widening this
(treat any recurring title token as a workspace) is a 042.3 question, not MVP.

## 2. User stories {#stories}

- **US-1.** Как пользователь, спрашивая «кто в команде `CompanyA`?», я хочу
  видеть только людей, которых видели в контексте `CompanyA` — чтобы не путать с
  другой компанией. *Accept:* ответ не содержит ни одного человека, наблюдавшегося
  только под `CompanyB` или только в неизвестном контексте.
- **US-2.** Как пользователь, я хочу, чтобы чат не сваливал людей из разных
  компаний в один список. *Accept:* при наличии людей из ≥2 воркспейсов ответ
  группирует их по воркспейсу, заголовки воркспейсов различимы.
- **US-3.** Как пользователь, я не хочу видеть себя (`Self`) среди сотрудников.
  *Accept:* `Self` и его варианты имени/почты никогда не появляются в людских
  списках.
- **US-4.** Как пользователь, когда компания человека неизвестна, я хочу честное
  «видел в переписке, компания неясна». *Accept:* такие люди идут в явную корзину
  «company unclear», а не приписываются к проекту.
- **US-5.** Как пользователь, я не хочу выдуманных действий/связей между людьми.
  *Accept:* ответ не содержит глаголов-связей («добавил», «подчиняется») между
  двумя людьми, если их нет дословно в контексте.

## 3. Design {#design}

Two layers. Ship the cheap structural layer first; escalate to the entity only if
live verification proves it insufficient (proportionality).

### 3.1. Workspace tagger (pure, testable) {#design.tagger}

`PeopleWorkspaceTagger` — pure functions, no I/O:

- `knownWorkspaces(from aliases: [ProjectAlias]) -> [Workspace]`
  Build the workspace dictionary **at runtime** from the user's project catalog
  (canonical + aliases, lowercased). INV-5.
- `workspace(forWindowTitle:appName:known:) -> WorkspaceTag`
  Returns `.workspace(canonical)` when a known alias is a token in the title,
  else `.unknown`. DMs / generic titles → `.unknown`.
- `isOwnToolNoise(appName:) -> Bool` — INV-6 deny-list (the app itself + AI/dev
  tools). Data-driven constant list of *tool* app names (not company names — safe
  to keep in source).
- `isSelf(_ token:, identity: SelfIdentity) -> Bool` — INV-3.

`SelfIdentity` = `{ email: String (from `LicenseService.email`, exists today),
nameVariants: [String] (from a **NEW** settings field 042.2 must add — does not
exist yet) }`. No real name in source/tests. Without nameVariants, self-exclusion
is best-effort from the email local-part only (INV-3).

### 3.2. People context assembly (consumed by ChatService) {#design.assembly}

`PeopleContextBuilder.build(screenRows:knownWorkspaces:selfIdentity:) ->
PeopleContext`:

1. Drop rows where `isOwnToolNoise(appName)` (INV-6).
2. Tag each remaining row with `workspace(...)`.
3. (042.1) Emit a **per-row, workspace-prefixed** screen block:
   `[workspace: CompanyA] <ocr snippet>` / `[workspace: unclear] <ocr snippet>`.
   The model already sees the raw window title; this **normalizes** that messy
   free-text into a canonical workspace tag and routes unknowns explicitly — no
   NER. The leverage is the normalization + the §3.3 hard rule, not new data.
4. Filter `Self` tokens out of any surfaced name (best-effort, INV-3).

Render into the chat prompt as a dedicated, separated block (replaces feeding raw
untagged `<recent_screen_activity>` into people questions):

```
<people_context>
  workspace: CompanyA
    - <snippet>            (Mattermost · 3d ago)
  workspace: CompanyB
    - <snippet>            (Telegram · 1d ago)
  workspace: unclear
    - <snippet>            (Telegram DM · 5h ago)
</people_context>
```

### 3.3. Prompt rules (ChatService.systemPrompt) {#design.prompt}

Tighten the existing `<critical_accuracy_rules>` §2 to encode INV-1..4 explicitly:
people belong to the workspace of the snippet they appear in; never merge across
workspaces; unknown → "company unclear"; `Self` is never an employee; never invent
a name or an action between two people.

### 3.4. Optional — Person aggregation entity (only if 042.1–2 insufficient) {#design.entity}

A `Person` SwiftData entity aggregating sightings: `displayName`, `nameVariants`,
`companies: Set<String>`, `firstSeen/lastSeen`, `mentionCount`, `sourceApps`.
Built by a periodic pass over comms-app OCR, deduping name variants (last-name +
Cyrillic/Latin). Gives a *curated* roster instead of snippet-grouping. Deferred
because it needs on-device NER + name-dedup — real cost, real failure modes. Spec
it fully only after 042.2 is measured on the live chat.

## 4. Iterations {#iterations}

### 4.0. ITER-042.0 — Cheap hypothesis (DONE on disk, pending live check) {#iterations.0}

The model already receives each screen snippet's window title (verified), so test
the cheapest lever first: a hard prompt rule + own-window noise filter. No tagger.

- [x] `ScreenContextNoiseFilter.isOwnWindow(appName:ownAppName:)` pure helper + tests.
- [x] Drop own-window OCR in `ChatService.fetchScreenContextLast24h` (over-fetch ×3,
      filter, take `limit`).
- [x] Rewrite `systemPrompt` `<critical_accuracy_rules>` §2: window-title = workspace,
      never merge across workspaces, unclear→"company unclear", never invent
      names/links, user is not a colleague.
- [x] Prompt-rule tests (`ChatServicePeopleRulesTests`).
- [ ] **Run `swift test`** (needs build approval) — assert green.
- [ ] **Live check** on the real chat ("кто в `CompanyA`?", screenshot repro). If it
      stops mixing companies + inventing → 042.1+ may be unnecessary. If it still
      mixes → proceed to the normalize-tagger (042.1).

### 4.1. ITER-042.1 — Tagger + filters (pure, TDD) {#iterations.1}

- [ ] RED: tests for `workspace(forWindowTitle:)` on fixtures derived from the
      real titles (redacted): known-token → workspace; DM/generic/empty →
      unknown; alias substring match is token-bounded (no false "Pro" in
      "Product").
- [ ] RED: tests for `isOwnToolNoise` (own app + AI/dev tools = true; comms = false).
- [ ] RED: tests for `isSelf` (email + name variants, case/translit folding).
- [ ] GREEN: implement `PeopleWorkspaceTagger`.
- [ ] Corner cases (see §5) tested.

### 4.2. ITER-042.2 — Context assembly + prompt rules {#iterations.2}

- [ ] RED: `PeopleContextBuilder.build` groups by workspace, drops noise,
      excludes `Self`, routes untagged to "unclear".
- [ ] GREEN: implement builder; wire into `ChatService.buildUserPrompt` as
      `<people_context>`; remove raw OCR people-leakage path for people questions.
- [ ] Add the **new "your name variants" settings field** (INV-3 needs it; does
      not exist today) + feed it into `SelfIdentity`.
- [ ] Tighten `systemPrompt` §2 per §3.3; add a prompt-level test asserting the
      rule text is present (INV-1..4).
- [ ] Live check: ask the real chat "кто в `CompanyA`?" / "кто в `CompanyB`?" —
      assert separation, `Self` absent, unknowns honest. (User runs / confirms.)

### 4.3. ITER-042.3 — Person entity (gated) {#iterations.3}

- [ ] Only if 042.2 live check still mixes/over-claims. Spec the entity in full
      (schema, migration, NER pass, dedupe, cost) before any code.

## 5. Corner cases {#corner}

1. Name variants — `"PersonX"` vs `"<first> PersonX"` → same person (last-name
   match); at minimum never asserted as two different people.
2. Person under **two** workspaces (consultant) → listed under both, never
   collapsed to one. Truth = appears in both.
3. Own-tools echo (app reads back its own answer) → excluded before tagging (INV-6).
4. `Self` in OCR → excluded (INV-3).
5. Telegram DM title (`"Telegram @ <x>"`) → workspace unclear, not invented.
6. Generic `"Mattermost Desktop App"` → unclear.
7. OCR false-positive token (common word) → mention-count threshold before
   treating as a person (≥2 sightings across distinct timestamps).
8. Cyrillic vs Latin spelling of the same name → folded for self/dedupe compares.
9. Workspace alias is a substring of an unrelated word → token-bounded match only.
10. No people in context → "I don't have that," never invented (INV-4).
11. Workspace token present but it's the app's *own* product name → still noise
    if appName is own-tools (INV-6 takes precedence over §3.1 tag).

## 6. Out of scope {#scope-out}

- Backfilling/cleaning historical noisy memories ("User chats with X via …") —
  separate one-shot cleanup, not part of the answer-path fix.
- Full NER / `Person` entity — gated to ITER-042.3.
- Email-address ↔ person resolution beyond `Self`.

## 7. DoD {#dod}

- INV-1..6 enforced in code paths that feed people context to the chat.
- 042.1 + 042.2 tests green, including all §5 corner cases; build + lint pass.
- Live chat re-test: people questions return workspace-separated answers, `Self`
  excluded, unknown-company people stated honestly, no invented names/relations.
- No real company/person name in source, tests, or this spec.

## Changelog
- [2026-05-30] §0–§7: initial spec. Root cause verified against production store
  (people are in screen OCR, partial workspace signal, own-tools+self noise).
  Earlier "meeting participants" approach retracted (§1.1.1).
- [2026-05-30] Self-audit pass (fresh-reviewer). Corrected 4 of my own claims
  against real code/data: (1) INV-3 downgraded to best-effort — app has email but
  NO name field, needs new settings input; (2) INV-6 narrowed — AI-tools OCR is
  huge & partly real, low-trust not hard-denied; (3) §1.1.3 echo overstated —
  825/861 mentions are genuine, self-echo only ~8; (4) §1.1.4 — the window title
  is ALREADY in the prompt, so the fix is normalize+rule+filter, not "add data".
  Added §1.2 second limit: dictionary only knows tracked-project companies.
