# ITER-075 Steps 5–6 — code check (2026-09-25)

This is a read-only check of the current code, `evidence/ITER-074/whole-review.md` and ITER-074, done for the plan's Steps 5 and 6.

The orchestrator re-checked three facts:
- The only production caller is `DiaSpike.runIfRequested()` (AppDelegate.swift:709).
- `type` is built without a payload (CandidateBuilder.swift:118).
- `UserMemory` rows are free text.

Line numbers are for commit 7d5748b.

## 1. Current behaviour

### Status and plumbing
1. Nothing in production drives a browser; the only caller is the dormant probe.
   - `AgentQueue` is a struct that nothing owns, and `AgentRouter.decide` is unwired.
   - JevEngine, the planner, the writer, a real browser bridge, a real Sheet, InputLease, TrustedInput, the card and the record store are test doubles or missing.
2. Tabs: `make new tab at end of tabs of w` runs in the front window (DiaScript.swift:71-85), and Chrome makes the new tab active.
   - Chrome's sdef has a writable `active tab index` and no background option on `make`.
   - Dia's sdef has only a read-only `active tab` and a `focus` command.
3. Threads:
   - The probe runs `NSAppleScript` on the main actor.
   - `BrowserBridge` and `AgentRun` are `@MainActor`.
   - The osascript precedent reads its pipe after `waitUntilExit`, so a 2 MB report would block.
4. Sheets: `SheetDestination` has create, paste and readBack, and `paste` also owns the screen consent.
   - Only `FixtureSheet` implements it.
   - `SheetCells` handles the canonical form and the read-back compare.
   - `PasteboardReplacementTransaction` exists, but the ⌘V helpers are private.
5. The writer has only `row(columns:subgoal:excerpt:)`.
   - There is no errand card kind; cards fade after 6 s, and the fifth one evicts the oldest.
   - An existing card is never redrawn, and cards have no labelled buttons.
   - Settings has no Agent tab, and the Sparkle delegate is nil.

### Whole-review findings
6. All 16 whole-review findings are still in HEAD.
7. S1 — back.
   - Back is `location.assign(previous)` with no check.
   - `visited` is filled from the page's own `location.href`, so a page can plant an address with `replaceState`, and an approved address can be replayed.
   - Back is always treated as reversible.
8. S2 — the lexicon and the grant check don't read `payload` (a select's option).
9. S3 — `locate()` never reads `report.flags`.
10. S4 — `boundedText` walks light-DOM children only, and slotted text is judged by its `<slot>`, which has no box.
11. S5 — `CookieBanner` is called only from tests, and the report has no overlay text.
12. L1–L10 and K1:
    - L1: the paste has no header and no source column.
    - L2: `type` has no payload and ends `.unsupported`.
    - L3: done and stuck skip `AgentPolicy.decide`.
    - L4: a login page ends the errand, and any bridge or decode error or a slow first page becomes `.failed`.
    - L5: `record.sheet` is set only after the paste, and the read-back is skipped at Stop.
    - L6: `paid` is bounded by expiry only.
    - L7: the consent wait sits inside `paste`.
    - L8: `closeTab` runs in the task that Stop cancels.
    - L9: an unsent action is logged `.acted`, and `.failed` overwrites `.confirmed`.
    - L10: no test answers Yes in time.
    - K1: the report is built and stringified in the page's own world.
13. Also found:
    - A `type` into a textarea or editor can never pass its postcondition, and values are cut at 200 characters.
    - A field whose label exceeds `WORDS_LIMIT` breaks the first pass and is still reported and typeable.
    - `back` is offered with no previous address.
    - An unreachable engine ends `.stuck` after two misses.
14. §17.2 items with no code yet:
    - J1×3 and J2×1 need everything above.
    - There is no committed list of irreversible actions.
    - The router is unwired.
    - InputLease and cancel-by-keystroke don't exist.
    - The card doesn't exist.
    - The CAPTCHA, typing, browser-not-running, quit, update and sleep cases have no code.
    - The run record has no work time, wait time or spend.

### Step 6 — what the observer reports
15. Per field:
    - role and accessible name (≤200 characters), with the name taken from aria-labelledby, aria-label, label, title or placeholder;
    - inputType, form action, method and submit label, and select options;
    - the value, except for textareas, editors, checkboxes, radios, files and passwords, and never on a login, payment or truncated page.

    Not reported: `autocomplete`, `required`, `name`/`id`, `maxlength`.
16. These are withheld entirely, and the page is flagged:
    - password, `current-password`, `new-password`, `one-time-code` and `cc-*` fields;
    - fields whose words match the secret patterns;
    - any obvious secret input found by the unbounded scan.

    The patterns are English only, so a field labelled «Код из SMS» is reported with its value.
17. Confirmation today:
    - The lexicon reads the element's name, text, submit label, form action and destination, so every `type` into a form with a "Send" button asks separately.
    - `Approval` binds the URL, the visible text and the submit label.
    - A Yes for Submit binds no field values.

## 2. Changes for Step 5
1. New `ChromeBridge: BrowserBridge`:
   - Apple Events are sent from a detached task (`NSAppleEventDescriptor.sendEvent(options:timeout:)`), each inside `Deadline.run(5 s)`.
   - Errors map to denied, not running, no window, JavaScript off and tab not found.
   - The permission is checked before each errand, and `DiaSpike` is removed.
2. `openTab` becomes one script: save `active tab index`, make the tab, then restore the index.
   - A new `activeTabID` builder lets the loop pause when the user brings the agent's tab to the front.
3. S1:
   - `visited` holds only addresses the loop opened itself without a Yes, never `page.url`.
   - `back` is offered only with a `backTo`, which is its destination.
   - Back is reversible only if it passes the navigation check.
4. S2: the lexicon and the grant check read `action.payload` for `.select`.
5. S3: `locate()` returns `'wall'` on a login or payment flag, and `'gone'` for a type or select on a truncated report.
6. S4:
   - `boundedText` walks `drawnChildren`, and visibility is judged by the nearest ancestor that has a box.
   - No click or select is offered for a nameless control.
7. S5:
   - The report gains `overlays` (dialogs, aria-modal, fixed layers at the centre), with their text, element indices and `blocksPage`.
   - A recognised cookie banner is declined without a question.
   - An unrecognised blocking overlay means leaving the site.
   - Banner elements are never candidates.
8. L1: `AgentPlan.sourceColumn`; the paste writes the header plus rows with the source, and the whole matrix is read back.
9. L2: no `type` candidate without a payload.
10. L3: done and stuck go through the policy, and a short done ends `.stuck` ("N из M").
11. L4:
    - A login flag gets a `pause(.signIn)` card ([Продолжить]/[Стоп], up to 10 min, counted as a wait); a CAPTCHA gets the same.
    - A payment flag stays `.needsUser`.
    - A bridge or decode error is a miss.
    - A closed tab ends as `.tabClosed`.
12. L5: `record.sheet` is set at create, and the read-back always runs once a paste has started, even after Stop.
13. L6: `paid` is bounded by `workTimeLeft`.
14. L7: the consent moves out of `paste` and is counted as a wait.
15. L8: `closeTab` runs in an uncancelled task.
16. L9: `.notSent`; `approved` survives. The record gains work time, wait time and spend.
17. New `GoogleSheet: SheetDestination`:
    - `sheets.new` opens in a background tab.
    - The paste takes the lease, prepares the clipboard, brings the tab forward after consent, rechecks Stop, sends one trusted ⌘V, restores the clipboard, and gives the user's tab and app back.
    - `readBack` uses whatever the I-0.2 check proves.
18. The writer (`OpenAICompatibleWriter`) and `AgentPlanner` take prompts that are ported and owner-approved. Each call reserves its worst case.
19. Card: a new `MWNotification.Kind.errand`:
    - pin and update, with no fade or eviction while an errand runs;
    - labelled buttons (Стоп, Стоп всё, Да/Нет, Продолжить, Открыть таблицу);
    - an `AgentCardPresenter`.
20. Settings gets a `SettingsTab.agent`: the Jev key, the writer, the browser choice, and what leaves the Mac. There is also a new `AgentRecordStore`.
21. A `@MainActor AgentService` owns `AgentQueue`:
    - the core's errand branch calls `submit(goal)`;
    - Stop and Stop all are wired;
    - quit, the Sparkle delegate and sleep are hooked in.

## 3. Changes for Step 6
1. The observer skips any `sensitiveField` in its second pass, which closes the site-48 gap. It also reports `autocomplete` and `required`.
2. Russian secret names wait for the owner's decision on Cyrillic tests. Superseded by the Codex review (F5): a confidence threshold is no substitute for the secret filter. Until that decision, a form whose field names the filter cannot read is refused, visibly.
3. New `FormFillJob`:
   - A form is the fields that share one action and method. Only text, email, tel, url, number, textarea and select fields are filled.
   - Facts come from Retrieval.
   - Jev answers a `choice` of fact kind or «leave empty» per field; values never go to Jev.
   - A field below the threshold stays empty.
   - Free text comes from the writer, through a ported and owner-approved prompt.
4. `type` and `select` carry their payload and are built by the job. The `type` script returns `holds` (`node.value === text`), checked in the page.
5. A new `form` confirmation kind is bound to the origin, the action, the method, the submit button and the (field, value) list. One Yes covers exactly those values.
6. Submit: `Approval.fields`. In the same script as the click, each approved field is found again and its value compared, so any difference, new field or flag voids the Yes.
7. The preview card:
   - a header with the origin, the destination and the submit label;
   - one row per field: name, value and source (a fact, the writer, or «пусто — не знаю»);
   - [Заполнить]/[Нет], then [Отправить]/[Нет];
   - two minutes to answer, and silence counts as No.
8. A page with a password, card or code field stops the job, and the card says which part is the user's.

## 4. Tests to write first
- S1: back never opens a planted address, and never replays an approved one.
- S2: a select option is read by the lexicon and the grant check.
- S3: a click is refused when a password field appeared after the choice.
- S4: a component button is named by its slotted text, and a nameless control offers no action.
- S5: a cookie banner is declined without a question, and a blocking unknown overlay skips the site.
- L1–L10: one test per finding, as listed in the review.
- Chrome: `openTab` restores the active index in the same script, and no Apple Event is sent from the main thread.
- Step 6:
  - An unchecked field is not reported.
  - Submit is refused when a field changed after the Yes.
  - A textarea reports that it holds.
  - Nothing is typed before the preview Yes.
  - Fact values never reach the engine.
  - A field that no fact matches stays empty.
- Every new wait gets `…EndsAtItsWindow` and `…NeverRunsPastTheExpiry`.

## 5. Spec corrections and open questions
1. Which browser: ITER-075 Step 5 says Chrome, but ITER-074 (decision 2, US-2, §11, §17.2) says Dia, with Chrome in phase 2. One of them must change. Dia has no `active tab index`.
2. The card kind should be `.errand`, since "agent card" already means the Screen Agent. ITER-074 also needs updates:
   - §1 lists form filling as "not planned";
   - §10 has no rows for Step 6 data.
3. PROGRESS.md says "15 findings" but lists 16.
4. Spec wording to update:
   - back goes only to an address the loop opened without a Yes;
   - §7.1 adds a select's option;
   - the type check runs in the acting script;
   - §7.3 adds K1;
   - Step 6 needs a source for the form's address.
5. To settle live:
   - whether Chrome's `execute` runs in an isolated world;
   - whether `make new tab` brings Chrome to the front;
   - whether `paste selection` and `copy selection` work in Sheets;
   - whether `sendEvent` is safe off the main thread;
   - background-tab throttling.
6. For the owner:
   - the header row and the source column;
   - the pause card;
   - sleep;
   - Russian secret names;
   - Step 6: one Yes or two;
   - where the form facts come from (`UserMemory` is free text; there is no structured email or phone).
