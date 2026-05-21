#!/bin/bash
set -euo pipefail

# MetaWhisp Release Script
# Builds app, creates DMG, signs for Sparkle, copies to website downloads

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Step 1: Building app..."
bash build.sh --no-launch

# ──────────────────────────────────────────────────────────────────────────────
# Step 1b: Bundle integrity assertions
# ──────────────────────────────────────────────────────────────────────────────
# Catches gaps between what build.sh PRODUCES and what the runtime EXPECTS.
# Cheap (seconds) and catches broken releases before they reach a user.
# History: v1.3.5 (2026-05-21) shipped without mlx.metallib because the
# build pipeline had no invariant check for that file; users hit "MLX error"
# on first launch. These asserts make that class of failure impossible —
# the release aborts here, not at the user.
ASSEMBLED_APP="$HOME/Applications/MetaWhisp.app"
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
# shell. Pre-step: kill running app — it holds the /Volumes/MetaWhisp mount-name
# lock and would block hdiutil otherwise.
pkill -x MetaWhisp 2>/dev/null || true
sleep 1
bash make-dmg-manual.sh

DMG="$SCRIPT_DIR/MetaWhisp.dmg"
if [ ! -f "$DMG" ]; then
    echo "ERROR: DMG not created"
    exit 1
fi

DMG_SIZE=$(stat -f%z "$DMG")
echo "    DMG size: $DMG_SIZE bytes"

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
# Step 3b: Smoke test — mount fresh DMG, launch, assert process survives 5s
# ──────────────────────────────────────────────────────────────────────────────
# Notarization Accepted ≠ working. The 2026-05-21 incident shipped an
# Accepted DMG that crashed on first eval(). This step actually RUNS the
# binary from the DMG in isolation and checks it doesn't die. Catches any
# class of bundle-broken-at-runtime issue (missing metallib, broken
# Frameworks rpath, entitlement mismatch, etc).
echo ""
echo "==> Step 3b: Smoke test — mount DMG and launch..."
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

# Capture log baseline so we can grep for new errors written during the
# smoke launch window only.
LOG_BASELINE_LINES=$(wc -l < ~/Library/Logs/MetaWhisp.log 2>/dev/null || echo 0)
# Launch without taking focus.
"$SMOKE_APP_COPY/Contents/MacOS/MetaWhisp" >/tmp/mw-smoke.stdout 2>/tmp/mw-smoke.stderr &
SMOKE_PID=$!
disown $SMOKE_PID 2>/dev/null || true
sleep 5
if ! kill -0 $SMOKE_PID 2>/dev/null; then
    echo "==> ❌ Smoke test FAILED — app died within 5s"
    echo "--- stdout ---"
    cat /tmp/mw-smoke.stdout | tail -20
    echo "--- stderr ---"
    cat /tmp/mw-smoke.stderr | tail -20
    rm -rf "$SMOKE_APP_COPY"
    exit 1
fi
# Look for fatal-class messages written DURING the smoke window only.
fatal_grep=$(tail -n +$((LOG_BASELINE_LINES + 1)) ~/Library/Logs/MetaWhisp.log 2>/dev/null | grep -iE "(Fatal error|MLX error:|SIGSEGV|abort\(\))" | head -5 || true)
if [ -n "$fatal_grep" ]; then
    echo "==> ❌ Smoke test FAILED — fatal-class message in log:"
    echo "$fatal_grep"
    kill $SMOKE_PID 2>/dev/null || true
    rm -rf "$SMOKE_APP_COPY"
    exit 1
fi
kill $SMOKE_PID 2>/dev/null || true
wait $SMOKE_PID 2>/dev/null || true
rm -rf "$SMOKE_APP_COPY" /tmp/mw-smoke.stdout /tmp/mw-smoke.stderr
echo "    Smoke test passed (PID $SMOKE_PID survived 5s, no fatal errors)"

echo ""
echo "============================================"
echo "  RELEASE READY"
echo "============================================"
echo "  DMG size: $DMG_SIZE bytes"
echo "  $SIGNATURE"
echo ""
echo "  Next steps:"
echo "  1. Update website/src/appcast.xml with signature + size"
echo "  2. Deploy website: cd website && npm run deploy"
echo "  3. Deploy API if changed: cd api && npx wrangler deploy"
echo "============================================"
