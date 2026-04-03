#!/bin/bash
set -euo pipefail

# MetaWhisp Release Script
# Builds app, creates DMG, signs for Sparkle, copies to website downloads

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Step 1: Building app..."
bash build.sh --no-launch

echo ""
echo "==> Step 2: Creating DMG..."
bash make-dmg.sh 2>/dev/null || bash make-dmg-clean.sh

DMG="$SCRIPT_DIR/MetaWhisp.dmg"
if [ ! -f "$DMG" ]; then
    echo "ERROR: DMG not created"
    exit 1
fi

DMG_SIZE=$(stat -f%z "$DMG")
echo "    DMG size: $DMG_SIZE bytes"

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
