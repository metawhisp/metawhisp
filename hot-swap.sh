#!/bin/bash
set -euo pipefail

# Hot-swap the freshly compiled debug binary into the running /Applications copy
# WITHOUT triggering a TCC re-prompt. Critical that we sign with the same
# Developer ID identity and entitlements every time so macOS sees the same
# code identity as the original install.
#
# Usage: bash hot-swap.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DEBUG_BIN="$SCRIPT_DIR/.build/debug/MetaWhisp"
APP="/Applications/MetaWhisp.app"
SPARKLE="$APP/Contents/MacOS/Sparkle.framework"
SIGN_ID="Developer ID Application: MetaWhisp Maintainer (6D6948Z4MW)"
ENTITLEMENTS="$SCRIPT_DIR/Resources/MetaWhisp.entitlements"

if [ ! -f "$DEBUG_BIN" ]; then
    echo "ERROR: $DEBUG_BIN not found — run \`swift build\` first."
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "ERROR: Developer ID identity not in keychain — TCC will reset on launch."
    echo "       Falling back to ad-hoc would re-prompt for all permissions."
    exit 1
fi

echo "==> Killing running MetaWhisp..."
pkill -x MetaWhisp 2>/dev/null || true
sleep 1

echo "==> Building fresh debug bundle in ~/Applications..."
# We can't `cp` directly into /Applications/MetaWhisp.app — TCC blocks shell
# writes to existing bundles inside /Applications even though we own them.
# Workflow: build a fresh bundle in ~/Applications (user-owned, no TCC), then
# remove + ditto into /Applications. The rm + ditto pair is allowed; only
# in-place modification is blocked.
USER_APP="$HOME/Applications/MetaWhisp.app"
if [ ! -d "$USER_APP" ]; then
    echo "ERROR: $USER_APP not found — run \`bash build.sh\` first to create the bundle."
    exit 1
fi
cp "$DEBUG_BIN" "$USER_APP/Contents/MacOS/MetaWhisp"
# Debug binaries don't go through build.sh's install_name_tool step, so add
# the @executable_path/../Frameworks rpath that lets dyld find Sparkle in its
# Contents/Frameworks/ home. Idempotent — install_name_tool errors out
# (silenced) if the rpath is already there.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$USER_APP/Contents/MacOS/MetaWhisp" 2>/dev/null || true

echo "==> Replacing /Applications copy with the patched bundle..."
rm -rf "$APP"
ditto "$USER_APP" "$APP"

echo "==> Re-signing OUTER bundle only with Developer ID (TCC-stable)..."
# IMPORTANT: only re-sign the outer bundle on each swap — Sparkle internals
# don't change between swaps and re-signing them triggers a keychain access
# prompt that hangs in non-interactive shells. Nested Sparkle was already
# signed with Developer ID by the original `build.sh` cycle and stays valid
# across our binary swaps (only `Contents/MacOS/MetaWhisp` changes).
codesign --force --sign "$SIGN_ID" \
    --options runtime \
    --identifier "com.metawhisp.app" \
    --entitlements "$ENTITLEMENTS" \
    "$APP" >/dev/null 2>&1

echo "==> Verifying signature chain..."
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | grep "^Authority=Developer ID Application" | head -1)
if [ -z "$AUTHORITY" ]; then
    echo "WARN: outer signature didn't pick up Developer ID. TCC may reset."
fi

echo "==> Relaunching..."
open "$APP"
sleep 2
PID=$(pgrep -fx "$APP/Contents/MacOS/MetaWhisp" | head -1)
echo "==> Done. MetaWhisp running as PID $PID"
