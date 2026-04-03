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

# Code sign with persistent certificate + entitlements + loose designated requirement
# Entitlements grant hardened-runtime apps the right to request microphone access
# The loose requirement (identifier only) means TCC permissions survive rebuilds
codesign --force --sign "TranscribeAI Developer" \
    --identifier "com.metawhisp.app" \
    -o runtime \
    --entitlements "Resources/MetaWhisp.entitlements" \
    --requirements '=designated => identifier "com.metawhisp.app"' \
    --deep "$APP_DIR" 2>&1 || \
codesign --force --sign - --identifier "com.metawhisp.app" \
    --entitlements "Resources/MetaWhisp.entitlements" \
    --deep "$APP_DIR" 2>/dev/null || true
echo "==> Code signed (with entitlements)"

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
