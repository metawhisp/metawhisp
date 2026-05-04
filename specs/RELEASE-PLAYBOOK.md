# Release Playbook — how to ship a new MetaWhisp version

End-to-end procedure for cutting a new release of the macOS app and getting it
to live users. Last updated 2026-05-03 after we hit several deploy bugs the
hard way; this doc captures the lessons.

## TL;DR — release a patch in 3 commands

```bash
# 1. Bump version
$EDITOR Resources/Info.plist            # CFBundleShortVersionString + CFBundleVersion
# 2. Build + DMG + notarize + Sparkle sign
bash release.sh                         # ~20-30 min, fully automatic
# 3. Publish DMG to GitHub Release (source of truth for downloads)
export GH_TOKEN="github_pat_..."        # token with Contents:write on metawhisp/metawhisp
gh release create vX.Y.Z \
  -R metawhisp/metawhisp \
  --title "MetaWhisp X.Y.Z" \
  --notes "..." \
  MetaWhisp.dmg#MetaWhisp.dmg
```

The Cloudflare Page Rule already maps `metawhisp.com/downloads/MetaWhisp.dmg`
→ `github.com/metawhisp/metawhisp/releases/download/vX.Y.Z/MetaWhisp.dmg`, so
**users automatically get the new build through the website button** — no
Pages deploy needed.

⚠️ The Page Rule's destination URL is **hard-coded to a specific version**
(currently `v1.3.1`). When releasing `v1.3.2` you must also update the rule's
destination — see "Bumping the redirect target" below.

---

## Architecture (DO NOT change without reading "lessons learned")

```
                              ┌─────────────────────────┐
                              │  metawhisp.com/         │  Cloudflare Pages
   user clicks                │  ├── /                  │  (marketing site,
   "Download" ──────────────► │  ├── /blog/...          │  blog, all UI)
                              │  └── /appcast.xml       │  ← Sparkle reads here
                              └────────────┬────────────┘
                                           │
                            /downloads/MetaWhisp.dmg
                                           │
                                           ▼
                              ┌─────────────────────────┐
                              │ Cloudflare Page Rule    │  separate from Pages
                              │ Forwarding URL → 302    │
                              └────────────┬────────────┘
                                           ▼
                              ┌─────────────────────────┐
                              │ github.com/metawhisp/   │  GitHub Releases
                              │ metawhisp/releases/     │  (source of truth
                              │ download/vX.Y.Z/        │  for DMG binaries)
                              │ MetaWhisp.dmg           │
                              └─────────────────────────┘
```

**Why split this way:** Cloudflare Pages deploys are *atomic full snapshots*.
Every `wrangler pages deploy` uploads the entire directory; anything not in
the upload is **deleted** from the live site. We were blowing the marketing
site away every time we tried to ship a new DMG. The Page Rule + GitHub
Release indirection means future DMG releases never touch the website state.

---

## Step-by-step release

### 1. Bump version

`Resources/Info.plist`:
- `CFBundleShortVersionString` — semver string users see, e.g. `1.3.1`
- `CFBundleVersion` — integer build number, must increase every release
  (Sparkle compares this, not the semver string)

### 2. Build + sign + notarize via `release.sh`

```bash
bash release.sh
```

This script chains:
1. `bash build.sh --no-launch` — `swift build -c release`, packages `.app`,
   re-signs Sparkle nested components + outer bundle with Developer ID +
   `--timestamp` (with retry-on-TSA-flake — added 2026-05-03 because Apple's
   TSA endpoint silently dropped timestamps once and notarization rejected).
2. `bash make-dmg-manual.sh` — packages `~/Applications/MetaWhisp.app` into
   `MetaWhisp.dmg` via `hdiutil`. **CONTRACT:** uses `~/Applications/...`,
   NOT `.build/release/...`. If you re-sign artifacts after build.sh you must
   `ditto $SRC ~/Applications/MetaWhisp.app` before running this step.
3. `xcrun notarytool submit ... --wait` — sends to Apple, waits 5-15 min.
   If status is `Invalid`, fetch the log:
   ```bash
   xcrun notarytool log <submission-id> --apple-id ... --team-id ... --password ...
   ```
4. `xcrun stapler staple` — pin the notarization ticket to the DMG.
5. Sparkle EdDSA `sign_update` — produces signature for appcast.
6. **Copies DMG to `website/src/downloads/MetaWhisp.dmg`** ← this step is
   redundant in the new architecture (we serve from GitHub Release instead),
   but keeping it for backwards compatibility in case the Page Rule is removed.

### 3. Publish DMG to GitHub Release

```bash
export GH_TOKEN="<fine-grained PAT for metawhisp account>"
gh release create v1.3.1 \
  -R metawhisp/metawhisp \
  --title "MetaWhisp 1.3.1" \
  --notes "..." \
  /Users/android/Code/MetaWhisp/MetaWhisp.dmg#MetaWhisp.dmg
```

Required token permissions on the `metawhisp/metawhisp` repo:
- `Contents: Read and write` (for creating releases + uploading assets)
- `Metadata: Read` (default, can't disable)

Make the token at https://github.com/settings/personal-access-tokens (must be
logged in as user `metawhisp`, NOT any other GitHub account).

### 4. Bumping the redirect target (when version > 1.3.1)

The Cloudflare Page Rule currently points at `v1.3.1`. To update for `v1.3.2`:

1. Open https://dash.cloudflare.com → metawhisp.com → **Rules** → **Page Rules**
2. Find rule with URL pattern `*metawhisp.com/downloads/MetaWhisp.dmg`
3. Edit → change the **Forwarding URL** target from `.../v1.3.1/MetaWhisp.dmg`
   to `.../v1.3.2/MetaWhisp.dmg`
4. Save.

**Better long-term fix (TODO):** make the Page Rule point at GitHub's
"latest release" alias: `https://github.com/metawhisp/metawhisp/releases/latest/download/MetaWhisp.dmg`.
GitHub auto-resolves this to whatever release is marked as "latest". One rule,
zero updates needed per release. Test before relying on it — Cloudflare may
follow the redirect chain or expose the indirection in unexpected ways.

### 5. Update Sparkle appcast (optional, for in-app auto-update)

Existing 1.3.0 users will only get auto-updated if `appcast.xml` advertises
the new version. Currently `appcast.xml` is on Cloudflare Pages and updating
it requires a Pages deploy (the dangerous operation). Options:

1. **Stop using Pages-hosted appcast.** Move `appcast.xml` to GitHub Releases
   too, add a Page Rule `metawhisp.com/appcast.xml` → GitHub raw URL of the
   appcast file. Then update appcast = release a new GitHub artifact = no
   Pages touch. **Recommended.** TODO; not done yet (2026-05-03).
2. **Safe Pages deploy** — see "Pages deploy procedure" below. Risky,
   requires full mirror of live state.
3. **Skip auto-update for now** — existing 1.3.0 users won't get the patch
   automatically; they'll need to re-download from the website button (which
   IS already updated). Acceptable for small user base.

---

## Token requirements (DO NOT commit values)

Each token below has limited scope. **Store in macOS Keychain or 1Password,
never in plaintext config or git.** The values that were used during the
2026-05-02 release session are compromised (they appeared in chat logs);
revoke + rotate before next release.

| Token | Where to create | Scope | Used for |
|---|---|---|---|
| **Apple Developer ID Application cert** | https://developer.apple.com → Certificates → "Developer ID Application" | n/a (cert, not token) | Code signing (build.sh) |
| **App-specific password** | https://appleid.apple.com → Sign-In and Security → App-Specific Passwords | n/a | Notarization (release.sh hardcodes; rotate via env var) |
| **GitHub fine-grained PAT** (for `metawhisp` user) | https://github.com/settings/personal-access-tokens | Repository: `metawhisp/metawhisp`. Permissions: `Contents: Read and write`, `Metadata: Read`. | Creating GitHub Releases (`gh release create`) |
| **Cloudflare Account API Token (Workers/Pages Edit)** | https://dash.cloudflare.com/profile/api-tokens → "Edit Cloudflare Workers" template | Account: All Accounts. | Deploying Pages site if ever needed (`wrangler pages deploy`). NOT used in normal release flow now that we serve DMGs from GitHub. |
| **Cloudflare Zone Token (Page Rules)** | Same dashboard, custom token | Zone: `metawhisp.com`. Permissions: `Zone → Page Rules: Edit` (or `Zone → Config Rules: Edit` for the newer Single Redirects API). | Creating/editing the redirect rule via API. Currently we use the dashboard manually. |

**Use-pattern in shell:**

```bash
# GitHub
export GH_TOKEN="$(security find-generic-password -s metawhisp-github -w)"

# Cloudflare
export CLOUDFLARE_API_TOKEN="$(security find-generic-password -s metawhisp-cf -w)"
export CLOUDFLARE_ACCOUNT_ID="1f2eeb70e1b6c19616b371751e5d45ed"
```

Add to keychain:
```bash
security add-generic-password -s metawhisp-github -a "$USER" -w "<token>"
```

---

## Pages deploy procedure (DANGEROUS — read first)

Only run a Pages deploy if you genuinely need to update HTML/CSS/blog. **Never
deploy `_site/` straight from `npm run build` without first mirroring live
state**, because:

- An external automation (some agent / cron / human) writes blog posts directly
  into Cloudflare Pages without committing to `website/src/blog/`.
- Eleventy (`npm run build`) generates `_site/` from `src/` only.
- `wrangler pages deploy _site` replaces the live site with whatever's in
  `_site/`, **deleting** any blog post that wasn't in `src/`.

We already lost 6 blog posts this way on 2026-05-02. Recovered by
`POST /pages/projects/metawhisp/deployments/{id}/rollback` to the previous
known-good deployment.

### Safe deploy (mirror live → patch locally → push)

```bash
# 1. Find the latest production deploy (the source of truth right now)
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/metawhisp/deployments?env=production&per_page=5" \
  | jq '.result[0].url'
# → https://<short_id>.metawhisp.pages.dev

# 2. Mirror it locally
cd /tmp
wget --mirror --no-host-directories --directory-prefix=metawhisp-mirror \
     --no-parent "https://<short_id>.metawhisp.pages.dev/"

# 3. Diff with your eleventy output to spot deletions
diff -r /tmp/metawhisp-mirror/ /Users/android/Code/MetaWhisp/website/_site/ \
  | grep "^Only in /tmp/metawhisp-mirror" | head -30

# 4. Copy any missing files into _site/
# 5. Apply your intended change in _site/
# 6. Deploy
cd /Users/android/Code/MetaWhisp/website
npx wrangler pages deploy _site --project-name=metawhisp --branch=main
```

If the deploy looks broken, **rollback in 5 seconds**:

```bash
PROJECT="metawhisp"
PREV_DEPLOY_ID="<id of last known-good deploy from `wrangler pages deployment list`>"
curl -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT/deployments/$PREV_DEPLOY_ID/rollback"
```

---

## Lessons learned (2026-05-02/03)

1. **Apple TSA flakes silently.** `codesign --timestamp` returns exit 0 even
   if the timestamp wasn't attached. Fix: build.sh now verifies `Timestamp=`
   in the signature after every `codesign` call and retries up to 3 times
   with 8s sleep. Without this, Apple notarization rejects with a generic
   "signature is invalid" error and you waste 30 minutes diagnosing.

2. **`make-dmg-manual.sh` uses `~/Applications/MetaWhisp.app`.** If you sign
   `.build/release/MetaWhisp.app` manually for some reason, you must `ditto`
   the result to `~/Applications/MetaWhisp.app` before re-running the DMG
   step or you'll re-package the OLD signed bundle and notarization will
   fail again with the same errors.

3. **Cloudflare Pages atomic deploy = full state replace.** Anything not in
   your local `_site/` will be deleted on the live site. Never deploy without
   a mirror-then-patch workflow.

4. **`whitespaceship` GitHub account is NOT for MetaWhisp.** Always use the
   `metawhisp` account. Set `GH_TOKEN` env var to the metawhisp PAT before
   running `gh` commands; don't rely on the keyring's default account.

5. **Tokens pasted in chat are compromised.** Even if you trust the assistant,
   chat logs persist. Use a temporary token (1h expiry, minimum scope) when
   sharing, and revoke after.
