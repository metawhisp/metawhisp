# scripts/lib/app-install.sh — sourced by build.sh, hot-swap.sh, release.sh,
# make-dmg-manual.sh and make-zip.sh. Never run on its own.
#
# ITER-076 0.1 — a test build replaces the working app in /Applications (owner,
# 2026-09-26: no separate test copy), and a swap is built never to leave it
# broken; the known limits below say where that stops. On
# 2026-09-25 a swap stopped the app, a signing step failed, an ad-hoc signature
# brought it back, and macOS then refused its permissions.
#   - Signing uses the team's Developer ID identity only, tested on a throwaway
#     file before anything is built or touched. There is no ad-hoc fallback.
#   - The new build carries the working app's bundle id and the same designated
#     requirement as the installed one, so macOS keeps its permissions and its
#     keychain access.
#   - The swap refuses while the app records or transcribes: the app writes what
#     it is busy with to activity.json (ActivityLease.swift). A running app that
#     wrote no lease of its own is refused too, unless MW_CONFIRM_IDLE=1 says the
#     caller checked it is idle.
#   - The app is asked to quit with SIGTERM, a normal quit in the app with its
#     meeting rescue, and is never force-killed.
#   - The new build is copied beside the installed one and its signature
#     checked there while the installed app still runs; one rename then puts
#     it in place, so a copy cut off at any point — a crash, a power cut —
#     leaves the installed app whole (the Kimi audit, 2026-09-27).
#   - The installed app is kept until the new one has started, stayed up and
#     written its own lease, and is put back on any failure, an interrupt or a
#     closed terminal included. After a swap it stays as "MetaWhisp.previous",
#     which is not a bundle, so macOS never opens it; `hot-swap.sh --rollback`
#     puts it back.
#   - One swap at a time, across every copy of the repo on this Mac.
#
# Known limits (reviews of 0.1, 2026-09-27):
#   - A rollback puts back an older build. If a newer build already moved the
#     app's data to a new SwiftData schema version, the older one can't open
#     it: an iteration that adds a schema version adds a schema check here first.
#   - Two swaps that find the same stale lock within milliseconds can both run.
#   - The busy check and the quit are tens of milliseconds apart.
#   - The swap folder and /Applications must be on one volume, so that one
#     rename puts the copy in place; a swap checks it and refuses otherwise.
#   - --confirm-idle is checked before the build, which takes minutes, and
#     applies at the quit: a build from before the lease that starts recording
#     meanwhile is quit without its meeting rescue.
#
# Tests swap the tools and folders through the MW_* variables; real runs never
# set them.

MW_TEAM_ID="6D6948Z4MW"
MW_CODESIGN="${MW_CODESIGN:-/usr/bin/codesign}"
MW_SECURITY="${MW_SECURITY:-/usr/bin/security}"
MW_OPEN="${MW_OPEN:-/usr/bin/open}"
MW_PLISTBUDDY="/usr/libexec/PlistBuddy"

MW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MW_PRODUCTION_BUNDLE_ID="com.metawhisp.app"
# The signed bundle build.sh leaves for release.sh, make-dmg-manual.sh and make-zip.sh.
MW_RELEASE_APP="$MW_REPO_ROOT/.build/arm64-apple-macosx/release/MetaWhisp.app"

MW_APP_NAME="MetaWhisp"
MW_APP_EXECUTABLE="MetaWhisp"
MW_APP_INSTALL_DIR="${MW_APP_INSTALL_DIR:-/Applications}"
# The working app's own data folder (AppIdentity, production), where it writes activity.json.
MW_APP_SUPPORT_DIR="${MW_APP_SUPPORT_DIR:-$HOME/Library/Application Support/MetaWhisp}"
# The copies a swap keeps, and its lock.
MW_SWAP_DIR="${MW_SWAP_DIR:-$MW_APP_SUPPORT_DIR/.swap}"
MW_QUIT_TIMEOUT="${MW_QUIT_TIMEOUT:-15}"
MW_LAUNCH_TIMEOUT="${MW_LAUNCH_TIMEOUT:-10}"
# How long a new app has to write its own lease, and then stay up, to count as installed.
MW_HEALTH_TIMEOUT="${MW_HEALTH_TIMEOUT:-20}"
MW_LAUNCH_SETTLE="${MW_LAUNCH_SETTLE:-3}"
MW_SELF_CHECK_TIMEOUT="${MW_SELF_CHECK_TIMEOUT:-60}"
MW_SELF_CHECK_GRACE="${MW_SELF_CHECK_GRACE:-5}"

# The state of a swap under way; mw_rollback, mw_recover_unarmed and mw_on_exit
# read it.
MW_SWAP_STARTED=false
MW_ROLLBACK_ACTIVE=false
MW_SWAP_SUCCEEDED=false
MW_KEPT_REPLACED=false
MW_COPY_VERIFIED=false
MW_ROLLBACK_RELAUNCH=false
MW_LOCK_HELD=""
MW_EXIT_CLEANUP=""
MW_SELF_CHECK_PID=""

mw_fail() {
    echo "==> ❌ $*" >&2
    return 1
}

mw_target() { echo "$MW_APP_INSTALL_DIR/$MW_APP_NAME.app"; }
mw_target_exe() { echo "$MW_APP_INSTALL_DIR/$MW_APP_NAME.app/Contents/MacOS/$MW_APP_EXECUTABLE"; }

# Prints the SHA-1 of the team's Developer ID Application identity.
mw_signing_identity() {
    local list id
    list=$("$MW_SECURITY" find-identity -v -p codesigning 2>/dev/null) || list=""
    id=$(awk -v team="($MW_TEAM_ID)" \
        'index($0, "Developer ID Application:") && index($0, team) { print $2; exit }' <<<"$list")
    if [ -z "$id" ]; then
        mw_fail "No Developer ID Application identity of team $MW_TEAM_ID in the keychain, so nothing was built or touched. An ad-hoc signature is never used: macOS would reset every permission."
        return 1
    fi
    echo "$id"
}

# Signs a throwaway copy of /usr/bin/true and checks the team, so a locked
# keychain or a refused key stops everything before anything is touched.
mw_preflight_sign() {
    local identity="$1" dir out info
    if ! dir=$(mktemp -d -t mw-preflight); then
        mw_fail "Could not make a folder for the signing test."
        return 1
    fi
    if ! cp /usr/bin/true "$dir/probe"; then
        rm -rf "$dir"
        mw_fail "Could not copy the signing test file."
        return 1
    fi
    # No timestamp: the test is about the key, and must not wait on Apple's server.
    if ! out=$("$MW_CODESIGN" --force --sign "$identity" --timestamp=none "$dir/probe" 2>&1); then
        rm -rf "$dir"
        mw_fail "The signing test failed, so nothing was built or touched:
$out
Fix: unlock the login keychain, run this again, and answer \"Always Allow\" when macOS asks whether codesign may use the Developer ID key."
        return 1
    fi
    info=$("$MW_CODESIGN" -dvv "$dir/probe" 2>&1) || info=""
    rm -rf "$dir"
    if ! grep -q "^TeamIdentifier=$MW_TEAM_ID\$" <<<"$info"; then
        mw_fail "The signing test did not make a signature of team $MW_TEAM_ID, so nothing was built or touched."
        return 1
    fi
}

# Prints what the app is busy with: idle, recording, transcribing or running an
# errand. No lease, an unreadable one, a process that is gone, or a pid that now
# runs another program counts as idle, so a crash never blocks a swap.
mw_lease_state() {
    local file="$1" pid state exe running
    if [ ! -f "$file" ]; then echo idle; return 0; fi
    pid=$(plutil -extract pid raw -o - "$file" 2>/dev/null) || { echo idle; return 0; }
    state=$(plutil -extract state raw -o - "$file" 2>/dev/null) || { echo idle; return 0; }
    exe=$(plutil -extract executable raw -o - "$file" 2>/dev/null) || exe=""
    case "$pid" in ''|*[!0-9]*) echo idle; return 0 ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then echo idle; return 0; fi
    running=$(ps -o comm= -p "$pid" 2>/dev/null) || running=""
    if [ -n "$exe" ] && [ "$running" != "$exe" ]; then echo idle; return 0; fi
    echo "$state"
}

# The pid that wrote the lease, or nothing.
mw_lease_pid() {
    local pid
    pid=$(plutil -extract pid raw -o - "$1" 2>/dev/null) || pid=""
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    echo "$pid"
}

# Refuses while the app records or transcribes, and while a running copy has
# written no lease of its own (a build from before the lease can't say whether
# it is recording), unless MW_CONFIRM_IDLE=1.
mw_refuse_if_busy() {
    local exe lease state pids owner pid
    exe=$(mw_target_exe)
    lease="$MW_APP_SUPPORT_DIR/activity.json"
    state=$(mw_lease_state "$lease")
    if [ "$state" != "idle" ]; then
        mw_fail "$MW_APP_NAME is $state right now, so the swap was refused and nothing was touched. Run it again when it has finished."
        return 1
    fi
    pids=$(mw_pids_of "$exe")
    if [ -z "$pids" ] || [ "${MW_CONFIRM_IDLE:-0}" = 1 ]; then return 0; fi
    owner=$(mw_lease_pid "$lease")
    for pid in $pids; do
        if [ "$pid" = "$owner" ]; then return 0; fi
    done
    mw_fail "$MW_APP_NAME is running but wrote no activity lease, so it can't tell whether it is recording. The swap was refused and nothing was touched. If it is idle, run again with --confirm-idle."
    return 1
}

# Only the working app is installed here: its bundle id and its executable.
mw_check_app_plist() {
    local plist="$1" id exe
    id=$("$MW_PLISTBUDDY" -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null) || id=""
    exe=$("$MW_PLISTBUDDY" -c "Print :CFBundleExecutable" "$plist" 2>/dev/null) || exe=""
    if [ "$id" != "$MW_PRODUCTION_BUNDLE_ID" ] || [ "$exe" != "$MW_APP_EXECUTABLE" ]; then
        mw_fail "$plist has bundle id '$id' and executable '$exe': only $MW_PRODUCTION_BUNDLE_ID with executable $MW_APP_EXECUTABLE is installed here."
        return 1
    fi
}

# The bundle's signature verifies, is the team's Developer ID, and carries the
# given identifier.
mw_verify_signature() {
    local app="$1" expected="$2" info signed
    if ! "$MW_CODESIGN" --verify --deep --strict "$app" >/dev/null 2>&1; then
        mw_fail "The signature of $app does not verify."
        return 1
    fi
    info=$("$MW_CODESIGN" -dvv "$app" 2>&1) || info=""
    signed=$(sed -n 's/^Identifier=//p' <<<"$info")
    if [ "$signed" != "$expected" ]; then
        mw_fail "$app is signed as '$signed', expected '$expected'."
        return 1
    fi
    if ! grep -q "^TeamIdentifier=$MW_TEAM_ID\$" <<<"$info" \
        || ! grep -q "^Authority=Developer ID Application:" <<<"$info"; then
        mw_fail "$app is not signed with the team's Developer ID."
        return 1
    fi
}

# The bundle's designated requirement: what macOS keys permissions and keychain
# access to.
mw_designated_requirement() {
    { "$MW_CODESIGN" -d -r- "$1" 2>/dev/null || true; } | sed -n 's/^designated => //p'
}

# The new build must meet the same designated requirement as the installed app,
# or macOS would treat it as another app. A first install has nothing to match.
mw_same_requirement() {
    local new="$1" installed="$2" a b
    if [ ! -e "$installed" ]; then return 0; fi
    a=$(mw_designated_requirement "$installed")
    if [ -z "$a" ]; then
        mw_fail "The installed $MW_APP_NAME has no designated requirement this can read: it is signed ad hoc or not at all, so no build could keep its permissions. Nothing was touched. Install the latest release from its release DMG, then run this again."
        return 1
    fi
    b=$(mw_designated_requirement "$new")
    if [ -z "$b" ] || [ "$a" != "$b" ]; then
        mw_fail "The new build's designated requirement differs from the installed app's, so macOS would drop its permissions and keychain access. Nothing was touched. If the installed app is not the team's own build, install the latest release from its release DMG, then run this again.
installed: $a
new:       $b"
        return 1
    fi
}

# Runs the bundle's self-check (`--self-check`, SelfCheck.swift): the app starts,
# checks its parts and exits by itself before it opens any data, so this is
# safe beside the working app. $1 is the executable. It never hangs: a check
# that runs past MW_SELF_CHECK_TIMEOUT is asked to stop, and one that has not
# stopped MW_SELF_CHECK_GRACE seconds later is reported and left running, never
# waited on.
mw_self_check() {
    local exe="$1" out pid status waited=0 grace=0
    if ! out=$(mktemp -t mw-self-check); then
        mw_fail "Could not make a file for the self-check."
        return 1
    fi
    "$exe" --self-check >"$out" 2>&1 &
    pid=$!
    MW_SELF_CHECK_PID="$pid"
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge $((MW_SELF_CHECK_TIMEOUT * 2)) ]; then
            kill -TERM "$pid" 2>/dev/null || true
            while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt $((MW_SELF_CHECK_GRACE * 2)) ]; do
                sleep 0.5
                grace=$((grace + 1))
            done
            MW_SELF_CHECK_PID=""
            if kill -0 "$pid" 2>/dev/null; then
                mw_fail "The self-check of $exe did not finish within ${MW_SELF_CHECK_TIMEOUT}s and did not stop when asked; it is left running as pid $pid:
$(cat "$out")"
            else
                wait "$pid" 2>/dev/null || true
                mw_fail "The self-check of $exe did not finish within ${MW_SELF_CHECK_TIMEOUT}s:
$(cat "$out")"
            fi
            rm -f "$out"
            return 1
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    MW_SELF_CHECK_PID=""
    if wait "$pid"; then status=0; else status=$?; fi
    if [ "$status" -ne 0 ] || ! grep -q "^SELF-CHECK OK\$" "$out"; then
        mw_fail "The self-check of $exe failed (exit $status):
$(cat "$out")"
        rm -f "$out"
        return 1
    fi
    rm -f "$out"
    echo "==> Self-check passed: $exe"
}

# The pids running the given executable. The command line is matched from its
# start, so a program that only mentions the path never matches, and characters
# that mean something in a pattern are escaped.
mw_pids_of() {
    local pattern
    pattern=$(printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
    pgrep -f "^$pattern( |\$)" 2>/dev/null || true
}

# Waits, sending nothing, until no process runs the given executable; fails
# after MW_QUIT_TIMEOUT.
mw_wait_gone() {
    local exe="$1" tries=0
    while [ -n "$(mw_pids_of "$exe")" ]; do
        if [ "$tries" -ge $((MW_QUIT_TIMEOUT * 2)) ]; then return 1; fi
        sleep 0.5
        tries=$((tries + 1))
    done
}

# Asks the running app to quit and waits for it. In the app SIGTERM is a normal
# quit, meeting rescue included. It is never force-killed: if it has not quit in
# time, the swap stops and nothing is replaced.
mw_quit_app() {
    local exe="$1" pids
    pids=$(mw_pids_of "$exe")
    if [ -z "$pids" ]; then return 0; fi
    echo "==> Asking $MW_APP_NAME to quit..."
    kill -TERM $pids 2>/dev/null || true
    if mw_wait_gone "$exe"; then return 0; fi
    mw_fail "$MW_APP_NAME did not quit within ${MW_QUIT_TIMEOUT}s. It may be waiting for an open dialog or menu to close, and then quits by itself. It was not force-killed, and nothing was replaced."
    return 1
}

# Opens the installed app and waits until it counts as running: it started,
# wrote its own lease within MW_HEALTH_TIMEOUT, and is still up MW_LAUNCH_SETTLE
# seconds later. Every open here asks for a new instance (`-n`): right after
# the bundle at the install folder was replaced, macOS can resolve the app to
# the process that just quit and refuse the open with -600 (2026-10-20,
# launchservicesd "resolved to" the old pid; three swaps of eight rolled back
# so). Each caller has already seen that process gone.
mw_launch_and_check() {
    local target exe lease tries=0 pid=""
    target=$(mw_target)
    exe=$(mw_target_exe)
    lease="$MW_APP_SUPPORT_DIR/activity.json"
    "$MW_OPEN" -n "$target" || true
    while [ -z "$pid" ]; do
        if [ "$tries" -ge $((MW_LAUNCH_TIMEOUT * 2)) ]; then
            mw_fail "The new $MW_APP_NAME did not start within ${MW_LAUNCH_TIMEOUT}s."
            return 1
        fi
        sleep 0.5
        tries=$((tries + 1))
        pid=$(mw_pids_of "$exe" | head -1)
    done
    tries=0
    while [ "$(mw_lease_pid "$lease")" != "$pid" ]; do
        if [ "$tries" -ge $((MW_HEALTH_TIMEOUT * 2)) ] || ! kill -0 "$pid" 2>/dev/null; then
            mw_fail "The new $MW_APP_NAME did not write its activity lease within ${MW_HEALTH_TIMEOUT}s of starting."
            return 1
        fi
        sleep 0.5
        tries=$((tries + 1))
    done
    # A build that crashes right after it starts must not replace the previous one.
    sleep "$MW_LAUNCH_SETTLE"
    if ! kill -0 "$pid" 2>/dev/null; then
        mw_fail "The new $MW_APP_NAME quit within ${MW_LAUNCH_SETTLE}s of starting."
        return 1
    fi
}

# One swap at a time, across every copy of the repo on this Mac: the lock is a
# folder that holds its run's pid. A lock whose run is gone, or that never got a
# pid and is older than 10 s, no longer counts, so a crash never blocks swaps.
mw_take_swap_lock() {
    local lock="$MW_SWAP_DIR/lock" holder age
    if ! mkdir -p "$MW_SWAP_DIR"; then
        mw_fail "Could not create $MW_SWAP_DIR."
        return 1
    fi
    if ! mkdir "$lock" 2>/dev/null; then
        holder=$(cat "$lock/pid" 2>/dev/null) || holder=""
        case "$holder" in ''|*[!0-9]*) holder="" ;; esac
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            mw_fail "Another swap of $MW_APP_NAME is running (pid $holder), so this one stopped and touched nothing. If no swap is running, remove $lock and run this again."
            return 1
        fi
        age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
        if [ -z "$holder" ] && [ "$age" -lt 10 ]; then
            mw_fail "Another swap of $MW_APP_NAME is starting, so this one stopped and touched nothing. If no swap is running, remove $lock and run this again."
            return 1
        fi
        rm -rf "$lock"
        if ! mkdir "$lock" 2>/dev/null; then
            mw_fail "Another swap of $MW_APP_NAME just started, so this one stopped and touched nothing."
            return 1
        fi
    fi
    echo "$$" > "$lock/pid"
    MW_LOCK_HELD="$lock"
}

# Releases the lock only while it still holds this run's pid.
mw_release_swap_lock() {
    if [ -n "$MW_LOCK_HELD" ] && [ "$(cat "$MW_LOCK_HELD/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$MW_LOCK_HELD"
    fi
    MW_LOCK_HELD=""
}

# Installs a signed build of the working app at $MW_APP_INSTALL_DIR/MetaWhisp.app,
# under the swap lock. $1 is the new bundle. The new build is always opened and
# checked: one installed without starting it could be broken.
mw_swap_app() {
    local status=0
    mw_take_swap_lock || return 1
    mw_swap_app_locked "$@" || status=$?
    mw_release_swap_lock
    return "$status"
}

mw_swap_app_locked() {
    local new="$1"
    local target exe current="$MW_SWAP_DIR/$MW_APP_NAME.current" previous="$MW_SWAP_DIR/$MW_APP_NAME.previous"
    local incoming="$MW_SWAP_DIR/$MW_APP_NAME.incoming"
    target=$(mw_target)
    exe=$(mw_target_exe)

    # Only the working app is installed here, and only a verified one that
    # macOS will take for the installed app.
    mw_check_app_plist "$new/Contents/Info.plist" || return 1
    mw_verify_signature "$new" "$MW_PRODUCTION_BUNDLE_ID" || return 1

    # A swap cut off hard can leave the installed app aside. It is never deleted
    # unseen: alone, it is put back; beside an app in place, both are kept, and
    # which one stays is the owner's call.
    if [ -e "$current" ]; then
        if [ -e "$target" ]; then
            mw_fail "An earlier swap kept two copies of $MW_APP_NAME: the installed one at $target and the one it replaced or put aside at $current. Keep the one you want, move the other to the Trash, then run this again. Nothing was touched."
            return 1
        fi
        if ! mv "$current" "$target"; then
            mw_fail "The installed $MW_APP_NAME is in $current and could not be put back, so nothing was replaced."
            return 1
        fi
    fi

    mw_same_requirement "$new" "$target" || return 1

    # The new build is copied beside the installed one and checked there
    # while the installed app still runs: nothing in the install folder
    # changes until one rename puts the checked copy in place. A copy left by
    # a swap killed earlier is removed first. ditto, not cp -r: cp -r turns
    # Sparkle's symlinks into files and the signature no longer matches.
    local swap_volume install_volume
    swap_volume=$(stat -f %d "$MW_SWAP_DIR" 2>/dev/null) || swap_volume=""
    install_volume=$(stat -f %d "$MW_APP_INSTALL_DIR" 2>/dev/null) || install_volume=""
    if [ -z "$swap_volume" ] || [ "$swap_volume" != "$install_volume" ]; then
        mw_fail "$MW_SWAP_DIR and $MW_APP_INSTALL_DIR are not on the same volume, so the new $MW_APP_NAME could not be put in place with one rename. Nothing was touched."
        return 1
    fi
    rm -rf "$incoming" 2>/dev/null || true
    if [ -e "$incoming" ]; then
        mw_fail "A copy left by an earlier swap at $incoming could not be removed, so nothing was replaced."
        return 1
    fi
    if ! ditto "$new" "$incoming"; then
        rm -rf "$incoming" 2>/dev/null || true
        mw_fail "Copying the new $MW_APP_NAME failed; the installed one was not touched."
        return 1
    fi
    if ! mw_verify_signature "$incoming" "$MW_PRODUCTION_BUNDLE_ID"; then
        rm -rf "$incoming" 2>/dev/null || true
        return 1
    fi

    # Checked right before the quit: the copy takes seconds.
    if ! mw_refuse_if_busy; then
        rm -rf "$incoming" 2>/dev/null || true
        return 1
    fi
    MW_ROLLBACK_RELAUNCH=false
    if [ -n "$(mw_pids_of "$exe")" ]; then MW_ROLLBACK_RELAUNCH=true; fi
    # From here the installed app may be quit or moved aside, so an exit before
    # the rollback is armed still puts it back (mw_recover_unarmed).
    MW_SWAP_STARTED=true
    if ! mw_quit_app "$exe"; then
        MW_SWAP_STARTED=false
        rm -rf "$incoming" 2>/dev/null || true
        return 1
    fi

    if [ -e "$target" ] && ! mv "$target" "$current"; then
        mw_fail "Could not move the installed $MW_APP_NAME aside, so nothing was replaced."
        rm -rf "$incoming" 2>/dev/null || true
        mw_recover_unarmed
        return 1
    fi
    MW_ROLLBACK_ACTIVE=true
    MW_SWAP_STARTED=false
    MW_COPY_VERIFIED=false

    # One rename puts the checked copy in place: the install folder never
    # holds half an app.
    if ! mv "$incoming" "$target"; then
        mw_fail "Putting the new $MW_APP_NAME in place failed."
        mw_rollback
        rm -rf "$incoming" 2>/dev/null || true
        return 1
    fi
    MW_COPY_VERIFIED=true
    if ! mw_launch_and_check; then
        mw_rollback
        return 1
    fi
    MW_ROLLBACK_ACTIVE=false
    MW_SWAP_SUCCEEDED=true
    mw_keep_replaced || true
    echo "==> Installed: $target"
    if [ "$MW_KEPT_REPLACED" = true ]; then echo "    The one it replaced is kept; bash hot-swap.sh --rollback puts it back."; fi
    mw_warn_old_working_copy
}

# Keeps the build a successful swap replaced as the one --rollback puts back.
# Never moves it into a kept copy that is still there; says so instead, since
# the next swap stops on the leftover.
mw_keep_replaced() {
    local current="$MW_SWAP_DIR/$MW_APP_NAME.current" previous="$MW_SWAP_DIR/$MW_APP_NAME.previous"
    # An interrupt here would leave the replaced build beside the new one and
    # stop every later swap, so it waits until the build is kept.
    trap '' INT TERM HUP
    MW_KEPT_REPLACED=false
    if [ ! -e "$current" ]; then
        MW_SWAP_SUCCEEDED=false
        return 0
    fi
    if mw_keep_as_previous; then
        MW_SWAP_SUCCEEDED=false
        MW_KEPT_REPLACED=true
        return 0
    fi
    MW_SWAP_SUCCEEDED=false
    echo "==> ⚠️  The replaced $MW_APP_NAME could not be kept for --rollback; it is at $current. Swaps stop until you remove $previous and move $current there." >&2 || true
    return 1
}

# Makes the build at $current the one --rollback puts back. The older kept
# build is renamed aside and deleted only once $current is in its place: a kill
# at any point leaves a kept build or $current, never neither — and what it
# can leave, an older copy aside or $current beside the app, the next keep or
# swap clears or reports (the Kimi audit, 2026-09-27). Fails, touching nothing,
# when the older kept build can't be moved aside.
mw_keep_as_previous() {
    local current="$MW_SWAP_DIR/$MW_APP_NAME.current" previous="$MW_SWAP_DIR/$MW_APP_NAME.previous"
    local stale="$MW_SWAP_DIR/$MW_APP_NAME.previous.stale.$$"
    # A stale copy under this run's own pid can only be a dead run's.
    if [ -e "$stale" ]; then rm -rf "$stale" 2>/dev/null || true; fi
    if [ -e "$previous" ] && ! mv "$previous" "$stale" 2>/dev/null; then return 1; fi
    if [ -e "$previous" ] || ! mv "$current" "$previous" 2>/dev/null; then
        if [ -e "$stale" ] && [ ! -e "$previous" ]; then mv "$stale" "$previous" 2>/dev/null || true; fi
        return 1
    fi
    rm -rf "$stale" "$previous".stale.* 2>/dev/null || true
}

# A swap cut off after it asked the installed app to quit, but before its
# rollback was armed: the app may be quit, or already moved aside. It is put
# back, and opened again once the old process is gone if it was running.
mw_recover_unarmed() {
    local target exe current="$MW_SWAP_DIR/$MW_APP_NAME.current"
    if [ "$MW_SWAP_STARTED" != true ]; then return 0; fi
    trap '' INT TERM HUP
    MW_SWAP_STARTED=false
    target=$(mw_target)
    exe=$(mw_target_exe)
    if [ -e "$current" ] && [ ! -e "$target" ] && ! mv "$current" "$target" 2>/dev/null; then
        echo "==> ❌ Could not put the installed $MW_APP_NAME back; it is kept at $current." >&2 || true
        return 1
    fi
    if [ "$MW_ROLLBACK_RELAUNCH" = true ] && [ -e "$target" ] && mw_wait_gone "$exe"; then
        "$MW_OPEN" -n "$target" >/dev/null 2>&1 || true
    fi
    echo "==> The installed $MW_APP_NAME is back." >&2 || true
}

# Puts the installed app back after a swap that stopped half-way. It ignores
# further interrupts, leaves a new build that records running, moves the new
# build aside and puts the installed one back before it asks the new one to
# quit, deletes nothing until the installed one is back, and writes its
# messages last, so a closed terminal can't cut it short. Does nothing unless a
# swap is under way.
mw_rollback() {
    local target exe state owner current="$MW_SWAP_DIR/$MW_APP_NAME.current"
    local failed="$MW_SWAP_DIR/$MW_APP_NAME.failed" previous="$MW_SWAP_DIR/$MW_APP_NAME.previous" kept
    if [ "$MW_ROLLBACK_ACTIVE" != true ]; then return 0; fi
    MW_SWAP_STARTED=false
    target=$(mw_target)
    exe=$(mw_target_exe)
    trap '' INT TERM HUP
    # A new build that is recording or transcribing is never stopped. Only
    # its own lease counts: one left by a copy running elsewhere does not.
    state=$(mw_lease_state "$MW_APP_SUPPORT_DIR/activity.json")
    owner=$(mw_lease_pid "$MW_APP_SUPPORT_DIR/activity.json")
    if [ "$state" != "idle" ] && [ -n "$owner" ] && mw_pids_of "$exe" | grep -qx "$owner"; then
        MW_ROLLBACK_ACTIVE=false
        if [ ! -e "$current" ]; then
            echo "==> ❌ The new $MW_APP_NAME is $state, so it was not stopped; it stays at $target." >&2 || true
            return 1
        fi
        # The installed one becomes the kept build, so no leftover blocks the
        # next swap and --rollback puts it back once the new one has finished.
        if mw_keep_as_previous; then
            echo "==> ❌ The new $MW_APP_NAME is $state, so it was not stopped; it stays at $target. The installed one is kept at $previous: when the new one has finished, bash hot-swap.sh --rollback puts it back." >&2 || true
        else
            echo "==> ❌ The new $MW_APP_NAME is $state, so it was not stopped; it stays at $target. The installed one is at $current. Swaps stop until you remove $previous and move $current there." >&2 || true
        fi
        return 1
    fi
    # The new build is moved aside first, while it may still run, and the
    # installed one put back: an exit during the quit that follows, even a
    # hard one, leaves the installed app in place.
    if [ -e "$target" ]; then
        rm -rf "$failed" 2>/dev/null || true
        # An old copy that can't be removed never blocks the rollback.
        if [ -e "$failed" ]; then failed="$failed.$$"; rm -rf "$failed" 2>/dev/null || true; fi
        if [ -e "$failed" ] || ! mv "$target" "$failed" 2>/dev/null; then
            MW_ROLLBACK_ACTIVE=false
            if [ -e "$current" ]; then
                echo "==> ❌ The new $MW_APP_NAME could not be moved aside, so both copies are kept: the new one at $target, the installed one at $current." >&2 || true
            else
                echo "==> ❌ The new $MW_APP_NAME could not be moved aside; it stays at $target." >&2 || true
            fi
            return 1
        fi
    fi
    if [ -e "$current" ] && ! mv "$current" "$target" 2>/dev/null; then
        # A new build that is in place and verified is better than nothing in
        # /Applications. Without one, $failed may hold an older failed copy,
        # which stays out, and the next swap puts the installed one back from
        # $current.
        if [ "$MW_COPY_VERIFIED" = true ]; then mv "$failed" "$target" 2>/dev/null || true; fi
        MW_ROLLBACK_ACTIVE=false
        echo "==> ❌ Could not put the installed $MW_APP_NAME back; it is kept at $current." >&2 || true
        return 1
    fi
    MW_ROLLBACK_ACTIVE=false
    # Then the new build, which runs from the address it started at, is asked
    # to quit. It is never force-killed.
    if ! mw_quit_app "$exe" >/dev/null 2>&1; then
        if [ -e "$target" ]; then
            echo "==> ❌ The new $MW_APP_NAME did not quit, so it was moved to $failed while it runs, and the installed one is back. Quit the MetaWhisp that is running (the new one), then open MetaWhisp." >&2 || true
        else
            echo "==> ❌ The new $MW_APP_NAME did not quit, so it was moved to $failed while it runs. Quit the MetaWhisp that is running." >&2 || true
        fi
        return 1
    fi
    rm -rf "$failed" 2>/dev/null || true
    # A first install has nothing to put back.
    [ -e "$target" ] || return 0
    if [ "$MW_ROLLBACK_RELAUNCH" = true ]; then "$MW_OPEN" -n "$target" >/dev/null 2>&1 || true; fi
    echo "==> The installed $MW_APP_NAME is back." >&2 || true
}

# `hot-swap.sh --rollback`: swaps the kept previous build and the installed app,
# with the same guards as a swap, so running it twice gets back to where it was.
mw_restore_previous() {
    local status=0
    mw_take_swap_lock || return 1
    mw_restore_previous_locked || status=$?
    mw_release_swap_lock
    return "$status"
}

mw_restore_previous_locked() {
    local previous="$MW_SWAP_DIR/$MW_APP_NAME.previous" staged="$MW_SWAP_DIR/$MW_APP_NAME.restoring"
    # A rollback cut off half-way leaves the kept build staged; it is still the kept one.
    if [ ! -e "$previous" ] && [ -d "$staged" ] && ! mv "$staged" "$previous"; then
        mw_fail "The kept $MW_APP_NAME is in $staged and could not be put back as the kept one, so nothing was touched."
        return 1
    fi
    if [ ! -d "$previous" ]; then
        mw_fail "There is no kept previous $MW_APP_NAME in $MW_SWAP_DIR, so nothing was touched."
        return 1
    fi
    rm -rf "$staged" 2>/dev/null || true
    if [ -e "$staged" ] || ! mv "$previous" "$staged"; then
        mw_fail "Could not stage the previous $MW_APP_NAME, so nothing was touched."
        return 1
    fi
    if ! mw_swap_app_locked "$staged"; then
        [ -e "$previous" ] || mv "$staged" "$previous" 2>/dev/null || true
        return 1
    fi
    rm -rf "$staged"
    echo "==> The previous $MW_APP_NAME is back; the one it replaced is kept for the next --rollback."
}

# The default release gate: the project's regression script. A release runs
# the gate before it builds, so a release before a green gate refuses on its own.
# It is a function so the test (scripts/test-release-preflight.sh) can swap a
# stub in its place.
mw_release_gate() {
    bash scripts/regression.sh
}

# Refuses a release while a tracked file is modified or staged (untracked
# files are allowed — the owner keeps some in the main tree: AGENTS.md,
# CLAUDE2.md, Local, Plugin, appcast.xml, .agents/, two spec drafts), and
# refuses a release while the regression gate does not pass. Called once, at
# the top of release.sh, before bash build.sh. $1 is the gate function name;
# it defaults to mw_release_gate.
mw_release_preflight() {
    local gate_fn="${1:-mw_release_gate}"
    if ! git -C "$MW_REPO_ROOT" diff --quiet 2>/dev/null; then
        mw_fail "Tracked files in the repo have local changes. Commit or stash them before a release."
        return 1
    fi
    if ! git -C "$MW_REPO_ROOT" diff --cached --quiet 2>/dev/null; then
        mw_fail "Tracked files in the repo have staged changes. Commit or unstage them before a release."
        return 1
    fi
    if ! "$gate_fn" "$MW_REPO_ROOT" >/dev/null 2>&1; then
        mw_fail "The regression gate did not pass. Run \`bash scripts/regression.sh\` and fix what it says before a release."
        return 1
    fi
}

# The traps build.sh, hot-swap.sh and release.sh set once, near their top: on
# any exit, a self-check still running is asked to stop, a swap that stopped
# half-way is rolled back and the swap lock released, then the given cleanup
# runs; an interrupt or a closed terminal exits through the same path.
mw_trap_exit() {
    MW_EXIT_CLEANUP="$1"
    trap 'mw_on_exit' EXIT
    trap 'exit 130' INT TERM HUP
}

mw_on_exit() {
    trap '' INT TERM HUP
    if [ -n "$MW_SELF_CHECK_PID" ]; then kill -TERM "$MW_SELF_CHECK_PID" 2>/dev/null || true; fi
    mw_rollback || true
    mw_recover_unarmed || true
    if [ "$MW_SWAP_SUCCEEDED" = true ]; then mw_keep_replaced || true; fi
    # A copy under way when the run was cut off is this run's own.
    if [ -n "$MW_LOCK_HELD" ]; then rm -rf "$MW_SWAP_DIR/$MW_APP_NAME.incoming" 2>/dev/null || true; fi
    mw_release_swap_lock || true
    eval "$MW_EXIT_CLEANUP" || true
}

# Where build.sh puts the bundle together. A swap build goes apart from the
# release bundle that release.sh and make-dmg-manual.sh package.
mw_bundle_path() {
    if [ "$2" = true ]; then echo "$1/swap/$MW_APP_NAME.app"; else echo "$1/$MW_APP_NAME.app"; fi
}

# The old build.sh left a copy of the working app in ~/Applications. A link or
# Spotlight can still open it, and it would open the owner's data with an old
# version, so every swap says so until the copy is gone.
mw_warn_old_working_copy() {
    local old="${MW_OLD_COPY_DIR:-$HOME/Applications}/MetaWhisp.app" id
    if [ ! -d "$old" ]; then return 0; fi
    id=$("$MW_PLISTBUDDY" -c "Print :CFBundleIdentifier" "$old/Contents/Info.plist" 2>/dev/null) || id=""
    if [ "$id" = "$MW_PRODUCTION_BUNDLE_ID" ]; then
        echo "==> ⚠️  An old copy of the working app is still at $old. It can open your data with an old version; move it to the Trash." || true
    fi
}
