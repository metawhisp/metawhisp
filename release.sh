#!/bin/bash
set -euo pipefail

# MetaWhisp Release Script
# Builds app, creates DMG, signs for Sparkle, copies to website downloads

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Step 1: Building app..."
bash build.sh --no-launch

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
APPLE_ID="maintainer@gmail.com"
TEAM_ID="6D6948Z4MW"
APP_SPECIFIC_PASS="fswz-qydu-csch-ocyp"

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

echo ""
echo "==> Step 4: Copying to website downloads..."
cp "$DMG" "$SCRIPT_DIR/website/src/downloads/MetaWhisp.dmg"
echo "    Copied to website/src/downloads/MetaWhisp.dmg"

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
