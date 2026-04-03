#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="MetaWhisp"
DMG_NAME="$APP_NAME.dmg"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
BG_IMG="$SCRIPT_DIR/Resources/dmg-background.png"

# Require create-dmg (brew install create-dmg)
if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

# Build first (--no-launch to avoid starting the app during DMG creation)
echo "==> Building $APP_NAME..."
bash build.sh --no-launch

# Check app exists
if [ ! -d "$INSTALLED_APP" ]; then
    echo "ERROR: $INSTALLED_APP not found"
    exit 1
fi

# Remove old DMG if exists
rm -f "$SCRIPT_DIR/$DMG_NAME"

# Unmount any leftover volumes
hdiutil detach "/Volumes/MetaWhisp" 2>/dev/null || true
hdiutil detach "/Volumes/MetaWhisp Install" 2>/dev/null || true

# Create DMG with create-dmg (uses HFS+ — Finder settings persist correctly)
echo "==> Creating styled DMG..."
create-dmg \
    --volname "MetaWhisp" \
    --background "$BG_IMG" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 96 \
    --text-size 12 \
    --icon "$APP_NAME.app" 160 170 \
    --app-drop-link 500 170 \
    --no-internet-enable \
    "$SCRIPT_DIR/$DMG_NAME" \
    "$INSTALLED_APP"

DMG_SIZE=$(du -h "$SCRIPT_DIR/$DMG_NAME" | cut -f1)
echo "==> Done! $DMG_NAME ($DMG_SIZE)"
echo "    Location: $SCRIPT_DIR/$DMG_NAME"
