#!/bin/bash
set -euo pipefail

# MetaWhisp Release Script
# Builds the app, packages a DMG, notarizes it, and signs for Sparkle.
# Publishing comes after it, by hand and on GitHub only (the steps it prints at
# the end); it never touches metawhisp.com and never deploys the API.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/scripts/lib/app-install.sh"
# On any exit a self-check still running is stopped and the smoke copy goes
# (scripts/lib/app-install.sh).
mw_trap_exit 'rm -rf "${SMOKE_APP_COPY:-}"'

# Preflight: refuse a release while a tracked file is modified or staged
# (untracked files are allowed — the owner keeps some in the main tree), or
# while the regression gate does not pass. Runs before bash build.sh.
mw_release_preflight

echo "==> Step 1: Building app..."
bash build.sh

# ──────────────────────────────────────────────────────────────────────────────
# Step 1b: Bundle integrity assertions
# ──────────────────────────────────────────────────────────────────────────────
# Catches gaps between what build.sh PRODUCES and what the runtime EXPECTS.
# Cheap (seconds) and catches broken releases before they reach a user.
# History: v1.3.5 (2026-05-21) shipped without mlx.metallib because the
# build pipeline had no invariant check for that file; users hit "MLX error"
# on first launch. These asserts make that class of failure impossible —
# the release aborts here, not at the user.
# build.sh leaves the signed release bundle in .build; nothing is installed.
ASSEMBLED_APP="$MW_RELEASE_APP"
echo "==> Step 1b: Bundle integrity check..."
required=(
    "$ASSEMBLED_APP/Contents/Info.plist"
    "$ASSEMBLED_APP/Contents/MacOS/MetaWhisp"
    "$ASSEMBLED_APP/Contents/MacOS/mlx.metallib"
    "$ASSEMBLED_APP/Contents/Frameworks/Sparkle.framework"
    "$ASSEMBLED_APP/Contents/Resources/AppIcon.icns"
)
for p in "${required[@]}"; do
    if [ ! -e "$p" ]; then
        echo "==> ❌ Missing required bundle path: $p"
        exit 1
    fi
done
# Verify version on the bundle matches what's in the source Info.plist —
# catches "forgot to bump version" mistakes that hide bad/duplicate
# Sparkle updates.
PLIST_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ASSEMBLED_APP/Contents/Info.plist" 2>/dev/null)
SRC_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SCRIPT_DIR/Resources/Info.plist" 2>/dev/null)
if [ "$PLIST_VER" != "$SRC_VER" ]; then
    echo "==> ❌ Bundle version $PLIST_VER ≠ source version $SRC_VER"
    exit 1
fi
echo "    Bundle invariants OK (v$PLIST_VER, all required paths present)"
# Codesign chain validates end-to-end.
if ! codesign --verify --deep --strict --verbose=2 "$ASSEMBLED_APP" >/dev/null 2>&1; then
    echo "==> ❌ codesign --verify --deep --strict FAILED on $ASSEMBLED_APP"
    codesign --verify --deep --strict --verbose=2 "$ASSEMBLED_APP" || true
    exit 1
fi
echo "    Codesign chain valid"

echo ""
echo "==> Step 2: Creating DMG (TCC-safe via /tmp staging)..."
# `make-dmg-manual.sh` stages in /tmp and uses plain hdiutil — survives in any
# shell. It mounts its image under /tmp/mw-mount, never /Volumes, so the working
# app keeps running: a release never stops it (ITER-075 step 0, US-0.2).
bash make-dmg-manual.sh

DMG="$SCRIPT_DIR/MetaWhisp.dmg"
if [ ! -f "$DMG" ]; then
    echo "ERROR: DMG not created"
    exit 1
fi

DMG_SIZE=$(stat -f%z "$DMG")
echo "    DMG size: $DMG_SIZE bytes"

echo ""
echo "==> Step 1c: Signing the DMG itself with Developer ID..."
# 2026-08-17 — this step was missing. Apple happily notarizes an UNSIGNED disk
# image (notarization checks what's inside it), so every release until now
# shipped a container that `spctl -a -t open` rejected with "no usable
# signature". Stapling still worked, so it went unnoticed.
# Must run BEFORE notarization: signing rewrites the DMG bytes, which would
# invalidate a ticket stapled to the unsigned version.
DMG_SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:.*\(6D6948Z4MW\)/ {print $2; exit}')
if [ -z "${DMG_SIGN_ID:-}" ]; then
    echo "ERROR: Developer ID Application cert (team 6D6948Z4MW) not in keychain."
    echo "Refusing to ship an unsigned DMG — no ad-hoc fallback here."
    exit 1
fi
codesign --force --sign "$DMG_SIGN_ID" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | tail -2
DMG_SIZE=$(stat -f%z "$DMG")
echo "    Signed DMG size: $DMG_SIZE bytes"

echo ""
echo "==> Step 2a: Notarizing DMG with Apple (MANDATORY in prod)..."
# WHY: Without notarization Gatekeeper shows "Apple cannot check for malicious
# software" on first launch for fresh downloads from the website — a
# conversion-killer for new users (auto-update via Sparkle bypasses Gatekeeper
# and works without notarization, but the website-download path needs it).
# Order matters: notarize + staple BEFORE the Sparkle EdDSA sign, because
# stapling modifies the DMG bytes and the Sparkle hash must cover the FINAL,
# stapled DMG that's actually shipped.
#
# Credentials live in macOS Keychain — NEVER hardcode them here.
# This file is in a public GitHub repo; anything written below is leaked.
# One-time setup:
#   security add-generic-password -s metawhisp-apple-id      -a "$USER" -w '<your-apple-id-email>'
#   security add-generic-password -s metawhisp-apple-notary  -a "$USER" -w '<app-specific-password from appleid.apple.com>'
APPLE_ID="$(security find-generic-password -s metawhisp-apple-id -w 2>/dev/null || true)"
TEAM_ID="6D6948Z4MW"   # Not secret — visible in any signed .app's codesign output.
APP_SPECIFIC_PASS="$(security find-generic-password -s metawhisp-apple-notary -w 2>/dev/null || true)"

if [ -z "${APPLE_ID:-}" ] || [ -z "${APP_SPECIFIC_PASS:-}" ]; then
    echo "ERROR: Apple notarization credentials missing from Keychain."
    echo ""
    echo "One-time setup:"
    echo "  security add-generic-password -s metawhisp-apple-id     -a \"\$USER\" -w 'your-apple-id@example.com'"
    echo "  security add-generic-password -s metawhisp-apple-notary -a \"\$USER\" -w '<app-specific-password>'"
    echo ""
    echo "Generate the app-specific password at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords."
    exit 1
fi

xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASS" \
    --wait

echo ""
echo "==> Step 2b: Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Re-stat after stapling — xattr write can shift size.
DMG_SIZE=$(stat -f%z "$DMG")
echo "    Stapled DMG size: $DMG_SIZE bytes"

echo ""
echo "==> Step 3: Signing for Sparkle..."
SIGN_TOOL="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ -x "$SIGN_TOOL" ]; then
    SIGNATURE=$("$SIGN_TOOL" "$DMG" 2>&1)
    echo "    $SIGNATURE"
else
    echo "ERROR: sign_update not found at $SIGN_TOOL"
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 3b: Smoke test — mount fresh DMG, run the app's self-check
# ──────────────────────────────────────────────────────────────────────────────
# Notarization Accepted ≠ working. The 2026-05-21 incident shipped an
# Accepted DMG that crashed on first eval(). This step actually RUNS the
# binary from the DMG with `--self-check` (SelfCheck.swift):
#   - dyld must load it and Sparkle, so a broken Frameworks rpath stops it here;
#   - macOS must accept its signature at launch;
#   - mlx.metallib must sit next to it;
#   - MLX must run two tiny GPU computations, one with a kernel from the metallib.
# It exits by itself before the app exists: no store, keychain, log, network or
# capture, only macOS's shared GPU shader cache for the bundle id. So it runs
# beside the working app, which a release never stops (ITER-075 step 0, US-0.2).
# Not covered:
#   - the app's own startup code. A test build swapped onto the owner's Mac
#     (hot-swap.sh) runs it first, before a release, with the working app's own
#     identity;
#   - an entitlement dropped from the signature, which macOS only enforces when
#     the app uses it.
echo ""
echo "==> Step 3b: Smoke test — mount DMG and run the self-check..."
SMOKE_MOUNT="/tmp/mw-smoke-mount"
SMOKE_APP_COPY="/tmp/MetaWhisp-smoke.app"
hdiutil detach "$SMOKE_MOUNT/MetaWhisp" -force >/dev/null 2>&1 || true
rm -rf "$SMOKE_APP_COPY" "$SMOKE_MOUNT"
mkdir -p "$SMOKE_MOUNT"
if ! hdiutil attach "$DMG" -mountroot "$SMOKE_MOUNT" -nobrowse -noverify -noautoopen >/dev/null 2>&1; then
    echo "==> ❌ DMG would not mount"
    exit 1
fi
ditto "$SMOKE_MOUNT/MetaWhisp/MetaWhisp.app" "$SMOKE_APP_COPY"
hdiutil detach "$SMOKE_MOUNT/MetaWhisp" -force >/dev/null 2>&1 || true
rmdir "$SMOKE_MOUNT" 2>/dev/null || true

if ! mw_self_check "$SMOKE_APP_COPY/Contents/MacOS/MetaWhisp"; then
    echo "==> ❌ Smoke test FAILED"
    rm -rf "$SMOKE_APP_COPY"
    exit 1
fi
rm -rf "$SMOKE_APP_COPY"
echo "    Smoke test passed (the DMG's app ran its self-check)"

echo ""
echo "============================================"
echo "  RELEASE READY"
echo "============================================"
echo "  DMG size: $DMG_SIZE bytes"
echo "  $SIGNATURE"
echo ""
echo "  Next steps (GitHub-only):"
echo "  1. Build appcast.xml: prepend this version's item (with the signature"
echo "     and length printed above) to the current appcast.xml."
echo "  2. gh release create vX.Y.Z --latest MetaWhisp.dmg appcast.xml"
echo "  3. Verify: curl -L https://metawhisp.com/appcast.xml — the new"
echo "     version must be at the top."
echo ""
echo "  Never touch the website or deploy the API from here."
echo "============================================"
