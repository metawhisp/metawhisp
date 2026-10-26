#!/bin/bash
set -euo pipefail

# ZIP distribution builder — used as a DMG alternative when running from a
# shell that lacks Full Disk Access (Cursor/VS Code integrated terminals).
# Produces MetaWhisp.zip which the user double-clicks to expand → drags into
# /Applications. Same UX as a DMG without the volume-mount TCC dance.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/scripts/lib/app-install.sh"

APP_NAME="MetaWhisp"
ZIP_NAME="$APP_NAME.zip"
INSTALLED_APP="$MW_RELEASE_APP"

echo "==> Building $APP_NAME..."
bash build.sh

if [ ! -d "$INSTALLED_APP" ]; then
    echo "ERROR: $INSTALLED_APP not found"
    exit 1
fi

# Remove old archive
rm -f "$SCRIPT_DIR/$ZIP_NAME"

# ditto preserves macOS metadata + extended attributes (signing, entitlements)
# better than `zip` — required so the app stays signed after extraction.
echo "==> Packing into $ZIP_NAME..."
ditto -c -k --keepParent "$INSTALLED_APP" "$SCRIPT_DIR/$ZIP_NAME"

ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
echo "==> Done! $ZIP_NAME ($ZIP_SIZE)"
echo "    Location: $SCRIPT_DIR/$ZIP_NAME"
