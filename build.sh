#!/bin/bash
set -euo pipefail

# Build MetaWhisp and package as a proper .app bundle
# Usage: ./build.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Use the correct Xcode
export DEVELOPER_DIR="/Applications/Other Apps/Xcode.app/Contents/Developer"

# Always build release for speed (debug is 5-10x slower for ML inference)
CONFIG="release"
BUILD_FLAGS="-c release"
NO_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug"; BUILD_FLAGS="" ;;
        --no-launch) NO_LAUNCH=true ;;
    esac
done

echo "==> Building MetaWhisp ($CONFIG)..."
swift build $BUILD_FLAGS 2>&1

# Paths
BUILD_DIR=".build/arm64-apple-macosx/$CONFIG"
EXECUTABLE="$BUILD_DIR/MetaWhisp"
APP_DIR="$BUILD_DIR/MetaWhisp.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Clean previous bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp "$EXECUTABLE" "$MACOS/MetaWhisp"

# Copy Info.plist
cp "Resources/Info.plist" "$CONTENTS/Info.plist"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy sounds if they exist
if [ -d "Resources/Sounds" ]; then
    cp -r "Resources/Sounds" "$RESOURCES/Sounds"
fi

# Copy Sparkle framework (rpath is @loader_path, so it goes next to the binary)
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$MACOS/"
fi

# Copy any SPM resources (MetaWhisp_MetaWhisp.bundle)
BUNDLE_PATH="$BUILD_DIR/MetaWhisp_MetaWhisp.bundle"
if [ -d "$BUNDLE_PATH" ]; then
    cp -r "$BUNDLE_PATH" "$RESOURCES/"
fi

echo "==> Bundle created: $APP_DIR"

# Clear extended attributes — Finder resource forks, xattr from curl downloads,
# SPM build outputs. Without this cleanup codesign silently fails with
# "resource fork detritus not allowed" and keeps the linker-signed adhoc signature,
# which has Identifier="MetaWhisp" (product name) instead of "com.metawhisp.app".
# Wrong identifier breaks macOS notifications (UNErrorDomain error 1).
xattr -cr "$APP_DIR" 2>/dev/null || true

# Stable Developer ID signing. Ad-hoc signatures change every rebuild — macOS treats
# each rebuild as a new app and resets TCC permissions (Screen Recording, Microphone,
# Accessibility). Developer ID keeps the same Team ID across rebuilds, so TCC sticks.
# If the cert is missing (CI, another machine) fall back to ad-hoc so build still works.
SIGN_IDENTITY="Developer ID Application: Andrey Dyuzhov (6D6948Z4MW)"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "==> ⚠️  Developer ID cert not found, falling back to ad-hoc (TCC will reset each rebuild)"
    SIGN_IDENTITY="-"
fi

# Sign nested Sparkle components bottom-up. --preserve-metadata keeps each nested bundle's
# original identifier (org.sparkle-project.*) and entitlements — dyld refuses to load
# Sparkle if its identifier changes, and XPC services need their own entitlements.
SPARKLE="$MACOS/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for target in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Sparkle" \
        "$SPARKLE"
    do
        codesign --force --sign "$SIGN_IDENTITY" \
            --options runtime \
            --preserve-metadata=identifier,entitlements,flags \
            "$target" 2>&1
    done
fi

# Sign outer bundle with our app identifier — macOS uses Identifier as app identity
# for notifications, TCC, and URL scheme registration.
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --identifier "com.metawhisp.app" \
    --entitlements "Resources/MetaWhisp.entitlements" \
    "$APP_DIR" 2>&1

# Verify: outer bundle identifier must match CFBundleIdentifier — without this
# macOS notifications return UNErrorDomain error 1.
SIGNED_ID=$(codesign -dvv "$APP_DIR" 2>&1 | grep -E "^Identifier=" | cut -d= -f2)
if [ "$SIGNED_ID" = "com.metawhisp.app" ]; then
    echo "==> Code signed (identifier: $SIGNED_ID) ✓"
else
    echo "==> ⚠️  Signature identifier is '$SIGNED_ID', expected 'com.metawhisp.app'"
    echo "==> Notifications may not work. Try deleting $APP_DIR and rebuilding."
fi

# Verify Sparkle.framework kept its original identifier
SPARKLE_ID=$(codesign -dvv "$MACOS/Sparkle.framework" 2>&1 | grep -E "^Identifier=" | cut -d= -f2)
if [ "$SPARKLE_ID" != "org.sparkle-project.Sparkle" ]; then
    echo "==> ⚠️  Sparkle identifier changed to '$SPARKLE_ID' — dyld will refuse to load it"
fi

# Install to ~/Applications for stable permissions
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
INSTALLED_APP="$INSTALL_DIR/MetaWhisp.app"

# Kill running instance before replacing
pkill -f "MetaWhisp.app" 2>/dev/null || true
sleep 0.5

# Copy to stable location
rm -rf "$INSTALLED_APP"
cp -r "$APP_DIR" "$INSTALLED_APP"
echo "==> Installed to: $INSTALLED_APP"

# Launch from stable location (skip with --no-launch)
if [ "$NO_LAUNCH" = false ]; then
    echo "==> Launching MetaWhisp..."
    open "$INSTALLED_APP"
fi
