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
# Frameworks/ is the standard Apple location for embedded frameworks. Putting
# Sparkle.framework here (instead of Contents/MacOS/) is REQUIRED for Apple
# notarization — codesign otherwise calls the bundle "ambiguous (could be
# app or framework)" because a `.framework` next to the main executable
# confuses the bundle-format heuristic. Notarization rejected our DMG with
# "signature of the binary is invalid" until we moved Sparkle to Frameworks/.
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"

# Clean previous bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

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

# Copy shrek-pill.mov — 5th pill style. SPM's `.copy` in Package.swift doesn't
# survive the build.sh rebundle step, so we copy explicitly here. The binary
# resolves it via `Bundle(for: ShrekVideoLayer.Coordinator.self)` which points
# at this `Contents/Resources/` location.
if [ -f "Resources/shrek-pill.mov" ]; then
    cp "Resources/shrek-pill.mov" "$RESOURCES/shrek-pill.mov"
fi

# Copy Sparkle framework into Contents/Frameworks/ (Apple's standard location).
# SPM compiles the binary with rpath `@loader_path` (= alongside the main
# executable, i.e. Contents/MacOS/). With Sparkle moved to Contents/Frameworks/
# we must add an additional rpath pointing one directory up + Frameworks/ so
# dyld can still find Sparkle.framework at runtime.
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    # Use `ditto` instead of `cp -R` — ditto reliably preserves the symlink
    # structure required for a valid macOS framework. `cp -R` on this layout
    # was producing duplicates (real files at root AND in Versions/B), which
    # made Apple notarization reject the binary as "signature invalid"
    # because the bundle structure was malformed.
    ditto "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/MetaWhisp" 2>/dev/null || true
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
SIGN_IDENTITY="Developer ID Application: MetaWhisp Maintainer (6D6948Z4MW)"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "==> ⚠️  Developer ID cert not found, falling back to ad-hoc (TCC will reset each rebuild)"
    SIGN_IDENTITY="-"
fi

# Sign nested Sparkle components bottom-up. We REMOVE the existing Sparkle
# Project signatures first (they were valid for Sparkle Project's identity but
# break notarization when we re-sign with our cert + --preserve-metadata which
# keeps stale Sparkle entitlements/flags). After remove, we re-sign with explicit
# `--identifier` so dyld still loads them as `org.sparkle-project.*`.
SPARKLE="$FRAMEWORKS/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    # Pairs of "path:identifier" for each nested target.
    sign_target() {
        local target="$1"
        local identifier="$2"
        # Best-effort remove existing signature; ignored if absent.
        codesign --remove-signature "$target" 2>/dev/null || true
        # Sign + verify timestamp landed. Apple's TSA (timestamp.apple.com)
        # occasionally returns "OK but no timestamp" on flaky network — codesign
        # silently accepts that with exit 0, and Apple's notarization later
        # rejects with "signature of the binary is invalid". Verify after each
        # sign and retry up to 3 times on missing timestamp.
        local attempt
        for attempt in 1 2 3; do
            codesign --force --sign "$SIGN_IDENTITY" \
                --options runtime \
                --timestamp \
                --identifier "$identifier" \
                "$target"
            if codesign -dvvv "$target" 2>&1 | grep -q "^Timestamp="; then
                return 0
            fi
            echo "==> ⚠️  No timestamp on $(basename "$target") (attempt $attempt/3) — TSA flake, retrying..."
            sleep 2
            codesign --remove-signature "$target" 2>/dev/null || true
        done
        echo "==> ❌ Failed to attach timestamp to $target after 3 retries"
        return 1
    }
    sign_target "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"  "org.sparkle-project.Downloader"
    sign_target "$SPARKLE/Versions/B/XPCServices/Installer.xpc"   "org.sparkle-project.InstallerLauncher"
    sign_target "$SPARKLE/Versions/B/Updater.app"                 "org.sparkle-project.Sparkle.Updater"
    sign_target "$SPARKLE/Versions/B/Autoupdate"                  "org.sparkle-project.Sparkle.Autoupdate"
    sign_target "$SPARKLE/Versions/B/Sparkle"                     "org.sparkle-project.Sparkle"
    sign_target "$SPARKLE"                                        "org.sparkle-project.Sparkle"
fi

# Sign outer bundle with our app identifier — macOS uses Identifier as app identity
# for notifications, TCC, and URL scheme registration.
# `--timestamp` is MANDATORY for notarization (Apple verifies timestamp via
# their TSA) and required for the app to open on other Macs.
# Retry on missing timestamp — same TSA-flake guard as sign_target above.
for attempt in 1 2 3; do
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --identifier "com.metawhisp.app" \
        --entitlements "Resources/MetaWhisp.entitlements" \
        "$APP_DIR" 2>&1
    if codesign -dvvv "$APP_DIR" 2>&1 | grep -q "^Timestamp="; then
        break
    fi
    echo "==> ⚠️  No timestamp on outer bundle (attempt $attempt/3) — TSA flake, retrying..."
    sleep 2
    codesign --remove-signature "$APP_DIR" 2>/dev/null || true
done

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
SPARKLE_ID=$(codesign -dvv "$FRAMEWORKS/Sparkle.framework" 2>&1 | grep -E "^Identifier=" | cut -d= -f2)
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
