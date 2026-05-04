#!/bin/bash
set -euo pipefail

# Manual DMG builder using hdiutil directly — sidesteps create-dmg's TCC issues
# (it tries to mount + cp + style which fails when parent shell lacks Full Disk
# Access on certain volumes). Produces a clean drag-to-Applications DMG.
#
# CONTRACT: this script ASSUMES `~/Applications/MetaWhisp.app` already exists.
# The caller is responsible for building first (release.sh does this in Step 1
# via `bash build.sh`). If you run this script standalone, run `bash build.sh`
# first.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="MetaWhisp"
DMG_NAME="$APP_NAME.dmg"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
# Stage in /tmp — `~/Applications` is TCC-protected and `hdiutil` cannot
# read from it when run from non-Full-Disk-Access shells (Cursor / VS Code
# integrated terminals etc.). /tmp has no such restriction.
STAGING="/tmp/metawhisp-dmg-staging"

if [ ! -d "$INSTALLED_APP" ]; then
    echo "ERROR: $INSTALLED_APP not found — run \`bash build.sh --no-launch\` first."
    exit 1
fi

# Reset staging dir
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Copy the signed app + add an "Applications" symlink so the user can drag.
# `ditto` preserves macOS extended attributes — required to keep the
# Developer ID signature valid after the round-trip.
echo "==> Staging app + Applications symlink in $STAGING..."
ditto "$INSTALLED_APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# Clear any old DMG and any stuck mounts (both standard + custom mountroot)
rm -f "$SCRIPT_DIR/$DMG_NAME" "$SCRIPT_DIR/$APP_NAME.tmp.dmg"
hdiutil detach "/Volumes/MetaWhisp" -force 2>/dev/null || true
hdiutil detach "/tmp/mw-mount/MetaWhisp" -force 2>/dev/null || true
mkdir -p /tmp/mw-mount

# `hdiutil create -srcfolder` mounts the destination DMG under /Volumes/<name>
# and uses a privileged copy-helper to populate it. Shells without Full Disk
# Access (Cursor / VS Code / Claude Code integrated terminals) cannot write
# to /Volumes/* — copy-helper fails with "Operation not permitted" even on a
# DMG it just created. Workaround: create writable image, mount under /tmp
# (no TCC), ditto contents in, detach, convert to compressed UDZO.
echo "==> Creating writable DMG..."
hdiutil create -size 50m -fs HFS+ -volname "MetaWhisp" -ov "$SCRIPT_DIR/$APP_NAME.tmp.dmg" >/dev/null

echo "==> Attaching at /tmp/mw-mount (bypasses /Volumes TCC)..."
hdiutil attach "$SCRIPT_DIR/$APP_NAME.tmp.dmg" -mountroot /tmp/mw-mount -nobrowse -noverify -noautoopen >/dev/null

echo "==> Copying app + Applications symlink into mount..."
ditto "$STAGING/$APP_NAME.app" "/tmp/mw-mount/MetaWhisp/$APP_NAME.app"
ln -sf /Applications "/tmp/mw-mount/MetaWhisp/Applications"

echo "==> Detaching..."
hdiutil detach "/tmp/mw-mount/MetaWhisp" -force >/dev/null

echo "==> Converting to compressed UDZO..."
hdiutil convert "$SCRIPT_DIR/$APP_NAME.tmp.dmg" -format UDZO -o "$SCRIPT_DIR/$DMG_NAME" >/dev/null
rm -f "$SCRIPT_DIR/$APP_NAME.tmp.dmg"

DMG_SIZE=$(du -h "$SCRIPT_DIR/$DMG_NAME" | cut -f1)
echo "==> Done! $DMG_NAME ($DMG_SIZE)"
echo "    Location: $SCRIPT_DIR/$DMG_NAME"
