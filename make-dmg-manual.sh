#!/bin/bash
set -euo pipefail

# Manual DMG builder using hdiutil directly — sidesteps create-dmg's TCC issues
# (it tries to mount + cp + style which fails when parent shell lacks Full Disk
# Access on certain volumes). Produces a clean drag-to-Applications DMG.
#
# CONTRACT: this script ASSUMES the signed release bundle that build.sh leaves
# in .build (MW_RELEASE_APP in scripts/lib/app-install.sh) already exists.
# The caller is responsible for building first (release.sh does this in Step 1
# via `bash build.sh`). If you run this script standalone, run `bash build.sh`
# first.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/scripts/lib/app-install.sh"

APP_NAME="MetaWhisp"
DMG_NAME="$APP_NAME.dmg"
INSTALLED_APP="$MW_RELEASE_APP"
# PRD P1 15 — the window the DMG opens with: the app on the left, Applications
# on the right, the arrow of this background between them. Finder lays it out
# (scripts/dmg-layout.applescript) and writes it into the image's .DS_Store.
BACKGROUND="$SCRIPT_DIR/Resources/dmg-background.png"
LAYOUT="$SCRIPT_DIR/scripts/dmg-layout.applescript"
# Stage in /tmp — `~/Applications` is TCC-protected and `hdiutil` cannot
# read from it when run from non-Full-Disk-Access shells (Cursor / VS Code
# integrated terminals etc.). /tmp has no such restriction.
STAGING="/tmp/metawhisp-dmg-staging"

if [ ! -d "$INSTALLED_APP" ]; then
    echo "ERROR: $INSTALLED_APP not found — run \`bash build.sh\` first."
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

# Clear any old DMG and a mount this script left behind. /Volumes is never
# touched: a MetaWhisp the owner runs from a mounted DMG keeps its volume.
rm -f "$SCRIPT_DIR/$DMG_NAME" "$SCRIPT_DIR/$APP_NAME.tmp.dmg"
hdiutil detach "/tmp/mw-mount/MetaWhisp" -force 2>/dev/null || true
mkdir -p /tmp/mw-mount

# `hdiutil create -srcfolder` mounts the destination DMG under /Volumes/<name>
# and uses a privileged copy-helper to populate it. Shells without Full Disk
# Access (Cursor / VS Code / Claude Code integrated terminals) cannot write
# to /Volumes/* — copy-helper fails with "Operation not permitted" even on a
# DMG it just created. Workaround: create writable image, mount under /tmp
# (no TCC), ditto contents in, detach, convert to compressed UDZO.
echo "==> Creating writable DMG..."
# DMG size: app size + 20 MB headroom (HFS+ overhead, /Applications symlink,
# alignment). Was hardcoded 50 MB; broke 2026-05-21 when app grew past
# 50 MB (Phi-4 vendored MLX code + MCP server pushed bundle to 52 MB).
APP_KB=$(du -sk "$STAGING/$APP_NAME.app" | cut -f1)
DMG_MB=$(( APP_KB / 1024 + 20 ))
echo "    app=${APP_KB}KB → DMG=${DMG_MB}MB (with 20 MB headroom)"
hdiutil create -size "${DMG_MB}m" -fs HFS+ -volname "MetaWhisp" -ov "$SCRIPT_DIR/$APP_NAME.tmp.dmg" >/dev/null

echo "==> Attaching at /tmp/mw-mount (bypasses /Volumes TCC)..."
# Browsable: Finder has to see the writable image to lay out its window.
hdiutil attach "$SCRIPT_DIR/$APP_NAME.tmp.dmg" -mountroot /tmp/mw-mount -noverify -noautoopen >/dev/null

echo "==> Copying app + Applications symlink into mount..."
ditto "$STAGING/$APP_NAME.app" "/tmp/mw-mount/MetaWhisp/$APP_NAME.app"
ln -sf /Applications "/tmp/mw-mount/MetaWhisp/Applications"

echo "==> Laying out the window (background + icon positions, via Finder)..."
mkdir -p "/tmp/mw-mount/MetaWhisp/.background"
cp "$BACKGROUND" "/tmp/mw-mount/MetaWhisp/.background/background.png"
# The first run asks once to let this terminal control Finder. Without the
# layout the image still installs by drag; the release goes on, and says so.
osascript "$LAYOUT" "/tmp/mw-mount/MetaWhisp" \
    || echo "WARNING: Finder could not lay out the DMG window (Automation permission?) — the DMG has no background or icon positions"
sync
# Finder writes the layout into .DS_Store on its own time: wait for it, briefly.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "/tmp/mw-mount/MetaWhisp/.DS_Store" ] && break
    sleep 1
done
[ -f "/tmp/mw-mount/MetaWhisp/.DS_Store" ] || echo "WARNING: no .DS_Store in the image — the window opens without its layout"

echo "==> Detaching..."
hdiutil detach "/tmp/mw-mount/MetaWhisp" -force >/dev/null

echo "==> Converting to compressed UDZO..."
hdiutil convert "$SCRIPT_DIR/$APP_NAME.tmp.dmg" -format UDZO -o "$SCRIPT_DIR/$DMG_NAME" >/dev/null
rm -f "$SCRIPT_DIR/$APP_NAME.tmp.dmg"
# The staged copy is a launchable copy of the working app; it does not stay behind.
rm -rf "$STAGING"

DMG_SIZE=$(du -h "$SCRIPT_DIR/$DMG_NAME" | cut -f1)
echo "==> Done! $DMG_NAME ($DMG_SIZE)"
echo "    Location: $SCRIPT_DIR/$DMG_NAME"
