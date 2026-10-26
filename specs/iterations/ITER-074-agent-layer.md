# ITER-074 — Agent layer: browser use now, computer use next

**Status:** design, revised after two adversarial review rounds (2026-09-24).
Awaiting product-owner approval. Nothing is built.
**Depends on:** nothing unshipped.
**Builds on:** the voice question (Right ⌘ long-press), the notification stack,
CGEvent input, and the clipboard-borrowing transaction the layout fix already
uses. It does **not** reuse MetaChat's tool loop (§5).
**User outcome:** the user holds Right ⌘, says «add 10 competitor sites to a
table», keeps working, and a minute later a card says the table is ready — in
their own browser, with their own logins, having been asked only before
anything irreversible.

---

## 0. Decisions already made

Grilling 2026-09-24. Rows 13–16 were settled after the first review the same
day.

| # | Decision | Owner's answer |
|---|---|---|
| 1 | What v1 controls | The browser. Native apps and pixel computer use are phase 3. |
| 2 | How it reaches the browser | The user's real browser. No extension, no separate profile. |
| 3 | What thinks | Pluggable. On the Mac through a local model server, or cloud through OpenRouter or another hosted API (e.g. MiniMax M3). |
| 4 | Who pays in v1 | The user's own key, or local. Pro only after the real per-task cost is known. |
| 5 | Autonomy | Everything except the irreversible: send, publish, delete, pay, share. Never passwords or payment details. |
| 6 | Entry | The same Right ⌘ hold as the voice question. A question gets an answer; an errand goes to the agent. |
| 7 | Foreground | Background by default. Screen and mouse only after the user says yes. |
| 8 | Where it is seen | A card in the existing notification stack: current step, Stop, and the confirmations. Not the menu bar. |
| 9 | Ceilings | 40 steps / 10 minutes / $0.50 of cloud spend — whichever comes first. |
| 10 | v1 source | The agent searches the web itself. |
| 11 | v1 destination | The agent creates a new Google Sheet. |
| 12 | Step decisions | A System One decision model — Jev in the cloud, Laya on the Mac — chooses each action. An LLM writes text only. |
| 13 | Question or errand | An errand is a voice question. The app itself works out whether the user asked something or asked for something to be done — no separate gesture, no mode switch. |
| 14 | A second errand while one runs | It joins a queue, and the card says it is queued. |
| 15 | Cookie banners | No preference. The agent deals with them without asking (§7.2). |
| 16 | The Mac sleeps mid-errand | **Open.** The spec carries a proposed default (§8) until the owner answers. |

---

## 1. Jobs

What the layer is for, in the user's words. Phase 1 ships J1 and J2. Both run
on the same machinery: search the web, read the sites, fill a new Sheet.

| # | Job | Said like | Phase |
|---|---|---|---|
| J1 | Collect a list from the web into a new table | «Добавь 10 сайтов конкурентов MetaWhisp в таблицу» | 1 |
| J2 | Compare options side by side in a new table | «Сравни тарифы пяти сервисов транскрибации: цена, лимиты, языки» | 1 |
| J3 | Ask and get an answer — unchanged | «Что у меня завтра в календаре?» | exists; the router must not break it |
| J4 | J1 and J2 with nothing leaving the Mac but the browsing itself | on-device transcription + Laya + a local model server | 2 |
| J5 | J1 and J2 in Chrome or Safari | — | 2 |
| J6 | Work beyond the browser: native apps, pixel control | — | 3 |
| J7 | Another assistant hands the agent an errand over MCP | — | 3 |

Not planned — each needs its own decision: add rows to a table the user already
has; fill a web form up to, not including, its Submit; work inside a tab the
user names.

The layer must leave four existing jobs working as they do today: the voice
question's answers, dictation, selection translation and the layout fix. The
last three share the input lease with the agent (§7.5); §17.2 names the suites
that prove it.

---

## 2. The big picture

### 2.1 A core subsystem of the app

The agent is not a plugin or a companion app. It needs, all at once, what only
the app has:

- **Accessibility** — already granted for dictation; it lets the app post
  trusted keystrokes.
- **The voice entry** — the Right ⌘ long-press and its transcript. The
  long-press exists only in toggle mode: in push-to-talk mode Right ⌘ hold is
  dictation and there is no voice question
  (`Services/System/HotkeyService.swift:105`), so there are no errands in that
  mode either.
- **The notification stack** it reports through.
- **Settings**, where the engines and keys live.

What the app does **not** have yet is permission to send Apple Events. It is
signed with the hardened runtime (`build.sh:257`), and neither the
`com.apple.security.automation.apple-events` entitlement
(`Resources/MetaWhisp.entitlements`) nor `NSAppleEventsUsageDescription`
(`Resources/Info.plist`) is declared. Adding both is the first phase-0 spike
(§13).

It lives in the app target as `Services/Agent/`, beside `Services/Audio/` and
`Services/Intelligence/`, following the project's own layout.

### 2.2 The heavy model runs in its own process (phase 2)

Laya has 322M parameters in its multilingual checkpoint and 421M in the English
one (model cards `convaiinnovations/laya-multilingual` and
`convaiinnovations/laya`). A public fp32 ONNX export of the English checkpoint
is 1.69 GB, and its int8 version 0.58 GB (Hugging Face file listing,
2026-09-24). Its memory use when loaded is not published; phase 0 measures it.
Loaded into the app process, it would put the meeting recorder and dictation at
the mercy of the agent's memory. They must never die because an errand ran out
of memory.

There is no precedent for this in the app. `metawhisp-mcp` is launched by MCP
clients, not by the app (`Package.swift:9–11`), and the only child process the
app starts is a one-shot `osascript`
(`Services/Indexing/AppleNotesReaderService.swift:163`). So
`metawhisp-decider` gets its own contract, settled before phase 2:

- bundled inside the app and signed with it;
- started on demand; it prints `ready` on stdout before the first request;
- one request in flight, matched by id, each with a deadline;
- stderr is read continuously, so it can never block;
- stopped after an idle timeout once the queue is empty, and always when the
  app quits;
- a crash fails the errand, never the app.

Apple Events and CGEvents stay in the app process. The decider only computes
and needs no TCC grant.

### 2.3 The flow

```
Right ⌘ long-press (toggle mode)
 └─ transcript ─► AgentRouter ─┬─ question ─► post-processing ─► MetaChat, exactly as today
                               └─ errand ───► AgentQueue ─► AgentPlanner (writer LLM, once)
                                                             └─► AgentRun — the loop (§6)
                                                                  ├─ DiaBridge: observe and act, JS via Apple Events
                                                                  ├─ DecisionEngine: Jev (phase 1) · Laya in metawhisp-decider (phase 2)
                                                                  ├─ TextWriter: writer LLM, text only
                                                                  ├─ AgentPolicy + SafetyGuard
                                                                  ├─ TrustedInput ◄─ InputLease, shared with dictation
                                                                  └─ AgentCardPresenter: one pinned card

Outside the app: the user's browser (Apple Events) · a hosted API / OpenRouter (HTTPS, optional)
                 · a local model server on localhost
```

---

## 3. Five layers, top to bottom

| Layer | Job | Runs | Model |
|---|---|---|---|
| 1. Intent | Question or errand? | App, right after transcription | Decision engine `choice` on the transcript alone |
| 2. Plan | Goal, searches, output columns | App | Writer LLM, once per errand |
| 3. Loop | Observe → candidates → decide → guard → act → verify → record | App | Decision engine per step |
| 4. Engines | Answer typed questions; write text | Cloud, a local model server, or `metawhisp-decider` (phase 2) | Jev / Laya; any OpenAI-compatible LLM |
| 5. Hands | Read and act on the page; trusted keystrokes when a page refuses script input | App | — |

### 3.1 The router

**Where.** In `TranscriptionCoordinator`, right after transcription and before
post-processing. Today a voice question's transcript is post-processed first —
and that processing may use the cloud (`TranscriptionCoordinator.swift:389`,
`Services/Processing/TextProcessor.swift:86`) — and is then handed to MetaChat
(`TranscriptionCoordinator.swift:450`), whose `chat.send` takes a fresh screen
capture for voice questions (`Services/Intelligence/ChatService.swift:88`).
Routing first means an errand never passes through post-processing or the
screen capture.

**What it answers.** A `choice` between question and errand. The sentence is an
errand only when `errand` wins with at least 0.80 (placeholder, calibrated in
phase 0). Everything else is a question:
- `errand` below 0.80;
- a sentence of fewer than two words;
- no decision engine configured;
- an error, or a malformed answer;
- no answer within 2 seconds of the transcript being ready — one total deadline,
  a moment fixed before the engine is asked; a result that arrives at or after
  it is discarded.

A question continues down today's path unchanged, screen capture included. A
misrouted errand costs a text answer; a misrouted question would cost an
unwanted browser run.

**Cancel.** Routing runs inside the task that Esc already cancels
(`Services/UI/VoiceQuestionState.swift` `dismiss()`), so dismissing the popup
stops the router too.

**Cost.** A router call is billed to the user's Jev key, is not part of any
errand's budget, and adds its latency to every voice question while the agent is
configured. Phase 0 measures both; Settings discloses them.

The plan is written once, from the user's words, before any page is read. Page
text never re-enters the planner.

---

## 4. The v1 errand, step by step (J1)

«Добавь 10 сайтов конкурентов MetaWhisp в таблицу»

| # | What happens | Where | Leaves the Mac |
|---|---|---|---|
| 1 | Right ⌘ long-press; speech transcribed by the engine the user chose | App | nothing with on-device Whisper; the audio with cloud transcription (§10) |
| 2 | Router: errand — a `choice` on the sentence alone; no post-processing, no screen capture | Decision engine | the sentence (Jev) |
| 3 | The pinned card appears at once: «Понял: ищу конкурентов MetaWhisp · готовлю план · [Стоп]». If an errand is already running, the card says «В очереди: …» instead | App | nothing |
| 4 | Planner writes the goal, the searches (in the request's language and in English), the columns (name · URL · what they do) and the Sheet's title | Writer LLM | the sentence |
| 5 | The card shows the step: «Ищу конкурентов MetaWhisp · шаг 1 · [Стоп]» | App | nothing |
| 6 | A new background tab in the front Dia window opens a Google search for the first query | DiaBridge | the search itself, as any search |
| 7 | Observe; sensitive fields removed inside the page; candidate actions built; the engine picks one («open result 3») | Decision engine | the redacted candidate list (Jev) |
| 8 | On the site: the writer extracts name and description into the scratchpad; each row keeps its source URL | DiaBridge + writer | the excerpt (cloud writer) |
| 9 | Repeat 7–8 until 10 distinct qualifying sites; duplicates by domain skipped | Loop | as above |
| 10 | Open `sheets.new` in a background tab and set its title — creating and naming a file is reversible, no question | DiaBridge | nothing new |
| 11 | Card: «Можно взять экран на 3 секунды, чтобы вставить таблицу? [Да] [Нет]» — it also says so when the paste would switch the desktop or leave full screen | App | nothing |
| 12 | On yes, the paste transaction (§7.5): lease, clipboard borrowed, everything rechecked, one trusted ⌘V of escaped tab-separated rows, clipboard and focus given back if still ours | TrustedInput | the rows, into the user's new Sheet |
| 13 | Read the cells back and compare them with the canonical values (§6.6); the final card stays until closed: «Готово: 10 сайтов · [Открыть таблицу]» | DiaBridge | nothing |
| 14 | The errand record is written; the next queued errand starts | App | nothing |

Every paid call reserves its worst-case cost before it is sent, and every call —
model, network or Apple Event — has a deadline (§8). Stop cancels the call in
flight and is checked again immediately before every click, keystroke and paste
(§7.4).

J2 is the same run with the columns taken from the request («цена, лимиты,
языки»): one row per option, the named columns in the named order, a source URL
on every row, and «нет данных» in a cell the agent could not fill.

---

## 5. Components

All under `Services/Agent/` unless stated. **Pure** modules are testable
without a browser, a model or a network — the decisions live there.

| Component | Pure | Phase | Responsibility |
|---|---|---|---|
| `AgentRouter` | yes (mapping) | 1 | Maps the decision engine's question/errand `choice` to `.answer` / `.errand(goal)` under the rules of §3.1 |
| `AgentQueue` | yes | 1 | Errands wait in order; at most 3 waiting; expiry; frozen while an update waits |
| `AgentPlan` | yes | 1 | The fixed goal, subgoals, search queries, output columns and Sheet title. Immutable once written |
| `AgentPlanner` | no | 1 | One writer-LLM call producing `AgentPlan`, from the user's words only |
| `AgentRun` | no | 1 | Runs the loop; owns cancellation, deadlines, the step log |
| `AgentPolicy` | yes | 1 | Legal step transitions, confidence thresholds, step and budget accounting, progress and loop detection, absolute expiry |
| `ActionTable` | yes | 1 | Indexed elements with a stable fingerprint; sensitive fields already removed |
| `CandidateBuilder` | yes | 1 | Turns the table into ≤ 20 complete candidate actions per question: the best first, then «more» when a page is dense |
| `DecisionEngine` (protocol) | — | 1 | `decide(state, questions) → answers` in the Jev wire shape |
| `JevEngine` | no | 1 | `POST /v1/decisions` (a hosted API) or OpenRouter, the user's key |
| `LayaEngine` | no | 2 | Talks to `metawhisp-decider` |
| `TextWriter` (protocol) | — | 1 | OpenAI-compatible chat completion |
| `OpenAICompatibleWriter` | no | 1 | One client, three addresses: a local model server, OpenRouter, another hosted API |
| `BrowserBridge` (protocol) | — | 1 | List windows and tabs, open, run a script, read the result, bring a tab forward |
| `DiaBridge` | no | 1 | Apple Events to Dia (`execute … javascript`); injects the observer script and performs the actions |
| `ChromeBridge`, `SafariBridge` | no | 2 | The same for Chrome (`execute … javascript`) and Safari (`do JavaScript`) |
| `TrustedInput` | no | 1 | The paste transaction of §7.5 via CGEvent |
| `InputLease` | yes | 1 | One owner of synthetic input at a time — dictation, selection translation, layout fix, agent; the user's own keystroke always wins |
| `SafetyGuard` | yes | 1 | Irreversibility (lexicon + risk question), navigation check, field rules, cookie-banner policy, confirmation binding, cell escaping |
| `AgentCardPresenter` | no | 1 | The pinned card: step text, Stop, Stop all, Yes/No, Open, the queue line |
| `AgentRecordStore` | no | 1 | One versioned JSON file per errand under `Application Support/MetaWhisp/Agent/`, written atomically |
| `metawhisp-decider` (new executable target) | no | 2 | ONNX Runtime + Laya, stdin/stdout JSON, Jev wire shape, the contract in §2.2 |

**No SwiftData change in v1.** The live schema is V9
(`Services/Data/HistoryService.swift:29`). Errands are JSON files until their
shape settles. In phase 1 the result is found again in two ways: the final card
stays until the user closes it, and the Sheet carries the plan's title, so it
can be found in Google Drive. An entry in the app's history is phase 2.

**Not MetaChat's tool loop.** `ChatToolExecutor` exposes six local mutations
and four searches, and no browser tools
(`Services/Intelligence/ChatToolExecutor.swift:1079`). Its loop stops after 3,
4 or 5 rounds depending on the engine (`Services/Intelligence/ChatService.swift:163`,
`:209`, `:182`). Errands get their own authority; all they share with MetaChat
is the OpenAI-compatible client pattern.

**A pinned card.** `MWNotification` carries a title, a body and a single
`onTap`. The stack dismisses cards after 6 s
(`Views/Notifications/MWNotificationStack.swift:26`) and evicts the oldest of
four (`:19`, `:67`). Its renderer keeps an existing card's view as it was, so a
card cannot change its content today
(`Views/Notifications/MWNotificationStackController.swift:59`). The errand card
is a new `.agent` kind:

- it appears as soon as the router says «errand», before planning, so Stop is
  there from the first second;
- it is exempt from the timer and from eviction while an errand runs or waits;
- it is updated in place — the renderer learns to redraw a card whose content
  changed under the same id;
- it has labelled buttons: [Стоп] ends the running errand; [Стоп всё] appears
  when errands are waiting and ends them too. There is no close button while
  anything runs or waits;
- queued errands show on the same card («+1 в очереди»), not as extra cards;
- the final card — done, stopped or stuck — stays until the user closes it and
  says what was collected.

Screen Agent cards keep their 6-second life. The card goes to the stack, never
to the menu bar.

---

## 6. The loop in detail

### 6.1 Observe

The observer script walks the top document and its open shadow roots once. It
returns every element a person could act on: links, buttons, inputs, selects,
elements with a click handler or an interactive ARIA role. Hidden and zero-size
elements are dropped. Content inside cross-origin frames is out of reach and
counts as not found.

Each element has:
- an index;
- a fingerprint;
- a role, an accessible name and its visible text (trimmed);
- where activating it leads — its own href, or the link around it — and an
  input type;
- for a form control, the form's action URL, method and submit label;
- for a select, its listed options — up to 1000, and 2000 on a page;
- for an input, its current value, unless the field is sensitive;
- the page region it sits in, and whether it is in the viewport.

The fingerprint is a hash of the role, the accessible name, the href, the form's
action URL and method, and the nearest heading. It survives re-observation;
indices do not. Re-validation, confirmation binding and progress detection use
it.

Sensitive fields are removed by the script itself, before anything leaves the
page:
- `input[type=password]`;
- `autocomplete` values `cc-*`, `one-time-code`, `current-password` and
  `new-password`;
- fields that any word naming them marks as a password, a one-time or
  verification code, a card number, an expiry date or a security code — a
  `<label>` or an `aria-labelledby` label, shown or hidden, `aria-label`,
  `title`, `name` or `placeholder` (review round 5). Those words are read
  whole — no display limit lets a secret pass as safe — and a scan that runs
  out of time withholds every value on the page (review round 7).

Where someone writes — a textarea, a select, an editable region, an ARIA text
field, a component's shadow root inside one — only the field itself is
reported. Nothing written there becomes any element's name, text, row context
or heading. This is judged on the tree a person sees, slots included, and by an
element's own role, not a fallback one (review round 7). A sensitive field's
content, likewise, reaches no text the walk reports, and text a component does
not show is not read at all (review round 10); a control inside a sensitive
field is part of it and is not reported (review round 13).

The table keeps only two flags: *login form present* and *payment form
present*. The page's text is **data** in this table and nothing else.

### 6.2 Candidates

A search results page has hundreds of actionable elements. Laya scores 0.425 on
Banking77, a 77-option task, against Jev's 0.870 (Laya's model card), and its
multilingual card says to keep `choice` questions under ~20 options. So the loop
never asks about the whole page.

The app turns the table into **complete candidate actions** — operation, target
and parameters — so a model never invents a parameter:

| Operation | Its parameters come from |
|---|---|
| open | the element's own `href`, or a search URL built from the plan's queries — never text a model wrote. `http` and `https` only: `javascript:`, `data:`, `blob:`, `file:`, `mailto:` and every other scheme are never opened, and an element whose activation leads to such an address — its own, the link around it, or its form's destination — offers no action at all, whatever role the page gives it; so does an address at the report's length limit, which may have been cut (review round 9) |
| click | the element |
| type | the element; the text comes from the writer (§6.6) |
| select | the element and one of its listed options |
| scroll | the main region, one screen |
| wait | 2 s |
| back | an address this errand's loop opened before — the start or an open it sent — never one a page set by itself, never one the user approved (a second GET would do it again; ITER-076 2.2, S1), and never the page's own history, which a page can stuff to trap the agent (I-T2a) |
| more | — (the page's next candidates) |
| done / stuck | — |

Scoring is deterministic:
- overlap with the subgoal's terms, in both languages the planner wrote;
- main content over page chrome;
- in-viewport over not.

Every question offers the page's best actions, the plan's next three searches
and the page-level operations — never more than 20 options. When the page has
more actions than fit, «more» is offered too and shows the next ones, so every
action can be reached (review round 6). A select's options come best match
first; past the first five, they wait behind every other action on the page.
Zero → one scroll, then stuck.

### 6.3 Decide

A **step** is one Choose request below. Retries count as steps; routing and
planning do not. The 40-step ceiling counts these.

Two requests, in order:

1. **Choose.** State: the candidates, the current subgoal and the scratchpad
   count («7 of 10 collected»). Questions: `action` (choice among the
   candidates) and `goal_met` (noul: is the current subgoal satisfied on this
   page?).
2. **Risk.** Asked unless the chosen action is **always reversible**:
   - back, scroll, wait and «more» are always reversible;
   - so is a search the app built from the plan's own queries — it has no
     target on the page and an `http(s)` address;
   - every link from the page gets the risk question: a GET can purchase,
     transfer or unsubscribe whatever its words say (I-1.1 review).

   The risk question is `irreversible` (noul), about *that* action: its label,
   its form's action, method and submit label, the page's origin, and the
   destination URL.

Every answer is validated. An `action` that names no candidate, a malformed
answer, or a missing `irreversible` answer means **no action**, and counts as a
miss.

Before acting, the chosen target is looked up by fingerprint in a fresh
observation. If it is gone or changed, the step is decided again. The look-up
runs in the same script as the act (I-T2a). Typing looks again after the field
takes focus — the page's own handlers run then — and writes only if the field
is still the one chosen, still not sensitive and still focused (review round 9).

The question texts are prompts in all but name. **They are shown to the
product owner in full and approved before they are committed** — the same rule
as any LLM prompt. None is written from scratch: each is ported from a public
agent reference and adapted, with the source and its licence recorded. That
happens in phase 0 (I-0.4), because the phase-0 eval needs them.

### 6.4 Thresholds (initial values, calibrated in phase 0)

A `choice` answer carries a confidence. A `noul` does not: its single
probability is the whole answer. TypeSafe's documentation: «There is no
separate `confidence` value for a Noul». So the two get different rules.

| `action` confidence | Always reversible (back, scroll, wait, more, a planned search) | Other reversible (links, click, type, select) | Irreversible |
|---|---|---|---|
| ≥ 0.80 | act | act | ask the user |
| 0.50–0.80 | act | observe again, ask again | ask the user |
| < 0.50 | observe again, ask again | observe again, ask again | observe again, ask again |

Two «ask again» in a row for the same step → stuck: the errand stops with what
it has. **No LLM ever decides a step.**

The noul thresholds:
- `irreversible` counts as yes from 0.20 up, so anything short of clearly safe
  goes to the user;
- `goal_met` counts from 0.80.

Laya's multilingual card reports that it is «systematically over-confident
(mean confidence 0.75–0.83 against much lower accuracy)», so every number here
is a placeholder until measured on our pages.

### 6.5 Act, verify, record

Act through the bridge, then check the operation's own postcondition on a fresh
observation:

| Operation | Done when |
|---|---|
| open | the tab shows the requested URL — the same registrable domain after redirects |
| click | the URL, the target's state, or its region's content changed |
| type | the field's value equals the text |
| select | the chosen option is selected |
| scroll | the viewport moved |
| paste into the Sheet | the read-back cells equal the canonical values (§6.6) |

A failed postcondition is a miss. A write — type or paste — whose outcome is
uncertain is never repeated blindly: observe first, and if the value is there,
it counts as done. An action counts as sent once its script has gone out — a
lost reply included — so it is always recorded, and its postcondition decides
how it went (review round 13).

**Progress.** `AgentPolicy` tracks the actions — operation, target fingerprint
and parameters — and the scratchpad. Since the last new row or finished
subgoal, any of these means stuck:
- the same action three times — back, scroll, wait and «more» are not counted, since
  going back after every site is how a list gets collected; the same control
  with another option is another action;
- an A-B-A-B cycle;
- 8 steps.

A new row or a finished subgoal starts every count again: a button pressed once
per search, with a row after each, is not a loop (I-1.3).

**Record.** Every step appends to the errand record: operation, target role,
fingerprint hash, confidence, engine, milliseconds, tokens and cost — never the
page text or what was typed.

### 6.6 Text and cells

Only the `type` operation and the scratchpad extraction call the writer. It
gets the subgoal and the relevant excerpt, never the whole page: the visible
text of the page's main content, at most 3000 characters, on the tree a person
sees, without anything someone wrote there, any sensitive field's content or
hidden text (I-T2b, review round 10). A page whose fields could not all be
checked for secrets gives no excerpt.

The writer's output is data. Every cell goes through the same three steps, in
this order:

1. **Canonical value.** Control characters, tabs and line breaks become a space;
   runs of spaces become one; the ends are trimmed. An empty value becomes «нет
   данных».
2. **Escape for the paste.** If the canonical value starts with `=`, `+`, `-`,
   `@` or `'`, one apostrophe is put in front. Sheets treats a leading
   apostrophe as «this is text». Negative numbers therefore arrive as text,
   which a list does not mind.
3. **Read-back.** Each cell's displayed text must equal its canonical value, and
   no cell may hold a formula.

Whether the apostrophe escape survives a paste is a phase-0 check.

Every row keeps its source URL, so a wrong row is visible and can be checked.

---

## 7. Safety

### 7.1 Irreversible actions

Two independent checks; either one is enough to require a confirmation.

- **Structure** (ITER-076 2.1), in any language. Two cases need a Yes:
  - a click anywhere in a POST form, a script control inside it included;
  - a click on a control that sends any other form, to this site or another. A dialog form's buttons
    only close a dialog, so they are not one.

  A link is not one: every link gets the risk question.
- **Lexicon** on the target's name and visible text, its form's submit label and destination, its href
  and the action's destination (percent-decoded).
  - English only: send, submit, publish, post, delete, remove, pay, buy, order, share, invite, allow,
    accept, agree, grant, authorize, confirm, purchase, checkout, transfer, donate, bid, book, reserve,
    subscribe, upload, withdraw, sell.
  - Words match in their base form, as whole words.
  - Since ITER-076 2.1 the agent's code holds no Russian word lists. Other languages are read through
    structure and the `irreversible` noul.
- **Leaving or undoing** (log out, sign out, unsubscribe, cancel, approve) needs a Yes as well: the
  agent never signs the user out or drops a subscription on its own. In other languages this rests on
  the noul.
- **The `irreversible` noul** (§6.3). A malformed or missing answer means no
  action (§6.3), never an assumed yes or no.

The confirmation names the exact action: «Нажать „Отправить“ на
example.com?». It is bound to:
- the operation;
- the target's fingerprint, including its form's action and method;
- the page's origin and the destination URL;
- the payload — the text to type or the option to select.

If any of them changes before the action runs, the Yes is void — and the page,
the element's visible words and its submit label are checked again in the same
script that acts, so nothing can change in between (review round 11). No answer
within 2 minutes is a No. A grant is never asked about: it is handed to the
user (§7.2).

### 7.2 Things it never does

- Reads or fills a sensitive field (§6.1). A login form pauses the errand and
  asks the user to sign in; a payment form stops it.
- Grants anything — a grant is handed to the user, never asked about. A label
  that names cookies and holds nothing but cookie-consent words is consent to
  cookies; any other word («access», «account») makes it a grant (review
  rounds 11–13). This covers OAuth and permission prompts, and the «Allow
  access» banner that Sheets shows before IMPORT and IMAGE formulas may reach
  the web — Google blocks those formulas until the user clicks it
  (support.google.com/docs/answer/12188454). A grant prompt in the way stops
  the errand with a card saying what needs the user.
- Opens a URL a model wrote, or any URL that is not `http(s)`.
- Acts in a tab it did not open.
- Solves a CAPTCHA. It pauses and asks the user.

**Cookie banners** never interrupt the user (decision 15).
- **Recognised** means: a dialog or fixed overlay that mentions cookies and offers buttons with consent
  labels, both read in English since ITER-076 2.1.
  - Until S5 wires the banner in, a non-English banner can still match on the substring "cookie" or on
    a consent label such as "Accepter".
  - S5 makes a banner the agent can't fully read count as unsure, and skips it.
  A dialog that asks for access to an account, an app or anything of the
  user's is a grant, even when it mentions cookies. A bare «Allow» is a grant
  too: cookie consent says what it allows («Allow all», «Allow cookies»)
  (review round 5).
- **Inside a recognised banner**, the cookie order decides and neither risk
  check runs: reject all → necessary only → close → accept. Accept is chosen
  only when the banner blocks the page, offers nothing else, and its button
  says it accepts cookies («Accept cookies»). A bare «Accept» is never chosen —
  it may sit on a dialog that asks for more — so such a blocking banner counts
  as unsure (review round 7).
- **Not sure it is a cookie banner** — an overlay that blocks the page but is
  not recognised: the agent skips that site and moves to the next result. It
  does not click, and it does not ask.

### 7.3 A page that tries to give orders

Typed answers limit what a decision model can say. They do not limit which of
those answers a hostile page pushes it towards. TypeSafe's own documentation
says calibration «does not guarantee that an individual answer is correct». So
no defence here relies on the model resisting the page:

- the goal is written once, from the user's words, before any page is read, and
  it never changes;
- the model only picks among candidates the app built;
- URLs come only from real `http(s)` links and planned searches, and a link
  passes the navigation check before it is treated as harmless;
- every answer is validated, and a bad answer means no action;
- anything irreversible needs the user's yes for that exact action and payload;
- sensitive fields never reach any model, and cells are escaped before the
  paste.

What a hostile page can still do: waste steps, or steer which results get
collected. The ceilings bound the first. The source URL on every row makes the
second visible.

### 7.4 Stop

Stop cancels the model, network or Apple Event call in flight. It is checked
again immediately before every click, keystroke and paste. An action already
sent to the page cannot be undone; the card says what the last action was, and
its postcondition is still checked and reported. Stop is always a button, never
a gesture that could be mistyped.

### 7.5 One owner of synthetic input

Today there is no shared arbiter across features. The layout fix serializes its
own corrections (`Services/System/LayoutSwitchController.swift:460`) and types
its replacement as a keystroke burst without touching the clipboard
(`Services/System/FocusedTextGateway.swift:322`). Dictation pastes by
activating the saved app and posting ⌘V 0.2 s later, without re-checking the
target (`Services/System/TextInsertionService.swift:177–183`). Selection
translation borrows the clipboard (`Services/System/SelectionTranslator.swift:35`).
Only the layout fix's clipboard path re-checks focus
(`TextInsertionService.swift:233`).

The agent adds `InputLease`: one owner of synthetic input at a time.

- **Who.** Dictation's paste, selection translation's ⌘C and ⌘V, the layout
  fix's keystroke burst, and the agent's paste. The user's own keystroke always
  wins: during the agent's paste window it cancels the paste and returns the
  lease.
- **Priority** when two ask at once: dictation → translation → layout fix →
  agent. The agent always yields.
- **How long.** The lease covers only the synthetic keystrokes — never a
  network call such as the translation itself (`SelectionTranslator.swift:101`).
  The agent holds it from just before its ⌘V until the paste shows up in the
  read-back, or 2 s pass. No holder keeps it longer than 5 s; after that it is
  released and the release is logged.
- **Waiting.** Dictation during an errand works as usual. The errand's paste
  waits for the lease for up to 30 s, then asks on the card again.

The agent's paste (§4, step 12):
1. Take the lease.
2. Borrow the clipboard through the existing ownership-checked transaction
   (`PasteboardReplacementTransaction`, `TextInsertionService.swift:25`).
3. Bring the agent's tab forward. If this switches the desktop or leaves full
   screen, the consent card has already said so.
4. Recheck Stop, the consent, the tab and the focused cell. Cancelling is
   possible up to here; after the next step the agent can only verify and
   report.
5. Post one trusted ⌘V.
6. Give the clipboard back **only if nobody copied since** (`restoreIfOwned`,
   `TextInsertionService.swift:81`). Return focus **only if** it is still on the
   agent's tab. Release the lease.

Any failed check before step 5 means no paste.

---

## 8. Ceilings

40 steps / 600 seconds / $0.50 of cloud spend — whichever comes first.

- **Steps** are Choose requests (§6.3).
- **Cost.** Before each paid call, its worst case — maximum input plus maximum
  output tokens at the model's price — is reserved. A call that would cross
  $0.50 is not sent. When an engine reports no usage, the reservation counts as
  spent. Router calls are not part of an errand's budget (§3.1).
- **Deadlines** (placeholders, measured in phase 0):
  - router: 2 s, total;
  - decision call: 10 s;
  - writer call: 30 s;
  - one Apple Event: 5 s.

  A timeout is a miss.
- **Local engines** count $0.
- **Waiting for the user doesn't count** towards the 600 s. That covers a
  confirmation, a CAPTCHA and a sign-in; each wait has its own ceiling (§7.1,
  §11).
- **Absolute expiry.** Whatever the pauses, an errand ends 30 minutes after it
  started, and a queued errand that has not started within 30 minutes of being
  queued is dropped. The card says which. This deadline and the 2-minute answer
  window run on the continuous clock, so setting the wall clock back cannot
  stretch them (review round 6).
- **At a ceiling** the errand stops. The card says how far it got («7 из 10
  собрано, остановился на лимите времени»), and the record keeps what was
  collected. The ceilings and Stop are checked right before every effect — an
  action, the Sheet's creation, the paste — not only between steps, and a
  question to the user never runs past the absolute expiry. No Sheet is made
  at a ceiling or after Stop (review round 11).
- **Queue.** At most 3 errands wait; a fourth is refused with a card.
- **Sleep** (decision 16, open — proposed default):
  - the 600-second clock counts awake time only;
  - on wake, any foreground consent is void and the lease is released;
  - after a sleep shorter than 10 minutes, the errand observes again and
    continues, asking for the paste again if it had not happened;
  - after 10 minutes or more, it stops with the partial result, so nothing
    starts clicking on its own hours later.

---

## 9. Permissions and first run

| What | When | How it is handled |
|---|---|---|
| Automation (Apple Events → the browser) | Declared in phase 0; checked before every errand | The entitlement and a usage string are added (§2.1). Before an errand starts, `AEDeterminePermissionToAutomateTarget` checks the target without sending it anything (off the main thread, as the SDK requires). Its answers: allowed; `errAEEventWouldRequireUserConsent` (−1744), which means macOS will ask once; `errAEEventNotPermitted` (−1743), denied or revoked, which ends in a card saying where to allow it; `procNotFound`, the browser is not running (§11) |
| «Allow JavaScript from Apple Events» | First script call | Detect the specific refusal, show where the toggle lives, do not retry until it is on |
| Accessibility | Already granted for dictation | Reused for trusted input |
| Screen Recording | Phase 3 only | Already granted for meetings |
| An engine | First errand | Settings → Agent: decision engine (Jev key; the Laya download in phase 2) and writer (a local model server, OpenRouter or another hosted API + model). With no decision engine set, the router is off and every voice question stays a question |

---

## 10. What leaves the Mac

| What | Leaves when | Goes to |
|---|---|---|
| The request's audio | cloud transcription is selected | MetaWhisp's Pro proxy, or Groq / OpenAI on the user's key (`Services/Transcription/CloudWhisperEngine.swift:61`) |
| The request's sentence, for routing | the decision engine is Jev | a hosted API or OpenRouter |
| A question's sentence, for post-processing | a question, when today's text processing uses the cloud (`TextProcessor.swift:86`); errands skip it | as today |
| The request's sentence, for the plan | the writer is a cloud model | the writer's provider |
| Redacted candidate lists and the goal | the decision engine is Jev | a hosted API or OpenRouter |
| Page excerpts and the goal | the writer is a cloud model | the writer's provider |
| Searches and page loads | always | the sites themselves, as in any browsing |
| The table's rows | always — it is the job | Google, into the user's own new Sheet |

With on-device transcription, Laya and a local model server, only the last two rows
apply. Settings says this in words next to each choice. Logs record counts,
confidences, timings and outcomes only — never page text or typed text.

---

## 11. Failure modes

| Situation | Detected by | Behaviour |
|---|---|---|
| CAPTCHA | known challenge markers in the table | pause; the card asks the user to pass it; [Продолжить] observes again; no answer in 10 min → stop |
| Login form | the *login form* flag on the full table | the same pause, asking the user to sign in |
| Payment form | the *payment form* flag | stop; the user does that part |
| A grant prompt (OAuth, «Allow access») | the lexicon on the target | stop; the card says what needs the user |
| An unrecognised overlay blocking the page | no candidates outside the overlay | skip the site, next result (§7.2) |
| Element vanished or changed | its fingerprint is missing from a fresh observation | decide again; a miss |
| Page slow | no load within 15 s | wait once, then a miss |
| Tab closed by the user | bridge error | stop, report |
| The user starts working in the agent's tab | focus and input events in that tab | pause; card: continue or stop; no answer in 10 min → stop |
| Dia not running | `procNotFound` (§9) | stop; the card says «Открой Dia и попроси ещё раз». The agent never launches or fronts the browser itself |
| Several Dia windows or profiles | the bridge lists the windows | the errand binds to the front window when it starts and opens its tabs there; that window closing stops it |
| Automation denied or revoked | −1743 (§9) | stop; the card says where to allow it |
| JavaScript from Apple Events is off | the specific script error | stop; the card shows where the toggle lives |
| Router: error, malformed answer, late answer | §3.1 | the sentence is a question; nothing else happens |
| Loop engine unreachable or past its deadline | network error, timeout | one retry, then stop, naming the engine |
| Malformed model answer in the loop | validation (§6.3) | no action; a miss |
| Decision model unsure | §6.4 | observe again, ask again; twice → stuck |
| No progress | `AgentPolicy` (§6.5) | stuck |
| Ceiling or absolute expiry | `AgentPolicy` (§8) | stop with the partial result |
| A second errand | `AgentQueue` | queued; the card says so; a fourth waiting → refused |
| Dictation during an errand | `InputLease` (§7.5) | dictation goes first; the agent's paste waits up to 30 s, then asks again |
| The app quits | `applicationShouldTerminate` — today it rescues meetings only (`App/AppDelegate.swift:2651`) | the running errand stops as if Stop were pressed; the record keeps the rows; waiting errands are recorded as not started. Resuming after relaunch is phase 2 |
| An update is ready | the updater's delegate — today there is none (`App/AppDelegate.swift:357`) | no new errand starts; the running one continues to its end, bounded by its absolute expiry; waiting errands are recorded as not started, and the card says so; if the update is withdrawn, errands start again; then Sparkle's postponed relaunch proceeds (`updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`). Sparkle may skip that callback — its header says it is not called in some relaunch cases — and then the app's quit path above applies |
| The Mac sleeps | sleep and wake notifications | §8 (decision 16, open) |

---

## 12. Testing

### 12.1 The automated test system — four levels

Levels 1–3 need no network, no browser, no macOS permission and no owner;
every suite in them joins `CRITICAL_SUITES`. Only level 4 needs the owner, and
it is batched into one session.

| Level | What it proves | How |
|---|---|---|
| L1 Unit | the decisions: router, queue, policy, candidates, guard, cells, lease | plain XCTest on the pure modules |
| L2 Page | the app's own JavaScript — observer, actions, read-back — does what it claims on real HTML | a `WKWebView` inside the test process loads local HTML fixtures (`Tests/MetaWhispTests/Fixtures/Agent/pages/`, found through `#filePath`) and runs the production scripts |
| L3 Loop | a whole errand works end to end | `WebViewBridge` — the production `BrowserBridge` protocol over one `WKWebView` per tab, fixture URLs routed to local files — plus a scripted decision engine, a fake writer and a fixture sheet that accepts a paste and reads its cells back |
| L4 Live | the parts only a real Mac can show: Dia over Apple Events, the macOS prompts, Google Sheets, Jev | `DiaSpike` and later spikes, run in the owner session; outcomes and timings go to a report |

Every L3 run checks DoD-shaped outcomes, not just "no crash":
- the rows collected, each with its source URL;
- a confirmation for every listed irreversible action;
- the ceilings respected;
- no step decided by an LLM;
- no page text in the log;
- no tab left open.

A `WKWebView` running outside an app was verified on 2026-09-24: it loaded a
local fixture, the probe read its elements and clicked a button.

### 12.2 What each level covers

- **Pure modules**, each unit-tested with a failing test first:
  - router mapping, including every fallback of §3.1;
  - queue: order, cap, expiry, the freeze during an update;
  - policy: transitions, thresholds, step and budget accounting, progress,
    absolute expiry;
  - candidate builder, including the scheme rule and the navigation check;
  - safety lexicon and field rules, cookie-banner policy, confirmation binding;
  - the three cell steps of §6.6: normalisation, escape, read-back equality;
  - input lease: priorities, the 5 s cap, the user's keystroke winning.
- **Every gate gets its ceiling test.** A `…DoesNotFire` test has a
  `…FiresAnywayAfter…` sibling. That covers the queue, the lease wait, the
  CAPTCHA pause, the confirmation timeout, the update deferral and the
  absolute expiry.
- **Page fixtures** — action tables captured from real pages and stored as
  JSON; the candidate builder and the guard run against them
  deterministically. The pages:
  - a Google results page, a competitor homepage, a fresh Sheet;
  - a cookie banner, an unrecognised blocking overlay;
  - a login form, an OAuth prompt;
  - a misleading «Продолжить» that submits a form;
  - a link whose path is `/unsubscribe`, and a `javascript:` link;
  - extracted text that starts with `=`, `-` and `'`.
- **Interleaving tests**: dictation, selection translation and a layout
  correction, each arriving during the agent's paste.
- **Eval harness (phase 0)** — hand-labelled step decisions and router
  sentences, run through Jev (and Laya once it exists). It reports accuracy,
  cost and time, split by Russian and English. This decides what ships.
- New suites join `CRITICAL_SUITES`; `scripts/regression.sh` must PASS.

---

## 13. Rollout

| Phase | Scope | Exit criterion |
|---|---|---|
| 0 — Spikes | (1) the signed app with the Apple Events entitlement: the permission check, prompt, denial, revocation; (2) JS through Apple Events in Dia, and its toggle; (3) trusted paste into a new Sheet, the apostrophe escape, and **reading the cells back**; (4) the prompts and typed questions drafted and approved; Jev step and router accuracy on captured pages, RU / EN; (5) Laya latency and memory — informational, off the phase-1 path | §17.1 |
| 1 — v1 | J1 and J2 in Dia, Jev on the user's key, a local model server or a cloud writer; router, queue, pinned card, guard, ceilings, input lease, update deferral | §17.2 |
| 2 — Local | `metawhisp-decider` with Laya; Chrome and Safari bridges; resume after quit; an entry in history | J1 passes with on-device transcription + Laya + a local model server and no outbound request except browsing and the Sheet; the app survives the decider being killed mid-errand |
| 3 — Beyond the browser | Pixel computer use; native apps through Accessibility; Pro-included cloud; errands over MCP | Separate spec |

---

## 14. What is not known yet

- Whether Dia exposes the «Allow JavaScript from Apple Events» toggle and what
  it requires. Its scripting dictionary carries the command; the toggle is
  unverified.
- How macOS attributes the Automation permission to the app. The TCC database
  is not readable here; phase 0 tests it on the signed app.
- Whether Sheets ignores script-dispatched input, whether a trusted ⌘V of
  tab-separated rows fills the cells, and whether the apostrophe escape
  survives a paste — likely, unmeasured.
- How to read the cells back. Sheets draws on a canvas. One hypothesis: its
  export endpoint, fetched from the same tab.
- What happens to Spaces and full screen when the agent's tab is brought
  forward.
- How often Jev picks the right element and the right route (question or
  errand), in Russian and in English, and how much the router delays a voice
  question. No one has published failure rates; the public numbers are single
  demos.
- Laya's latency and memory on the owner's Mac. Its model card reports
  32.8–39.5 ms per single question on a Tesla T4 GPU; nothing is published for
  Apple Silicon.
- The texts of every prompt and typed question — ported from public agent
  references in phase 0 (I-0.4), approved before commit.

---

## 15. User stories

**US-1 — errand by voice.** As a founder, I want to hold Right ⌘ and say an
errand, so that it gets done without me switching windows.
*Accepted when:*
- in toggle mode, an errand phrased in Russian or English starts an agent run,
  and a question still gets an answer;
- with no engine configured, every voice question is answered as before.

**US-2 — my own browser.** As a user, I want the agent to work in the browser I
am signed into, so that it can reach my Google account without a second login.
*Accepted when:* the errand runs in Dia with the user's session; no extension,
no new profile.

**US-3 — I keep working.** As a user, I want the agent to work in a background
tab, so that my cursor and keyboard stay mine.
*Accepted when:*
- no focus change and no synthetic input happen before the user approves the
  screen step;
- a keystroke during the paste cancels it;
- dictation during an errand works.

**US-4 — nothing irreversible behind my back.** As a user, I want to be asked
before anything is sent, published, deleted, paid for or shared, and I want the
agent never to grant access on my behalf.
*Accepted when:*
- every such action on the test pages raises a confirmation that names the
  action, including a misleading «Продолжить» that submits a form;
- No and silence both cancel it;
- a changed target or payload voids a Yes;
- a grant prompt stops the errand with a card.

**US-5 — I can see it and stop it.** As a user, I want a card with the current
step and a Stop button that does not disappear.
*Accepted when:*
- the card appears before planning and stays while anything runs or waits;
- Stop ends the run within one call deadline, and Stop all also clears the
  queue;
- the final card stays until closed and says what was done and what the last
  action was.

**US-6 — it cannot run away.** As a user paying with my own key, I want a hard
ceiling.
*Accepted when:*
- the run stops at 40 steps, 10 minutes of work or $0.50, and always within 30
  minutes of starting;
- no single call pushes the spend past $0.50;
- it reports the partial result.

**US-7 — local if I want (phase 2).** As a privacy-minded user, I want to run
the agent with nothing leaving my Mac except the browsing itself.
*Accepted when:* on-device transcription + Laya + a local model server complete the
errand with no outbound request except the searches, the pages and the Sheet.

**US-8 — one at a time.** As a user, I want a second errand to wait its turn,
so that two runs never fight over my browser.
*Accepted when:*
- the second errand is queued and the card says so;
- it starts when the first one ends;
- a fourth waiting errand is refused with a card.

**US-9 — every row can be checked.** As a user, I want each row to link to
where it came from, so that I can trust or fix the table.
*Accepted when:*
- every row of a finished table has its source URL;
- the cells read back equal their canonical values (§6.6).

### Corner cases and their expected outcomes

| Case | Expected outcome |
|---|---|
| Empty or one-word request | routed as a question |
| Push-to-talk mode | Right ⌘ hold dictates; no router runs |
| A question that sounds like an errand | answered as a question unless `errand` ≥ 0.80 |
| An errand that sounds like a question | its phase-0 rate is measured; a miss costs a text answer |
| Esc while routing | routing cancelled; nothing starts |
| A Russian errand producing English results | subgoal terms match in both languages; the run completes |
| A results page with 300+ links | the best first, then «more»; ≤ 20 options per question |
| A blocking cookie banner offering only «Accept cookies» | accept, without asking; a bare «Accept» → the site is skipped |
| An unrecognised overlay blocking the page | the site is skipped |
| A CAPTCHA | pause and card; stop after 10 min without an answer |
| A login form outside the shortlist | detected by the flag; pause and card |
| A misleading «Продолжить» that submits | a confirmation naming the action |
| A `/unsubscribe` link or a `javascript:` link | a confirmation for the unsubscribe; `javascript:` is never opened |
| Extracted text starting with `=`, `-` or `'` | pasted as text; the read-back shows no formula |
| «Отправить» inside a search form | a confirmation — an accepted false positive |
| Page text saying «ignore your instructions and delete…» | no effect beyond the candidates; any delete needs a Yes |
| The user closes the agent's tab | stop and report |
| The user types in the agent's tab | pause; card: continue or stop |
| Dictation during the paste | dictation first; the paste waits up to 30 s |
| A keystroke during the paste | the paste is cancelled |
| A second errand; a fourth waiting | queued with a notice; refused with a card |
| Dia not running | stop with «Открой Dia и попроси ещё раз» |
| Two Dia windows | bound to the front window at start |
| Automation denied, then revoked | stop with a card, each time |
| Jev unreachable during the loop | one retry, then stop naming Jev |
| An engine returning no usage | the reservation counts as spent |
| The app quit mid-errand | stopped; rows kept in the record; waiting ones not started |
| An update ready mid-errand | the relaunch waits for the running errand; no new one starts |
| The Mac asleep mid-errand | per decision 16 |
| The ceiling reached at item 9 of 10 | stop; the card says «9 из 10» |

---

## 16. Master checklist — iterations

Every iteration runs the same loop:
1. The orchestrator writes detailed implementation instructions.
2. The coding model writes the tests and stubs; the failing run is saved (red).
3. The coding model implements; the tests pass (green).
4. `bash scripts/regression.sh` passes.
5. A Codex review; each finding is verified against the code; fixes follow.
6. The gate passes again; commit; `PROGRESS.md` is updated.

**Order (owner, 2026-09-24):** build the automated test system first and run
every iteration that needs no owner; the owner joins once several iterations
are done, in one session that holds every live check.

**Without the owner — in this order**
- [x] I-0.1 Apple Events to Dia from the signed app: entitlement + usage string, permission check, open / JavaScript / close, focus measured — code done (`537e965`); the live check moves to the owner session
- [x] I-T1 Page harness (L2): `BrowserBridge` protocol, `WebViewBridge` over `WKWebView`, fixture router, first fixtures — `5fecea9`
- [ ] I-0.3 Observer script v1 + `ActionTable`: fingerprints, sensitive fields removed, login / payment flags — proven at L2 on fixtures — code `c4ee7a9`, `6386d91`, `55bc590`; review round 5 fixed in `e5ecb78`, re-review pending
- [ ] I-1.1 Cells (§6.6) + `SafetyGuard`: lexicon, navigation check, cookie policy, confirmation binding — code `8bdd3ac`, `593c776`; review round 5 fixed in `e5ecb78`, re-review pending
- [ ] I-1.2 `CandidateBuilder` — code `84ce5b2`; review round 6 fixed in `ebe296e`, re-review pending
- [ ] I-1.3 `AgentPolicy`: steps, thresholds, budget reservation, progress, absolute expiry — code `2ad8ae2`; review round 6 fixed in `ebe296e`, re-review pending
- [ ] I-1.4 `AgentQueue` + `AgentRouter` — code done; review pending
- [ ] I-T2 Loop harness (L3): scripted decision engine, fake writer, fixture sheet, `AgentRun` skeleton; J1 end to end on fixtures
  - [ ] I-T2a Action scripts (L2): open, click, type, select, scroll, back — each finds its element again with the observer's own walk in the same script run — code done; review pending
  - [ ] I-T2b Engine protocols, `AgentPlan`, scratchpad rows with source URLs, the errand record without page text, the page excerpt, the fixture sheet — code done; review pending
  - [ ] I-T2c `AgentRun` skeleton; J1 end to end on fixtures with the scripted engine; the L3 outcome checks of §12.1 — code done; review pending

**Owner session 1 — every live check at once**
- [ ] I-0.1 live: the macOS prompt, a denial, a revocation — §17.1(2) — the prompt and an allow done on Chrome, 2026-09-25 (the owner's choice); a denial, a revocation and Dia remain
- [ ] I-0.2 Sheets: trusted paste, the apostrophe escape, the cell read-back — §17.1(3)
- [ ] I-0.4 Prompts and typed questions ported from public references and adapted; owner approval — §17.1(4)
- [ ] I-0.5 Minimal `JevEngine` + eval harness; labelled sets; thresholds confirmed — §17.1(5)
- [ ] I-0.6 Go / no-go report, with Laya latency and memory as information — §17.1(1)

**Phase 1 — the rest**
- [ ] I-1.5 `InputLease`, adopted by dictation, selection translation and the layout fix; interleaving tests
- [ ] I-1.6 `DiaBridge` on Apple Events sent off the main thread + the `TrustedInput` paste transaction
- [ ] I-1.7 Pinned `.agent` card: in-place redraw, Stop / Stop all, the queue line, the final card
- [ ] I-1.8 Settings → Agent, including what leaves the Mac; `AgentRecordStore`
- [ ] I-1.9 `AgentRun` wiring; the router in `TranscriptionCoordinator`; the Sparkle delegate; `DiaSpike` removed
- [ ] I-1.10 J1 ×3, J2 ×1, every corner case — §17.2; release

**Phase 2**
- [ ] `metawhisp-decider` + `LayaEngine`; Chrome and Safari bridges; resume after quit; an entry in history — §13 exit criterion

- [ ] Regression gate PASS at every step

---

## 17. Definition of Done

### 17.1 Phase 0 is done when

1. A written go / no-go exists for each of the five spikes, with numbers
   measured on the owner's Mac — not published ones.
2. The signed app has checked its Automation permission for Dia and sent it an
   Apple Event. The macOS prompt, a denial and a revocation have each been seen
   and recognised.
3. Cells pasted into a new Sheet are read back and equal their canonical values
   (§6.6); a value starting with `=` reads back as text. Without the read-back,
   phase 1 does not start.
4. The owner has approved every prompt and typed-question text.
5. Jev is measured on the labelled set — at least 50 steps and 50 router
   sentences, half of them in Russian — for accuracy, cost and latency per call.
   It passes if it meets these thresholds (proposed; the owner confirms them
   before the set is scored):
   - no more than 2 % of labelled questions are routed as errands;
   - at least 90 % of labelled errands are routed as errands;
   - the router's 95th-percentile latency is at most 1.5 s;
   - the step choice is right at least 90 % of the time;
   - the lexicon and the `irreversible` noul together catch every labelled
     irreversible action.

### 17.2 Phase 1 is done when

1. J1 («Добавь 10 сайтов конкурентов MetaWhisp в таблицу») completes on the
   owner's Mac three times in a row. Each run gives a new, titled Sheet with 10
   distinct sites and a source URL on every row, and the cells read back equal
   their canonical values.
2. J2 («Сравни тарифы пяти сервисов транскрибации: цена, лимиты, языки»)
   completes once, with 5 rows, the three named columns in order, a source URL
   on every row, and «нет данных» where the agent found nothing.
3. The test pages and the list of irreversible actions on them are committed as
   fixtures before phase 1 starts. Every listed action raises a confirmation,
   and No and silence both cancel it.
4. US-1 to US-6, US-8 and US-9 pass their acceptance criteria. Every corner case
   in §15 gives its expected outcome.
5. Each J1 run's cost and time are written down, and none exceeds a ceiling.
   - Cost is the sum of each call's reported usage at its price, or its
     reservation when usage is missing.
   - Time runs from the router's answer to the final card, not counting waits
     for the user; those waits are reported separately.
6. Every finding in Appendix A is closed at the section it names.
7. Each pure module has a saved log of its failing test run from before the
   code that makes it pass. The new suites are in `CRITICAL_SUITES`,
   `bash scripts/regression.sh` says PASS, and the build passes. There are no
   TODOs, invented APIs or dead code.
8. The existing behaviour holds.
   - These suites pass unchanged: `TranscriptionCoordinatorRecoveryTests`,
     `TranscriptionConfidenceGateTests`, `TextInsertionClipboardTests`,
     `LayoutKeystrokeReplacementTests`, `LayoutClipboardOwnershipTests`,
     `LayoutTypingRaceTests`, `SelectionTranslateClipboardTests`,
     `SelectionTranslateFeedbackTests` and `HotkeyRearmTests`.
   - The interleaving tests of §12 pass.
   - With no engine configured, the transcript reaches MetaChat exactly as
     today.
9. A code review of the implementation leaves no open critical or major
   finding.
10. Code, tests and prompts contain no private data.
    - **Prohibited:** names of people, contacts, clients and private projects,
      emails, phone numbers, account ids and keys. Generic placeholders such as
      Sam, Alex or AcmeCorp are fine.
    - **Allowed:** the public products the integration needs — Dia, Chrome,
      Safari, Google Sheets, Jev, Laya, a hosted API, OpenRouter, a local model server,
      MetaWhisp.
    - **Checked** by an audit grep for email, phone and key patterns before
      every commit, and by the reviewer reading every new string literal.
11. Shipped through a Sparkle release and installed on the owner's Mac.

---

## Appendix A — Reviews of 2026-09-24: where each finding is closed

### Round 1

| # | Finding | Closed in |
|---|---|---|
| 1 | The writer decided low-confidence steps, against decision 12 | §6.4 |
| 2 | Apple Events were not declared in the signed app | §2.1, §9, §13 (phase 0) |
| 3 | «Page text cannot instruct the model» was unsupported | §6.1–§6.3, §7.1–§7.3 |
| 4 | The foreground paste was unguarded; nothing arbitrated input | §7.5 |
| 5 | The decision request was incomplete; two bands were identical; a noul has no confidence | §6.1–§6.4 |
| 6 | Verification could not prove completion | §6.5, §6.6, §4 (step 13), §17.1 |
| 7 | The run and browser lifecycle was missing | §8, §11 |
| 8 | Ceilings and Stop acted after the fact | §4, §7.4, §8 |
| 9 | The card could disappear | §5 |
| 10 | «V4 is current» | §5 |
| 11 | The `metawhisp-mcp` precedent | §2.2 |
| 12 | «Nothing leaves the Mac» at step 1; the screen capture inside `chat.send` | §3.1, §4, §10 |
| 13 | There is no Right ⌘ hold question in push-to-talk mode | §2.1, §15 (US-1) |
| 14 | «Builds on MetaChat's tool loop» | header, §5 |
| 15 | An errand could not be found again | §5 (final card, titled Sheet); history in §13 (phase 2) |
| 16 | The phase-1 acceptance was too narrow | §15, §17.2 |
| 17 | Consent buttons and cookie banners | §7.1, §7.2 |

### Round 2

| # | Finding | Closed in |
|---|---|---|
| 18 | Any link counted as reversible; the fingerprint missed the form's action; a Yes could outlive a changed payload | §6.1, §6.2, §6.3, §7.1 |
| 19 | The router: cloud processing before it, conflicting fallbacks, late results, Esc, billing | §3.1, §10, §11 |
| 20 | New errands could postpone an update forever; pauses could stretch a run without end; no step or Apple Event accounting | §6.3, §8, §11 |
| 21 | The card: Stop vs the queue, no Stop before planning, no receipt, the renderer cannot update a card | §4, §5 |
| 22 | The lease: restoring over a newer clipboard or focus, lifetimes, priorities, the layout keystrokes | §7.5 |
| 23 | Cookie banners: detection, precedence over both risk checks, unsure detection | §7.2, §11 |
| 24 | Sleep: stale consent after wake; the 10-minute boundary | §8 |
| 25 | Cells: order of normalisation, read-back representation, formulas | §6.6, §17.1 |
| 26 | A malformed risk answer had two outcomes; the named-tab exception; «granted» in US-4 | §6.3, §7.1, §7.2, §15 (US-4) |
| 27 | Wrong claims: «five rounds», «nothing arbitrates», the Sparkle callback, what leaves the Mac | §5, §7.5, §10, §11 |
| 28 | DoD items that could not be checked | §15 (corner-case table), §17 |
| 29 | Laya's figures had no pinned source | §2.2, §6.2, §6.4, §14 |
