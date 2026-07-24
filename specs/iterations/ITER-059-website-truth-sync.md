# ITER-059: Website truth sync — sell the product we actually ship {#root}

> Status: PLAN — awaiting founder OK. Created 2026-07-24.
> Source: live site walkthrough 2026-07-24 (landing, /pricing/, /account/,
> /download/ — all fetched and read in full this session).
> ⚠️ Rollout rule: site deploys are a SEPARATE action, never during an app
> release (2026-05-09 incident: lost 6 blog posts + broke the DMG download).
> The appcast CF redirect and /downloads/MetaWhisp.dmg redirect must not be
> touched — verified working today (302 → GitHub v1.3.18).

---

## 0. Audit verdict {#verdict}

The site sells the 2024 product: dictation only. Verified today:

1. **Flagship invisible.** Meetings, screen intelligence, second brain, tasks,
   chat — zero mentions on landing AND pricing. Meetings exist only as a blog
   link in the footer.
2. **Site contradicts the product in three places:**
   - Landing FAQ + compare table: "really free, no limits", "Correct/Rewrite
     use your own OpenAI API key", "Price: Free" — while /pricing/ sells Pro
     $7.77 "Built-in". Two incompatible stories on one site.
   - /pricing/: "60 min/day cloud transcription" (+ FAQ about the daily cap) —
     stale: the quota is MONTHLY per billing period since ITER-054.
   - /download/: "Version 1.0" (product is 1.3.x) and a "Bypass Gatekeeper:
     Right-click → Open" instruction that is wrong AND scary — the app is
     notarized + stapled; Gatekeeper accepts it (verified on the live DMG).
3. **"Get Pro" → bare login wall.** /account/ shows only "Sign in" with no
   plan recap, no "sign in to continue to checkout" context — and the Google
   button renders in SERBIAN («Пријавите се помоћу Google-а»). Prime buyer
   drop-off point.
4. Minor: hero mocks "$12/month" apps next to our own $7.77 sub; DMG size says
   16.6 MB (actual ~17.1 and drifting).

## 1. User stories {#stories}

- **US1.** As a visitor, I want to see what MetaWhisp actually does today
  (dictation + meetings + screen memory + tasks + chat), so I can decide it's
  worth installing. *Acceptance:* flagship sections on the landing; pricing
  lists what Pro actually includes.
- **US2.** As a reader comparing plans, I want ONE consistent story about
  free vs Pro, so I don't feel tricked after install. *Acceptance:* landing
  FAQ/compare and /pricing/ agree; quota wording matches the product
  (monthly, resets on billing day).
- **US3.** As a buyer clicking "Get Pro", I want to know what happens next,
  so I finish the purchase. *Acceptance:* /account/ shows the chosen plan +
  "Sign in to continue to checkout"; Google button in English.
- **US4.** As a downloader, I want install instructions that match reality,
  so I'm not scared off. *Acceptance:* no Gatekeeper-bypass steps (replaced
  with "notarized by Apple — opens normally"); no stale version numbers.

## 2. Invariants {#invariants}

- **I1 — Never break the money paths.** /downloads/MetaWhisp.dmg redirect and
  the appcast redirect stay untouched; verify with `curl -IL` after deploy.
- **I2 — Blog untouched.** No regeneration/rollback of existing posts
  (2026-05-09 incident class).
- **I3 — No fabricated numbers.** Every claim on the site must be true of the
  shipped product (Rule 13); anything unverifiable gets cut, not embellished.
- **I4 — Deploy = its own change window**, never bundled with an app release.

## 3. Sub-iterations {#plan}

### 059.1 — Truth fixes (small diffs, high trust impact) {#i1}
- [ ] /pricing/: quota wording → monthly per billing period; kill the
      "60 min/day" FAQ entry; add what Pro actually covers today (meetings
      transcription minutes, cloud voices/TTS, cloud LLM processing, semantic
      search) — exact list confirmed against the product before writing.
- [ ] Landing FAQ + compare table: reconcile with Pro (BYOK stays as the Free
      path, Pro as "no keys needed"); compare-table price row → "Free + Pro".
- [ ] /download/: remove Gatekeeper-bypass block → "Notarized by Apple; opens
      like any Mac app"; version string removed or made dynamic; size stated
      approximately ("~17 MB").
- [ ] Post-deploy verification (Rule 6): curl every changed page + both
      redirects; screenshot pass in the browser.

### 059.2 — Flagship on the site {#i2}
- [ ] Landing: new sections after the dictation story —
      "Meetings: record, transcribe, recap" · "Your Mac remembers: screen
      memory + second brain (text, not screenshots — stays on your Mac)" ·
      "Tasks that surface themselves" · "Chat with your history".
      Honest privacy framing throughout (on-device OCR text, retention,
      one-click delete).
- [ ] Nav/footer: Features → add flagship anchors; keep AEO footer block in
      sync.
- [ ] Hero: keep dictation as the hook, add one line that it's also a
      second-brain ("...and it remembers what you worked on").
- [ ] No invented testimonials/metrics (Rule 13) — feature descriptions only.

### 059.3 — Get Pro flow {#i3}
- [ ] /account/: when arriving from "Get Pro", show plan summary + "Sign in to
      continue to checkout"; plain sign-in copy otherwise.
- [ ] Google button locale forced to English (`hl=en` / data-locale on the GIS
      embed) — kill the Serbian.
- [ ] Walk the full path once on production: Get Pro → sign-in → checkout →
      license → deep-link activation (with founder's test account) and record
      where it breaks, if anywhere.

## 4. Corner cases {#corners}

Cached pages after deploy (CF cache purge for changed URLs only) · the
"FOR AI ASSISTANTS & SUMMARIZERS" footer block must mirror new claims ·
pricing page annual/monthly toggle keeps working · RU-locale visitors still
get English UI (site is EN-only by design).

## 5. Definition of Done {#dod}

1. Zero contradictions between landing, pricing, download page, and the
   shipped product (each claim spot-checked against the app).
2. Flagship visible on landing + pricing; privacy story honest.
3. Get Pro path walked end-to-end on production without dead ends; Google
   button English.
4. Both money redirects verified post-deploy; blog intact (post count
   unchanged).

## Changelog
- [2026-07-24] Plan created from the live site walkthrough (all pages fetched
  this session; contradictions verified against product code and worker).
