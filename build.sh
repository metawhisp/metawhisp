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

# ──────────────────────────────────────────────────────────────────────────────
# Compile MLX Metal shaders → mlx.metallib (mandatory for MLX init)
# ──────────────────────────────────────────────────────────────────────────────
# WHY: mlx-swift's `Cmlx` target lists 8 `.metal` shader source files in
# `Source/Cmlx/mlx-generated/metal/` but does NOT declare them as
# `.process(...)` resources in its `Package.swift`. As a result `swift build`
# compiles the C++ side (libmlx) but never produces the runtime `.metallib`
# that `mlx/mlx/backend/metal/device.cpp:load_default_library` searches for.
#
# At runtime MLX tries (in order):
#   1. <binary_dir>/mlx.metallib                    ← colocated
#   2. <mainBundle>/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/<lib>.metallib
#   3. AllBundles / AllFrameworks loop for SWIFTPM_BUNDLE
# If none exists the C++ side throws and the process exits. v1.3.5 release
# (2026-05-21) shipped without metallib → crash on first `eval(...)` → user-
# reported "app не работает" minutes after upload. Old /Applications survived
# only because a much older Xcode-built bundle had a metallib that lingered
# until the next `rm -rf "$APP"; ditto` cycle.
#
# Layer-1 root-cause fix: WE own the bundle; mlx-swift gave us source `.metal`
# files; turning them into the runtime metallib is OUR responsibility in the
# build pipeline. Done here, BEFORE codesign, so the signature seals the file.
#
# This block is mandatory — any failure aborts the build. Better to fail loud
# at release time than ship a binary that crashes on every user's machine.
MLX_METAL_DIR="$SCRIPT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ ! -d "$MLX_METAL_DIR" ]; then
    echo "==> ❌ mlx-swift metal sources not found at $MLX_METAL_DIR"
    echo "    Run \`swift build\` first so SPM checks out mlx-swift."
    exit 1
fi
METAL_BUILD_DIR=$(mktemp -d -t mw-metalbuild)
trap "rm -rf '$METAL_BUILD_DIR'" EXIT
echo "==> Compiling MLX metal shaders → mlx.metallib..."
metal_count=0
for m in "$MLX_METAL_DIR"/*.metal; do
    name=$(basename "${m%.metal}")
    if ! xcrun -sdk macosx metal -c "$m" -I "$MLX_METAL_DIR" -o "$METAL_BUILD_DIR/${name}.air" 2>&1 | head -5; then
        echo "==> ❌ Failed to compile $m"
        exit 1
    fi
    metal_count=$((metal_count + 1))
done
echo "    Compiled $metal_count metal sources → .air"
if ! xcrun -sdk macosx metallib "$METAL_BUILD_DIR"/*.air -o "$MACOS/mlx.metallib" 2>&1 | head -5; then
    echo "==> ❌ Failed to link metallib"
    exit 1
fi
if [ ! -s "$MACOS/mlx.metallib" ]; then
    echo "==> ❌ mlx.metallib is missing or empty after link"
    exit 1
fi
metallib_size=$(stat -f%z "$MACOS/mlx.metallib")
echo "    mlx.metallib OK (${metallib_size} bytes, colocated next to binary)"

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
# Sign with Developer ID cert by SHA-1 hash (privacy: hash never reveals
# the legal name on the cert, unlike the human-readable identity string).
# Look up the hash dynamically by team ID 6D6948Z4MW so this works whether
# the cert is currently labelled "MetaWhisp Maintainer" or any prior legal
# name on the same Apple Developer Program team.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:.*\(6D6948Z4MW\)/ {print $2; exit}')
if [ -z "$SIGN_IDENTITY" ]; then
    echo "==> ⚠️  Developer ID cert (team 6D6948Z4MW) not found, falling back to ad-hoc (TCC will reset each rebuild)"
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
        # Retry budget bumped 3 → 10 with exponential-ish backoff after a
        # 2026-05-09 release where Apple TSA was returning "OK but no
        # timestamp" for 5+ minutes straight, blowing through the old 3×2s
        # window in 8 seconds. Real outages last minutes; we need to wait it
        # out, not give up.
        local attempt
        local sleep_sec=5
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            codesign --force --sign "$SIGN_IDENTITY" \
                --options runtime \
                --timestamp \
                --identifier "$identifier" \
                "$target"
            # Verify timestamp landed. IMPORTANT — must NOT use
            # `codesign -dvvv | grep -q "^Timestamp="` directly: grep -q
            # exits on first match, the unread tail of codesign output
            # SIGPIPEs (exit 141), and under `set -o pipefail` the pipeline
            # exit code becomes 141 → the `if` evaluates as failure →
            # every attempt is reported as "no timestamp" even when the
            # timestamp was actually attached. 2026-05-21 incident: 4 hours
            # of retry cycles before this was identified. Dump codesign
            # output to a temp file first, then grep the file (no pipe).
            local cs_log
            cs_log=$(mktemp)
            codesign -dvvv "$target" >"$cs_log" 2>&1 || true
            if grep -q "^Timestamp=" "$cs_log"; then
                rm -f "$cs_log"
                return 0
            fi
            rm -f "$cs_log"
            echo "==> ⚠️  No timestamp on $(basename "$target") (attempt $attempt/10) — TSA flake, sleeping ${sleep_sec}s..."
            sleep "$sleep_sec"
            sleep_sec=$((sleep_sec < 60 ? sleep_sec + 10 : 60))
            codesign --remove-signature "$target" 2>/dev/null || true
        done
        echo "==> ❌ Failed to attach timestamp to $target after 10 retries (TSA outage > 5 min — try again later)"
        return 1
    }
    sign_target "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"  "org.sparkle-project.Downloader"
    sign_target "$SPARKLE/Versions/B/XPCServices/Installer.xpc"   "org.sparkle-project.InstallerLauncher"
    sign_target "$SPARKLE/Versions/B/Updater.app"                 "org.sparkle-project.Sparkle.Updater"
    sign_target "$SPARKLE/Versions/B/Autoupdate"                  "org.sparkle-project.Sparkle.Autoupdate"
    sign_target "$SPARKLE/Versions/B/Sparkle"                     "org.sparkle-project.Sparkle"
    sign_target "$SPARKLE"                                        "org.sparkle-project.Sparkle"
fi

# Sign mlx.metallib — codesign --deep on the outer bundle requires every
# nested binary to be individually signed first. Metal libraries are
# Mach-O-like artifacts so codesign treats them as code objects. Without
# this step the outer bundle sign fails:
#   "code object is not signed at all In subcomponent: .../mlx.metallib"
# We sign with --timestamp here too so the metallib survives notarization;
# Apple's notary rejects un-timestamped Mach-O in app bundles.
if [ -f "$MACOS/mlx.metallib" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$MACOS/mlx.metallib"
fi

# Sign outer bundle with our app identifier — macOS uses Identifier as app identity
# for notifications, TCC, and URL scheme registration.
# `--timestamp` is MANDATORY for notarization (Apple verifies timestamp via
# their TSA) and required for the app to open on other Macs.
# Retry on missing timestamp — same TSA-flake guard as sign_target above.
# Bumped 3 → 10 with longer sleeps for real TSA outages (2026-05-09).
outer_sleep=5
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --identifier "com.metawhisp.app" \
        --entitlements "Resources/MetaWhisp.entitlements" \
        "$APP_DIR" 2>&1
    # Same SIGPIPE pitfall as `sign_target` above — `grep -q` over a pipe
    # makes the unread tail SIGPIPE codesign, pipeline exits 141 under
    # `pipefail`, and we falsely loop. Dump to file, grep the file.
    outer_cs_log=$(mktemp)
    codesign -dvvv "$APP_DIR" >"$outer_cs_log" 2>&1 || true
    if grep -q "^Timestamp=" "$outer_cs_log"; then
        rm -f "$outer_cs_log"
        break
    fi
    rm -f "$outer_cs_log"
    echo "==> ⚠️  No timestamp on outer bundle (attempt $attempt/10) — TSA flake, sleeping ${outer_sleep}s..."
    sleep "$outer_sleep"
    outer_sleep=$((outer_sleep < 60 ? outer_sleep + 10 : 60))
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

# Copy to stable location.
# `ditto` (NOT `cp -r`) — `cp -r` on macOS dereferences symlinks, which
# destroys the symlink structure inside Sparkle.framework (Versions/Current,
# Sparkle, Headers, Resources etc are all symlinks). Once symlinks become
# real files, the codesign hashes computed in `--sign` above stop matching
# the on-disk content and Apple notary rejects with
# "The signature of the binary is invalid". Discovered 2026-05-09 after 4
# failed releases — ship blocker for v1.3.2.
rm -rf "$INSTALLED_APP"
ditto "$APP_DIR" "$INSTALLED_APP"
echo "==> Installed to: $INSTALLED_APP"

# Launch from stable location (skip with --no-launch)
if [ "$NO_LAUNCH" = false ]; then
    echo "==> Launching MetaWhisp..."
    open "$INSTALLED_APP"
fi
