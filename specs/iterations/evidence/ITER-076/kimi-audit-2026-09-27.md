# ITER-076 — independent audit by Kimi Code CLI, 2026-09-27

**Asked by the owner** ("сделай аудит того что сделал через kimi cli; опиши ему подробно идею и суть
проекта"). Kimi Code CLI 2.1.1 (`kimi-code/k3-256k`) read the MetaWhisp commits `62c9848`…`3eae406` and
the worker's `0dfa0cf`/`075e5fd`, read-only, with a written brief of the product, the plan and the rules.
It split the work across four read-only exploration agents and spot-checked the most severe claims
itself.

**Its final message was cut off:** the provider returned `403 You've reached your 5-hour usage limit`
while it was writing the report. The findings below are its own synthesis, copied from its session log
just before the cut. Neither repository changed during the run (checked by hashing `git status` and
`git diff` before and after; the only new file in the tree came from another session).

**Verdict (Kimi): ACCEPT WITH FIXES.** No P0.

## Findings and what happens to each

| # | Kimi's finding | Level | Disposition |
|---|---|---|---|
| 1 | The grant question E is not wired: a grant button in another language with no structural mark can be clicked on Jev's `irreversible` answer alone (`AgentRun.swift`, `SafetyGuard.swift` say so in comments) | P1 | Known; closes in 1.3b (E wired, handed over at ≥ 0.20). The agent has no production caller yet |
| 2 | Frames are never walked: hosted payment and login forms (Stripe Elements) flag nothing | P1 | Known limit since 2.2a; observing each frame over CDP is in 3.1 |
| 3 | The swap copied the new build straight into /Applications with `ditto`: a kill or power loss mid-copy left a half-copied app | P1 | **Fixed (0.1c):** the build is copied beside the installed one and checked there, then one rename puts it in place |
| 4 | `.type` has no structural form check: a field whose change handler submits a POST form is judged only by the lexicon and Jev | P2 | Open; with L2 (type candidates get text) in 2.4 |
| 5 | The open/back postcondition accepts any landing on the same site, so a redirect to another page of the site counts as success | P2 | Open; noted for 2.4 (postconditions) |
| 6 | The gate's test floor was 1313 while the suite has 2057 | P2 | **Fixed** (`3b54478`) |
| 7 | The worker's daily cap is checked before and metered after the call: parallel requests can overshoot it | P2 | Open; bounded by the per-request token cap. Worker follow-up |
| 8 | The worker checks only each question's type: a Pro user shapes the token spend within the 128 KB body | P2 | Open; the daily cap bounds it. Worker follow-up |
| 9 | JevWire decodes choice and score probabilities with no range, sum or key checks, though its header says an answer outside its bounds never decodes | P2 | Open; jev-ultrafast's `validate_choice` goes into JevWire at the start of 1.3b (the 1.3 review asked the same) |
| 10 | `mw_keep_replaced` deleted the older kept build before moving the replaced one in: a kill between the two stranded it | P2 | **Fixed (0.1c):** the older one is renamed aside first and deleted last |
| 11 | `BrowserBridge` is `@MainActor`, while the plan wants the CDP connection off the main thread | P2 | Addressed by the 3.1 design: the connection and its JSON parsing live in their own actor; only strings reach the main actor |
| — | P3s: the answered model name is not checked; the worker forwards the upstream error text to the client; a cancelled send is logged as "unavailable"; review transcripts are not committed; no browser-harness notice yet (added with 3.1); `DiaScript` naming and `DiaSpike` in the shipping binary (removed in 3.1); `mw_rollback` quits by path, not pid; the cap fails open when D1 is down (deliberate); a checkbox's `checked` is not bound at the act; a select picks the first of duplicate option texts | P3 | Listed for the items they belong to |

## What Kimi checked and found correct
- Jev failure paths are fail-closed on both sides; the app never hangs waiting for Jev; retries are
  bounded.
- The license is checked before the proxy; no key ships in the app; logs hold numbers only; the body caps
  match on both sides.
- An approval is bound to what the user saw (act-time re-validation); approved addresses are never
  replayed; back goes only to addresses the loop opened.
- Secret fields are left out of the observation, and a secret field at the act stops it.
- The swap's traps, rollback order, the new build's checks, no force-kill, quoting.
- No Cyrillic in `Services/Agent` or the agent tests; no secrets or real names; the MIT notices present;
  commits match their messages; the tests are substantive.
