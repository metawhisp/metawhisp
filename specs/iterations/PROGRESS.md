# Iteration Progress

## Active specification

`ITER-076-jev-agent.md` — the Jev agent: voice or MetaChat → a browser errand or a web form.
- **Approved** by the owner on 2026-09-26 ("сделай"). It replaces ITER-075's order. Built for users.
- **The owner checks only the final product** (2026-09-28): the final task in the browser, then
  "выпускай". Everything before that is tested by me, in his Chrome once the bridge is ready.
- **Done:** 0.1, 0.1b, 0.1c (swaps over the working app); 1.1 (worker route), 1.2 (`JevWire`,
  `JevEngine`), 1.3 (the approved question texts); 2.1, 2.2a, 2.2b, 2.3, 2.3b (safety before any live
  run). Side iterations: ITER-078 (the Island, `b3a033b`) and ITER-079 (one owner for a voice question,
  `5d4a794`). All installed on the owner's Mac (last swap 2026-09-28 22:25), none released.
- **GitHub study (2026-09-28):** see ITER-076 "What the GitHub study found". It proposes an LLM planner
  and fallback beside Jev; the owner's decision on that is pending.
- **3.1 done (2026-09-28), the agent's hands in the user's Chrome:** `e092018` (a tab of its own, an
  isolated world — K1 closed — J1 end to end through Chrome), `7bbd438` (clicks and typing as a person's
  input, with the aim's checks), `0f885f4` (`ChromeLink`: one live connection with its states; a
  WebSocket client of our own, since URLSession opened up to three connections — three Allow prompts —
  for a dropped handshake), `59f740e` (the Dia spike removed). Gate green, 2168 tests. Not yet installed
  on the owner's Mac: nothing in the app uses it until 3.3.
- **Review of 3.1, round 1 (2026-09-29):** two reviewers; 2 P0 and 4 P1 found — a forged report after a
  move to another site, a trusted click that pressed a Delete inside the chosen row, a page ending the
  connection, windows left open, Stop and the Allow question — all reproduced, fixed test-first and
  mutation-checked (`27da9c0`…`29afe6b`); details in ITER-076 3.1. Gate green, 2188 tests.
- **Review of 3.1, round 2 (2026-09-29):** every round-1 fix confirmed; 1 P0 (a Delete nothing names a
  control, at a row's centre) and 8 P2 found, reproduced, fixed test-first and mutation-checked
  (`75d9505`…`04c2b60`). Gate green, 2195 tests.
- **3.1 closed (2026-09-29)** after Kimi's round 2: Stop during Chrome's Allow question ends it; the
  agent's world is made without the page's console.
- **Owner decisions (2026-09-29), in ITER-076:**
  - one send button;
  - MetaChat starts errands through a `runErrand` tool; Stage 4's router is dropped;
  - Jev goes through TypeSafe directly. The keychain keys are refused (401), so a new key is needed;
  - reuse before writing;
  - lanes of agents, each step verified by MiniMax-M3 and Kimi. Kimi's weekly quota ran out 2026-09-29; a read-only Claude agent reviews meanwhile.
- **Owner decisions, second round (2026-09-29):** the model beside Jev is MetaChat's own on the Pro
  server; it names sub-goals and checks "done" against quotes; every model text goes to the owner first;
  Jev sees all visible controls and ordinary field values, never secrets; answers carry a source link per
  item; tests run in a separate Chrome. Recorded in ITER-076.
- **State, 2026-09-29 evening** (lanes in worktrees `../MetaWhisp-lanes/lane-{a,b}`, not merged yet):
  - server (`~/Code/metawhisp-api`, merged to its main, not deployed): S1 — Jev through TypeSafe first,
    OpenRouter as fallback, the daily cap counts both. Deploy waits for a working TypeSafe key;
  - lane A (`agent/lane-a`, HEAD `7bc9e63`): A1 shared Pro LLM client; A2 the loop asks Jev with the
    approved questions; A2 review fixes; A3a each look carries the page's text and scroll; A3b owner
    decision 4 — ordinary field values shown, documents/keys/secret values hidden, a page asking for a
    secret no longer stops the errand, only a step that could send one. Gate PASS, 2269 tests;
  - lane B (`agent/lane-b`, HEAD `1945b8e`): B0/B1 errand contract and service; B1c fixes; B2 MetaChat's
    `runErrand` tool (no bubble, approved texts); B2 review fixes; the Jev router removed. Gate PASS,
    2284 tests;
  - approval page for the agent's model texts and four MetaChat items:
    https://claude.ai/artifact/4a6BWVCxgAyCLYFv4HNPiQ — waiting for the owner's answer;
  - reviews: independent read-only Claude reviewers of lane A (A2 fixes + A3) and lane B (B2 fixes) are
    running. The owner asked for Codex: its limit runs until 2026-10-03 19:14 (checked 2026-09-29).
- **Next:** A4/A6 (plan, sub-goal loop, field text, reader, done check, answer with links) once the texts
  are approved; S2 (the agent's model route on the server); B3 (the Island's errand stages); merge the
  lanes into this branch and run the gate; Codex review on 2026-10-03.
- **Reviews** go to an independent read-only Claude agent; every fix is test-first and each review fix is
  broken once on purpose to prove its test catches it.
- **2026-09-30 — iteration loop.** The owner asked for the rest as sequential iterations, Codex reviewing
  each, agents implementing (some on MiniMax-M3), in a 20-minute loop. The iteration list, owner decisions
  and journal live in `metawhisp-research/briefs/ITER-076/ITERATIONS.md`; stages and DoD in
  `PLAN-STAGES.md`; the whole-agent critic review in `CRITIC-REVIEW.md`. Review rule (owner): re-review
  only on P1, only the fix diff, at most three reviews per iteration.
  - Owner decisions: all ported model texts are used as they are (the owner adds the licence line himself).
  - Lane A: A3d committed (`e5d2701`, gate PASS, 2288 tests); Codex round 2 on it: NOT ACCEPT → I-02.
  - **I-01 closed** (server, `agent/lane-s4` `33e78c9`, not deployed): one cutoff for everything, cost
    read from each answer, schemas and tool calls checked, reservations as holds kept all day once a
    provider is asked, a bounded cutover window in `deploy.sh`. Codex ACCEPT on its third check; one P2
    (Cloudflare activating after a timed-out upload) checked at the deploy.
  - **I-02 closed** (lane A, `agent/lane-a` `596127b`, gate PASS 2323 tests): secrets checked whole (encoded
    addresses, frames, cut values, remembered kinds and forms, bare one-time/backup codes, IBANs), no Yes
    without Jev's grant answer, payment handed over in any language when a total shows (checked again after a
    Yes and at the act). Codex ACCEPT on its third check.
  - **I-03 closed** (lane B, `agent/lane-b` `0cb3f53`, gate PASS 2328 tests; implemented by Claude Code on
    MiniMax-M3, narrowed and finished by the orchestrator): an errand starts only from a call that is the whole
    answer (one envelope, never repaired); errand records owner-only (0700/0600), at most 100 and 30 days,
    cleared with MetaChat's history and never brought back by a late run; examples stay in the answer, consumed
    calls never do. Codex ACCEPT on its third check; one P2 moved to I-06.
  - **I-04 closed** (`agent/merge` `e44a0ca`; this branch fast-forwarded to it): lanes A and B merged; the
    gate fails on any critical test that did not run or no longer exists (recorded inventory, named allow-lists
    for design, screen and Chrome skips, its own 14 self-checks); `runErrand` and the browsing rules are offered
    only when the errand service has a runner — until then MetaChat's rules are byte for byte the released ones.
    Gate PASS, 2463 tests. Codex ACCEPT on its first check; its two P2 fixed.
  - Owner items raised: the keyboard-layout corpus check never ran (needs the corpus files, or drop the claim).
  - **I-05 closed** (`agent/merge` `e55f534`; this branch fast-forwarded): `AgentRun` is an `ErrandRunner` —
    progress and hand-over reports, rows kept live, honest endings (no Pro, the day's limit, service down),
    a failed page read is a miss, a lost browser ends as lost, a No is final by what the action does, Stop
    keeps what was sent and returns within 10 s, spend recorded; a factory from a planner, engine, writer and
    Sheet, proven end to end in headless Chrome. The app's factory stays unset until a planner and a writer
    exist. Gate PASS, 2518 tests. Codex ACCEPT on its second check.
  - **I-06 closed** (`agent/merge` `9cb1070`; this branch fast-forwarded; implemented on MiniMax-M3, reworked
    by the orchestrator): one errand per goal (Unicode case-folded), a closed send starts none, an errand
    that started is no failed send and its result is saved after the reply that started it (dropped with a
    clear); the goal may name only addresses the user said — typed or spoken words, never an attached screen
    card — hosts compared whole, links read by their decoded parts; approved texts M2–M4; a round loses only
    the envelopes of the tool it called. Three Codex checks (3 P1, then 1, then 1 partly fixed); the last fix
    goes into I-06a's review (owner, 2026-09-30: "продолжай"). Gate PASS, 2538 tests.
  - Owner, 2026-09-30, on the result lines: the day's limit — approved; no Pro — the agent is simply not
    offered without Pro; service down — failures are to be reported to him, and every agent action logged.
  - **I-06a closed** (`agent/merge` `db88a31`; this branch fast-forwarded): every errand event — plan, step,
    page miss, wait for the service, question and its closing (yes / no / expired / stopped), hand-over, ending —
    in the errand's record and, line for line, in the app log (`[Errand <id8>] #n …`, append-only numbering),
    only numbers, kinds, ids, roles and a host; the agent is offered only with Pro, read per request; the
    day's-limit line (owner-approved). Also from its review: a link's addresses are read from the URL the system
    resolved (query names included). Codex ACCEPT on its second check; its two P2 fixed; five racy service tests
    fixed. Gate PASS, 2569 tests.
  - **I-06b closed** (app `agent/merge` `8c43ae0`; server `agent/lane-s4` `63a886a`, not deployed): the server
    records every 5xx of a Pro route (route, status, providers, ms — no content) and e-mails the owner at most
    hourly (`OWNER_ALERT_EMAIL` secret; flushed by ordinary traffic, no cron); a failed errand's event kinds and
    numbers go to `/api/pro/errand-report` under a closed contract pinned on both sides; the app's queue is
    0600, ≤20, ≤7 days, cleared with MetaChat's history. Found on the way: a spent call could answer 503 +
    Retry-After 60 instead of 504 (the deadline was re-read from the clock) — fixed. Codex ACCEPT on its second
    check. App gate PASS, 2586 tests; server tests all pass.
  - The "service did not answer" line (owner-approved 2026-10-01) is in the code (`2d3670b`); a flush awaited is
    now a flush done (`002378f`, the gate's 1-in-3 flake in the reporter).
  - **Server live (2026-10-02 11:39 UTC, deploy `3aebcd7`):** Jev through TypeSafe first, OpenRouter the
    fallback; firm daily ceilings in D1; failures recorded and mailed to the owner at most hourly. Checked live:
    401 without a license, Jev 200 in 0.55 s (`jev-1.13.0`), the D1 rows.
  - **I-07 closed** (`agent/merge` `d59b012`, after Codex's 3 reviews — `4aeb714`, `31cffae`, `e8a29f3`):
    typing that lands, written in one task with its field's last check (the reference's own one-task path),
    trusted input; a page read once it has gone quiet, every call of a settle bounded, a required landing judged
    on where the page was last read; suggestions waited on only in the field's own list. **Enter and Escape were
    ported, then removed:** what a page's own key or submit handler does cannot be bound from inside the page,
    and nothing irreversible may happen without the Yes (Codex review 2 P1-2, review 3 P1-1). Jev's labels are
    again the approved pre-I-07 list. Gate PASS, 2629 tests; mutations all caught (35 + 6 + 6 + 4).
  - Waiting for the owner: whether the user's Yes covers what a site's own code does in reaction to the
    approved act (Codex holds that it does not; full enforcement would need blocking the tab's requests).
  - Next: I-08 (hands 2: made-up dropdowns, see-through checkboxes, script-only controls, date, read-only and
    file fields); its Codex review also checks I-07's last fix (`d59b012`).

## Previous specification

`ITER-075-assistant-core.md` — one assistant core. Jev routes every request; one search over
complete data; chat and voice; browser errands; forms. The owner approved the plan and its order on
2026-09-25 ("начинай по порядку"). On 2026-09-26 ITER-076 moved the agent first. ITER-075's remaining
items (1.2–1.4, 1.5b, 1.7 and step 2) follow ITER-076.

- **Process (owner, 2026-09-25):**
  - GLM-5.3-Flash writes every change from detailed instructions: tests first, then code.
  - After that: the regression gate, a review, fixes, a commit, and then the next item.
  - Codex's quota runs out until 2026-09-29. Meanwhile each iteration is reviewed by an independent
    read-only Claude agent, and the reviews are re-run with Codex when it is back.
- **Step 0 (safe install, permissions that stay) — in progress.** The checklist is in the spec.
  - 0.1 `AppIdentity` is done (`6d4d494`), with tests and the gate green (1811 tests). Its review asked for three
    fixes in this iteration: a stronger literal guard, the production Recovery path pinned, and the
    SwiftData store URL pinned. All three are done.
  - Two findings moved to 0.4 and 0.6: the Dev app must not delete the shared models, and the
    scripts and Info.plist must build a separate Dev app.
  - 0.2 is done (`318e556`): the keychain tells missing from unreadable; writes never delete first;
    a sign-in the keychain refused says "Pro on for this session only", never "Pro activated"; the
    next launch explains a sign-out it caused. The gate is green (1830 tests). Review round 1 raised 5
    points and all were fixed; round 2 accepted.
  - 0.3 is done (`46ab8ba`): PermissionMonitor watches Accessibility and Screen Recording for the life
    of the app with no give-up. A grant re-arms Right ⌘/⌥, ⌘⌥O and the layout fix, and starts screen
    context, with no restart. A guard catches any new global key monitor that nothing re-arms. The gate
    is green (1841 tests). Review round 1 raised 2 major and 3 minor points, all fixed; round 2 accepted.
  - 0.4 is done (`40aa9c3`): a copy that is not the owner's app behaves as a guest. No updater, no global
    keys by default, and it never deletes the shared models. Tests no longer download into the owner's model
    folder. Review round 1 caught a test that called a real delete on the owner's model, which was fixed.
    The gate is green (1847 tests). Open question Q3 for the owner: share the model caches read-only, or
    keep separate ones?
  - 0.5 is done (`5235ed1`): the app writes what it is busy with to `activity.json`, and a SIGTERM quits
    it through the normal path, meeting rescue included. Round 1 caught that a SIGTERM during a meeting
    would hang the app, which is fixed: the quit now starts from a run-loop timer. Round 2 accepted. The gate is
    green (1857 tests).
    - `hot-swap.sh` is off until 0.6 rewrites it.
    - Known limits carried into 0.6:
      - an unbundled `swift run` shares the Dev app's lease file;
      - a quit held up by an open dialog is still pending when the script gives up.
    - Two stale worktrees under `.claude/worktrees/` still hold the old `hot-swap.sh`; don't run them.
  - 0.6 is split in two:
    - 0.6a is done (`72d6b88`): `build.sh --dev` installs "MetaWhisp Dev" only, and no build or install
      script stops the working app.
      - Review round 1 caught an interrupted rollback that could lose the Dev app; fixed. Round 2 accepted.
      - The gate is green (1877 tests).
      - Open owner step: delete the old `~/Applications/MetaWhisp.app` that the old `build.sh` left there.
    - 0.6b is done (`d6efb80`): the release smoke test is `MetaWhisp --self-check`, which exits before
      the app exists, and `release.sh` never stops the working app.
      - Review round 1 found no proof and a possible hang; fixed. Round 2 accepted.
      - The gate is green (1890 tests).
      - The first run on a real bundle is part of 0.7.
  - 0.7, the live check, is in progress.
    - Done without the owner (2026-09-26 01:15):
      - `bash hot-swap.sh --no-launch` built and installed `~/Applications/MetaWhisp Dev.app`, and did not
        start it;
      - the signing test passed with no prompt;
      - the self-check on the real bundle printed three `ok` lines, MLX on the GPU included, then
        `SELF-CHECK OK`;
      - the working app's process and signature are unchanged.
      - Evidence: `evidence/ITER-075/0.7-dev-bundle-selfcheck.txt`.
    - Still needs the owner:
      - start the Dev app and grant it its own permissions;
      - the SIGTERM-during-a-meeting check in the Dev app;
      - the working app showing `accessibility=yes`, `screen=yes`, `pro=YES`.
    - Its running build (1.3.37, 11:51) predates 0.2–0.5, so it needs a restart after the Accessibility
      toggle, and a release to get the fixes.
- **Step 1 (every call recorded once) — started 2026-09-26.**
  - 1.1 is done (`abf26be`): a recurring meeting ends at its own occurrence's end, and the end check waits
    10 minutes from the session start.
    - The cause: an identifier lookup that answered with the series' first occurrence.
    - Review round 1 raised 5 minor points, all fixed; round 2 accepted.
    - The gate is green (1903 tests).
  - 1.6 is done (`2d5eaa3`): the backfills never blank a conversation, and the project backfill checks each
    conversation once.
    - Review round 1 (3 major) and round 2 (4 follow-ups): all fixed and accepted.
    - The gate is green (1920 tests).
    - Owner decision before the release: keep the one-time project pass over conversations from before
      2026-04-25?
  - 1.2 and 1.3 wait for owner decisions (automatic restart after a stop that kept audio; a manual recording
    during a calendar event). 1.4 comes after 1.3.
  - 1.5a is done (`da06c54`).
    - Every summary goes through a queue on disk, and runs take turns.
    - The close summarizes its own conversation first.
    - The 522 untitled conversations are queued once.
    - The Pro proxy now says what failed: 503 when unavailable, 4xx when the request is refused, 422 for an empty
      answer, and an optional deadline. Deployed with the owner's OK on 2026-09-26.
    - Review: 6 rounds, round 5 accepted. The gate is green (1968 tests).
    - Next in 1.5b: the failed set and the Library states, Regenerate through the queue, and the delay after an
      outage. After that, 1.7 (durable recording) needs no owner decision.
- **Owner actions still open:**
  - dictation: re-toggle MetaWhisp in Accessibility, then sign in to Pro — no Pro keychain item exists
    now;
  - the decisions listed at the end of the spec, each asked when its step comes.

## Previous specification

`ITER-074-agent-layer.md` — agent layer (browser use).

- **State (2026-09-24):** design revised after two adversarial review rounds;
  all 29 findings mapped to the sections that close them (Appendix A). Jobs
  (§1) and the Definition of Done (§17) added. The iterations that need no
  owner have been built in the order of §16.
- **Open:** decision 16 — what happens when the Mac sleeps mid-errand (§8
  carries a proposed default). Which job groups beyond J1–J2 join phase 1.
- **Done:** I-0.1 code (`537e965`): permission check, AppleScript builders,
  dormant spike; 39 tests; two Codex rounds. Its live check waits for the owner
  session.
- **Done:** I-T1 (`5fecea9`): the page harness — WKWebView per tab, sealed
  from the network (CSP, block-all content rules, DNS prefetch off, routed
  navigation), navigation-bound load state, deadlines; 26 tests.
- **Owner-free iterations of §16 — all built (2026-09-24):** I-0.1 code,
  I-T1, I-0.3, I-1.1, I-1.2, I-1.3, I-1.4, I-T2a/b/c. J1 runs end to end on
  the fixture pages through the production loop (`AgentRunTests`).
- **Reviews:** Codex rounds 5–10 raised 26 points. 25 were checked against
  the code, confirmed, and fixed test-first (`e5ecb78`, `ebe296e`, `87e99c4`,
  `41af233`, `962eacf`, `99bf8be`); one (values after a report cut short) was
  answered with reasoning, which round 9 accepted. Rounds 9 and 10 accepted
  the previous round's fixes. Round 11 (on the loop `6d3eeae`, `99bf8be` and
  `c4a8ab8`) accepted `c4a8ab8` and raised five more — Stop and the ceilings
  at every effect, a Yes bound in the acting script, hidden secrets, grants —
  all confirmed and fixed in `5854de5`, written by GLM-5.3-Flash from the
  orchestrator's instructions. Rounds 12–22 each accepted the previous fix
  and raised one to eight more, every one confirmed in the code and fixed
  test-first by GLM (`dc0fb05` … `b34001c`): Stop reaching the Sheet, a sent
  action never lost, paid calls within the ceilings, controls inside a
  sensitive field, consent that grants more than cookies, submitters that
  could name a form — and, in rounds 15–22, the label reader: shadow roots,
  slots, every seam read both ways, text alternatives, stylesheets and a
  control's contents left out, a length limit that fails closed, and the
  usual English names of a secret. Two points were answered with reasoning
  and accepted (a highlight on a short word inside a longer one; a
  passport's expiry). Round 23 (on `b34001c`) accepted it with no new
  finding: the label reader is closed.
- **Whole-layer review (2026-09-24, at `ab6a131`):** Codex and a Claude
  review agent, each over every file in `Services/Agent/`. Both: not ready
  for the owner's live session. 15 findings, each checked against the code:
  5 safety (S1–S5), 10 in the loop against the spec (L1–L10), 1 known limit
  (K1) — `evidence/ITER-074/whole-review.md`, with the owner's decisions it
  needs.
- **Tests (2026-09-24):** 1801 in the suite, gate PASS; the agent layer's 20
  suites hold 331, all green.
- **First live check (2026-09-25, Chrome — the owner's choice):** MetaWhisp
  drove a real browser for the first time: the macOS prompt, the owner's OK, a
  tab opened, the page loaded in 545 ms, JavaScript in 33 ms, the tab closed.
  Finding: the new tab becomes the active one — the phase-1 bridge must open
  its tab without taking the user's. The first try was refused silently: the
  installed app had no Apple Events usage string, because hot-swap.sh swapped
  only the binary; it now copies Info.plist as build.sh does. Open: Developer
  ID signing fails from command-line tools (errSecInternalComponent) although
  the keychain is unlocked — MetaWhisp runs ad-hoc signed until that is fixed
  (`evidence/ITER-074/I-0.1-live-chrome.txt`). GLM's key is unreachable the
  same way, so GLM cannot write code until then.
- **Design changes made along the way — for the owner to know:**
  - a dense page is asked about with «more» (next candidates) instead of a
    region stage, so every action is reachable in ≤ 20-option questions;
  - back opens the previous address the errand's tab showed, never the
    page's own history (a page can stuff it);
  - a bare «Accept» cookie button is never pressed — only one that names
    cookies; a blocking banner with nothing else counts as unsure and the
    site is skipped (still no question to the user, decision 15);
  - a one-word request is a question; the router's 2 s deadline is a moment
    fixed before the engine is asked;
  - a link whose address is at the 2000-character limit offers no action;
  - select options: up to 1000 per select, 2000 per page.
- **Next:** first the whole-layer review's findings — S1–S5 before any live
  run — then owner session 1 (§16): I-0.1 live check (macOS prompt, denial,
  revocation, Dia's JavaScript toggle), I-0.2 Sheets (paste, apostrophe,
  read-back), I-0.4 prompts and typed questions (ported, owner-approved),
  I-0.5 Jev key and eval, I-0.6 go / no-go. Open questions: decision 16
  (sleep), Russian-language test cases (tests are English-only), which job
  groups beyond J1–J2 join phase 1.
- **Disk:** 2026-09-24 18:05 the disk filled (121 MB free) — another session's
  scratchpad held 6.1 GB of site copies. The owner chose to delete unavailable
  simulators (there were none); space came back to ~3–4 GB on its own.
- **Coder:** GLM's plan quota ran out at 16:48 CEST and was back by 20:18 CEST;
  in between the orchestrator wrote the code (owner's choice). From round 11
  on, GLM-5.3-Flash writes the code again from detailed instructions.
- **How iterations run:** GLM-5.3-Flash (`glm-codex`, model `glm-5.3-flash`)
  writes code from detailed instructions. It cannot build inside its sandbox —
  SwiftPM's own sandbox cannot nest — so the orchestrator compiles and feeds
  the errors back. Red and green runs are saved in
  `specs/iterations/evidence/ITER-074/`. Every finished iteration gets a Codex
  review (`~/.hermes/node/bin/codex`, prompt on stdin).
- **Owner session 1** (after I-T2): I-0.1 live check, Sheets, prompts
  approval, Jev key and eval. Also a question: Russian-language fixtures, since
  tests are English-only.
- **Input for I-0.4:** `ITER-074-prompt-sources.md` (untracked until the
  prompts are ported; its repo paths name open-source authors, which the
  licence notices will name anyway).

The sections below describe ITER-062 and were last updated 2026-08-16.

## Current iteration

I3 in progress. The first local vertical slice is wired into the normal app:
it buffers one word in RAM, applies only conservative local RU↔EN confidence,
revalidates the focused AX text field, selects the target macOS input source,
and shows a 1.4-second non-activating toast. It also recognises two clean
Shift releases in 400ms, then converts the selection or only the immediate
previous word. It never logs or persists typed text. The remaining live check
is physical input in TextEdit; UI automation actions deliberately do not
traverse a listen-only event tap. Live diagnostics proved that the monitor and
EN→RU confidence path see the candidate but ran before the target app had
committed its separator, so the AX gateway safely returned `staleTarget`.
Automatic correction now waits 16ms, revalidates the focused field, and logs
only the outcome (never text). Double Shift delivery is also proven by live
logs; its failed manual conversion path previously depended on a full `AXValue`
read. It now reads only selected text or a 128 UTF-16-character Accessibility
window immediately before the caret, with the native-editor `AXValue` fallback
bounded to the same window. A live editor then acknowledged the AX text-write
but visibly retained the original text. The replacement path now verifies the
exact bounded range before emitting feedback; when direct AX mutation is not
real, it uses the shared selected-text paste seam, confirms the result, and
restores the full clipboard snapshot only if its change count is unchanged.
The first verified-replacement build then logged a candidate without an
outcome: the controller had cancelled its own pending correction on a later
key event. Pending automatic work is now cancelled only by shutdown or a
newer candidate; Double Shift also records a content-free gesture marker for
the live test. Controller dependency seams now allow deterministic async
tests to prove automatic and Double Shift dispatch reaches the text gateway
and switches input source only after a verified success (including a failed
replacement non-switch case). The focused test profile is 38/38 green and the
full package suite is 830 passed / 4 skipped / 0 failed. The installed
Developer-ID-signed local app is active; only the physical global event and
real AX editor mutation still require native keyboard input.

The first physical retry reached AX replacement but stopped immediately when
the clipboard fallback tried to call `copy()` on `NSPasteboardItem`; that
Objective-C exception left the correction without a terminal result. The
fallback now copies every available pasteboard representation explicitly,
waits 150 ms for the AX selection to commit, posts Command-V directly to the
checked target process, verifies before restoring the transaction, and
preserves an intervening user copy. Automatic correction retries exactly once
when the editor has not yet committed its separator, then otherwise fails
closed. The regression tests for both restoration branches and the stale-target
retry are green; the final local Developer-ID-signed build is installed and
awaits the same physical retry.

## Master checklist

- [x] Competitor and platform research
- [x] User stories, permission contract, production architecture
- [x] UI, visual feedback, privacy metrics, and test gates
- [ ] I0 signed TCC/event-tap proof — active state verified; physical-event
  delivery pending
- [x] I1 pure mapper/confidence TDD — 8 tests green
- [x] I2 replacement gateway/input-source TDD — 7 tests green
- [ ] I3 controller/auto/Double Shift TDD — automatic and Double Shift paths
  wired; signed-app physical event/AX proof remains
- [ ] I4 UI/metrics
- [ ] I5 release verification

## Known constraints

- Automatic global correction cannot operate until macOS permits the required
  Accessibility/Input Monitoring path. The setting defaults to requested ON,
  not falsely active.
- No raw typed content may be retained or logged.
- Existing working-tree changes are user-owned and out of scope.

## Next step

Repeat the original scenario in the editor where the toast appeared without a
text change. A toast must now mean the text changed. In TextEdit, switch to
English, type `ghbdtn` without a trailing space and press two clean Shift
taps; it should become `привет`, change the input source to Russian, and show
the EN → RU toast. Do not use a password or sensitive input for this check.
