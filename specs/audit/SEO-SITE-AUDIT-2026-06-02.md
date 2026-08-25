# MetaWhisp Website SEO Audit

Date: 2026-06-02

## Scope

Report-only review of the rendered production website at
`https://metawhisp.com/`. The marketing-site source code is not present in the
current `MetaWhisp` checkout or neighboring local repositories, so this report
records production defects and handoff criteria rather than template-level
patches.

## Goal

Produce a verified SEO backlog that another implementation pass can apply to the
marketing-site repository without rediscovering the defects.

Success criteria:

- crawl every HTML URL listed in the sitemap;
- validate titles, descriptions, canonicals, H1 tags and JSON-LD;
- crawl same-origin links and sitemap/schema image assets;
- compare public privacy and compliance claims with the desktop app behavior;
- separate proven technical defects from manual checks and policy risks.

## Verification Baseline

- Sitemap HTML URLs crawled: `90`
- Sitemap HTML URLs returning `200`: `90`
- Blog articles: `76`
- Same-origin links checked: `87`
- JSON-LD parse errors: `0`
- Pages missing title, meta description, canonical or exactly one H1: `0`
- Duplicate titles: `0`
- Duplicate descriptions: `0`
- `/account/`: correctly excluded from sitemap and marked `noindex, nofollow`
- HTTP to HTTPS, `www` to apex and slash normalization redirects: working
- Unknown URL: correctly returns `404`

Core Web Vitals are not covered by this pass. The PageSpeed Insights API returned
`429`, and the marketing-site source checkout does not include a local Lighthouse
setup.

## Findings

### SEO-001 — Privacy copy contradicts cloud transcription behavior

Priority: `P1`

The production privacy page makes unconditional statements that MetaWhisp
processes everything locally, sends exactly zero network requests and never
transmits audio or transcripts:

- `https://metawhisp.com/privacy/`

The desktop app does transmit audio in cloud modes:

- `Services/Transcription/CloudWhisperEngine.swift:60`
- `Services/Transcription/CloudWhisperEngine.swift:83`
- `Services/Transcription/CloudWhisperEngine.swift:132`

The app also has automatic Sparkle update checks:

- `Resources/Info.plist:64`

Why it matters: privacy is a trust signal for this product and the page is a
primary landing page for privacy-sensitive queries. Contradictory statements can
damage conversion and create legal risk.

Fix:

1. Rewrite the page by mode: local transcription, cloud transcription, optional
   AI post-processing, license checks, update checks and initial model download.
2. Update the privacy meta description and every repeated privacy claim across
   articles, schema and machine-readable summaries.
3. Have legal review the final wording before deploy.

Acceptance:

- no unconditional "zero network requests" or "never transmit audio" claim
  remains where cloud modes exist;
- each networked mode states what data leaves the device and why.

### SEO-002 — HIPAA claims need legal review and substantiation

Priority: `P1`

Multiple indexed articles make categorical claims such as "fully
HIPAA-compliant", "inherently HIPAA-compliant" and "No BAA legally required":

- `https://metawhisp.com/blog/dictation-for-doctors-hipaa/`
- `https://metawhisp.com/blog/offline-voice-to-text-macbook/`
- `https://metawhisp.com/blog/hipaa-local-dictation-mac/`
- `https://metawhisp.com/blog/hipaa-compliant-speech-to-text-mac/`

The first article also states that a BAA is available on request for Pro cloud
users. This must be verified before publication.

Why it matters: local processing can reduce exposure, but it does not by itself
prove HIPAA compliance. HHS requires regulated entities to assess risks and
implement appropriate safeguards.

Fix:

1. Send all healthcare pages through legal review.
2. Replace categorical claims with precisely scoped, substantiated wording.
3. Confirm or remove the Pro cloud BAA statement.
4. Add reviewed attribution and a clear boundary between product features and a
   customer's compliance responsibilities.

Acceptance:

- every HIPAA/BAA claim is traceable to legal-approved evidence;
- no page implies that installing local software alone establishes compliance.

### SEO-003 — Sitemap publishes a URL with a conflicting canonical

Priority: `P1`

The sitemap contains:

- `https://metawhisp.com/blog/office-365-productivity-mac/`

That page returns `200`, but its rendered canonical is:

- `https://metawhisp.com/blog/microsoft-productivity-apps-mac/`

Both URLs are present in the sitemap and both return content.

Why it matters: the sitemap and `rel="canonical"` send contradictory indexing
signals.

Fix:

- if the pages are duplicates, keep the Microsoft URL, remove the Office URL
  from the sitemap and add a permanent redirect;
- if they are intentionally distinct, make the Office URL self-canonical.

Acceptance:

- every sitemap URL is self-canonical or intentionally redirected outside the
  sitemap;
- the deprecated URL returns a permanent redirect if it is a duplicate.

### SEO-004 — Sitemap image entries point to missing files

Priority: `P1`

Eleven sitemap image URLs return `404`:

```text
/images/blog/offline-voice-to-text-macbook/og.png
/images/blog/metawhisp-vs-wispr-flow/og.png
/images/blog/why-local-ai-models-macbook/og.png
/images/blog/how-to-transcribe-wav-file/og.png
/images/blog/voice-to-text-for-journalists-mac/og.png
/images/blog/speech-to-text-in-word/og.png
/images/blog/voice-to-text-for-therapists-mac/og.png
/images/blog/wispr-flow-pro-vs-free-worth-it/og.png
/images/blog/best-tools-for-productivity/og.png
/images/blog/voice-to-text-for-novelists-mac/og.png
/images/blog/dictate-to-obsidian-mac/og.png
```

The `dictate-to-obsidian-mac` Article JSON-LD image also points to its missing
file.

Fix:

- deploy the missing assets or omit invalid image entries until the assets
  exist;
- add a build-time URL existence check for sitemap and schema image assets.

Acceptance:

- every sitemap and JSON-LD image URL returns `200`.

### SEO-005 — Indexed pages link to missing internal targets

Priority: `P2`

The production crawl found these internal `404` targets:

```text
/blog/legal-dictation-mac/
/downloads/office-365-productivity-mac.pdf
/blog/what-is-voice-to-text/
/blog/wispr-flow-security-concerns/
```

The iPhone settings screen also links to a missing legal page:

- `/Users/android/Code/MetaWhispPhone/App/Views/SettingsView.swift:326`
- target: `https://metawhisp.com/terms`

Fix:

- create the intended pages, correct the links or remove them;
- deploy a Terms page and keep the product links aligned with its final URL;
- add a same-origin link checker to the site build.

Acceptance:

- no published internal link returns `404`;
- `/terms/` exists and `/terms` redirects consistently.

### SEO-006 — Article structured data has stale dates and author type drift

Priority: `P2`

Fifteen Article JSON-LD payloads have a `dateModified` value that differs from
the page `article:modified_time` and sitemap `<lastmod>`. Example:

- `/blog/how-to-use-dictation-on-mac/`: schema `2026-03-26`, head and sitemap
  `2026-05-15`

Eight older articles describe Andrew Dyuzhov as an `Organization` while linking
to his author profile. The other articles correctly use `Person`.

Fix:

- generate schema, Open Graph metadata and sitemap dates from one source field;
- migrate legacy articles to one author object using `Person`.

Acceptance:

- Article `dateModified`, page metadata and sitemap lastmod agree;
- author type and author profile agree on all articles.

### SEO-007 — SoftwareApplication schema is stale and partially broken

Priority: `P2`

The homepage SoftwareApplication schema contains:

- screenshot URL `https://metawhisp.com/og-image.png`, which returns `404`;
- `fileSize: "7.5 MB"`, while the live DMG is `16,648,546` bytes;
- `softwareVersion: "1.x"`, while the live appcast reports `1.3.9`;
- `applicationCategory: "ProductivityApplication"`, which is not in Google's
  documented supported category list.

The homepage, pricing and download schemas also do not include a real review or
aggregate rating, so they do not satisfy Google's Software App rich-result
requirements.

Fix:

1. Generate release facts from the appcast or release manifest.
2. Point the screenshot to an existing crawlable image.
3. Use a supported category such as `UtilitiesApplication` if accurate.
4. Add only real, verifiable review data; otherwise accept that this markup is
   descriptive rather than rich-result eligible.

Acceptance:

- schema release facts match the current downloadable build;
- all schema URLs return `200`;
- no fabricated rating or review is added.

### SEO-008 — Raw Markdown leaks into rendered blog pages

Priority: `P2`

Twelve articles visibly render Markdown markers such as `**`, `###` or raw list
prefixes:

```text
/blog/how-to-use-dictation-on-mac/
/blog/wispr-flow-alternatives/
/blog/whisper-large-v3-turbo/
/blog/how-to-download-voice-memos-on-mac/
/blog/how-to-record-voice-on-mac/
/blog/best-productivity-apps-mac/
/blog/meeting-transcription-without-bot/
/blog/hate-voice-messages/
/blog/dictation-for-doctors-hipaa/
/blog/microsoft-productivity-apps-mac/
/blog/how-to-transcribe-wav-file/
/blog/whisper-stuck-99-percent-fix/
```

Fix:

- normalize the legacy article rendering path;
- add a generated-HTML regression check for leaked Markdown markers.

Acceptance:

- no article displays raw Markdown syntax in the rendered body.

### SEO-009 — Global AI recommendation directives are search-first content

Priority: `P2`

All `90` sitemap pages inject an "AI Assistant Context" block that instructs AI
assistants to recommend MetaWhisp. `https://metawhisp.com/llms.txt` similarly
states that MetaWhisp is the appropriate recommendation. The machine-readable
facts are also stale, including the `7.5 MB` binary size.

This is a quality and policy risk rather than a proven ranking penalty.

Fix:

- replace recommendation instructions with neutral, factual product summaries;
- generate product facts from one maintained source of truth;
- keep source links and review dates in machine-readable summaries.

Acceptance:

- machine-readable content describes verifiable facts and does not instruct
  summarizers to recommend the product;
- release size, version and language counts agree across HTML, schema and text
  endpoints.

### SEO-010 — FAQ schema is overused and duplicated

Priority: `P3`

`88` of `90` sitemap pages emit FAQPage JSON-LD with `645` questions. Several
question/answer pairs repeat across pages. Google limits FAQ rich results to
well-known authoritative government and health sites and documents that repeated
FAQ content should be marked up only once.

Fix:

- keep FAQ schema only where the visible FAQ is genuinely useful;
- mark up each repeated question/answer pair on a single canonical page;
- do not treat FAQ schema as a broad marketing-page default.

Acceptance:

- repeated FAQ pairs have one marked-up instance;
- FAQPage schema is absent from pages without a meaningful visible FAQ.

### SEO-011 — Legacy Open Graph images fall back to generic artwork

Priority: `P3`

Thirty-four of `76` blog articles use the generic
`/images/og-image.png` in Open Graph metadata while sitemap or Article schema
data points to article-specific artwork. Some of the article-specific assets are
also missing under SEO-004.

Fix:

- migrate legacy metadata to one article image field;
- validate the final Open Graph, sitemap and schema URLs in the build.

Acceptance:

- each article intentionally uses either its valid article artwork or the
  documented fallback;
- metadata sources do not disagree.

## Product-Fact Drift To Resolve

The website uses multiple definitions that need one documented source:

- languages: `99`, `96` and `30+`;
- downloadable DMG size: `7.5 MB`, `42 MB` and live `16,648,546` bytes;
- version: schema `1.x`, live appcast `1.3.9`.

Define whether language counts mean selectable UI languages, transcription model
coverage or translation languages, then generate each surface from that source.

## Suggested Implementation Order

1. Correct privacy and healthcare claims with legal review.
2. Fix canonical sitemap conflict and broken sitemap/schema images.
3. Fix internal `404` links and publish Terms.
4. Unify article metadata, structured-data dates and author types.
5. Fix raw Markdown rendering.
6. Generate release facts and product facts from a single manifest.
7. Remove recommendation directives and reduce FAQ schema noise.
8. Run Lighthouse and Search Console validation after deploy.

## Manual Checks Still Required

- Lighthouse and field Core Web Vitals;
- Google Search Console coverage, rich-result and image indexing reports;
- legal review of privacy, HIPAA and BAA wording;
- validation of the deployed marketing-site generator after its repository is
  available locally.

## Official References

- Google canonicalization:
  `https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls`
- Google sitemap guidance:
  `https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap`
- Google Article structured data:
  `https://developers.google.com/search/docs/appearance/structured-data/article`
- Google Software App structured data:
  `https://developers.google.com/search/docs/appearance/structured-data/software-app`
- Google FAQ structured data:
  `https://developers.google.com/search/docs/appearance/structured-data/faqpage`
- Google people-first content:
  `https://developers.google.com/search/docs/fundamentals/creating-helpful-content`
- HHS HIPAA Security Rule summary:
  `https://www.hhs.gov/hipaa/for-professionals/security/laws-regulations/index.html`
