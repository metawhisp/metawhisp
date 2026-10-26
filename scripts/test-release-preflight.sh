#!/usr/bin/env bash
# scripts/test-release-preflight.sh
#
# The preflight that release.sh runs before build.sh: it refuses a release
# while a tracked file is modified or staged, or while the regression gate does
# not pass. We test the function in temp git repos with a stub gate so we don't
# run the full suite.
#
#   bash scripts/test-release-preflight.sh
#
# Untracked files are allowed — the owner keeps some in the main tree
# (AGENTS.md, CLAUDE2.md, Local, Plugin, appcast.xml, .agents/, two spec
# drafts), and the preflight must not refuse on them.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/app-install.sh
source scripts/lib/app-install.sh

WORK=$(mktemp -d -t mw-preflight-check)
trap 'rm -rf "$WORK"' EXIT
CASES=0
BROKEN=0

# expect NAME PASS|FAIL DIR GATE — call mw_release_preflight against DIR with
# the stub GATE (a function name). MW_REPO_ROOT is set to DIR for the call.
expect() {
    local name="$1" want="$2" dir="$3" gate="$4"
    local out got
    CASES=$((CASES + 1))
    MW_REPO_ROOT="$dir" out=$(mw_release_preflight "$gate" 2>&1) && got=PASS || got=FAIL
    if [ "$got" != "$want" ]; then
        echo "  ✗ $name: preflight said $got, it must say $want"
        echo "$out" | sed 's/^/      /'
        BROKEN=1
        return
    fi
    echo "  ✓ $name"
}

# init NAME — a temp git repo at $WORK/$1 with HEAD set, ready to test in.
init() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false
    : > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m init
}

# Stub gates: true passes, false fails.
gate_true() { return 0; }
gate_false() { return 1; }

echo "Preflight refuses a dirty tree (modified or staged tracked files)"
init clean
expect "a clean tree and a passing gate is allowed" PASS "$WORK/clean" gate_true

init modified
echo "modified" > "$WORK/modified/file.txt"
expect "a modified tracked file is refused" FAIL "$WORK/modified" gate_true

init staged
echo "staged" > "$WORK/staged/file.txt"
git -C "$WORK/staged" add file.txt
expect "a staged change is refused" FAIL "$WORK/staged" gate_true

init untracked
echo "untracked" > "$WORK/untracked/untracked.txt"
expect "only untracked files are allowed" PASS "$WORK/untracked" gate_true

init staged_untracked
echo "untracked" > "$WORK/staged_untracked/untracked.txt"
git -C "$WORK/staged_untracked" add untracked.txt
expect "a newly-staged file is refused" FAIL "$WORK/staged_untracked" gate_true

echo "Preflight refuses a failing gate"
init failing_gate
expect "a clean tree but a failing gate is refused" FAIL "$WORK/failing_gate" gate_false

echo
if [ "$BROKEN" = "0" ]; then
    echo "preflight checks: $CASES cases, all as they must be"
else
    echo "preflight checks: FAILED — preflight decided wrongly"
fi
exit $BROKEN