#!/usr/bin/env bash
# scripts/test-regression-gate.sh
#
# The gate's own checks: scripts/regression.sh reads saved `swift test` runs
# (scripts/fixtures/regression/) and each case says what the gate must decide.
# `bash scripts/regression.sh` runs this first; it also runs on its own:
#
#   bash scripts/test-regression-gate.sh
#
# The saved runs keep only the suites these cases use, so the cases use that
# list of critical suites; every other list is the gate's own.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FIXTURES="scripts/fixtures/regression"
WORK=$(mktemp -d -t mw-gate-check)
trap 'rm -rf "$WORK"' EXIT
CASES=0
BROKEN=0

# The gate's decision on LOG: MODE is check or update; ALLOW sets
# MW_ALLOW_NO_CHROME. The floor and the inventory live in STATE.
verdict() {
    local log="$1" mode="$2" allow="$3" state="$4"
    (
        # shellcheck source=regression.sh
        source scripts/regression.sh
        CRITICAL_SUITES=(AgentServiceTests ChromeLinkTests ChromeBridgeLiveTests ChromeConnectionLiveTests
                         SchemaMigrationTests LayoutCorpusBenchmarkTests)
        FLOOR_FILE="$state/floor"
        INVENTORY_FILE="$state/inventory"
        MW_ALLOW_NO_CHROME="$allow"
        mw_verdict "$log" 0 "$mode"
    )
}

# expect NAME PASS|FAIL LOG MODE ALLOW STATE [TEXT...] — the verdict, and for
# each TEXT a line of the gate's output that says it.
expect() {
    local name="$1" want="$2" log="$3" mode="$4" allow="$5" state="$6"
    local out got text
    shift 6
    CASES=$((CASES + 1))
    out=$(verdict "$log" "$mode" "$allow" "$state" 2>&1) && got=PASS || got=FAIL
    if [ "$got" != "$want" ]; then
        echo "  ✗ $name: the gate said $got, it must say $want"
        echo "$out" | sed 's/^/      /'
        BROKEN=1
        return
    fi
    for text in "$@"; do
        if ! grep -qF -- "$text" <<< "$out"; then
            echo "  ✗ $name: $got, but no line says: $text"
            echo "$out" | sed 's/^/      /'
            BROKEN=1
            return
        fi
    done
    echo "  ✓ $name"
}

# fresh NAME LOG [ALLOW] — a floor and an inventory recorded from LOG.
fresh() {
    mkdir -p "$WORK/$1"
    verdict "$2" update "${3:-}" "$WORK/$1" > /dev/null 2>&1
    echo "$WORK/$1"
}

# recount DT DS — the run on stdin, its summary with DT more tests and DS more skipped.
recount() {
    perl -pe 's/Executed (\d+) tests, with (\d+) tests? skipped/"Executed ".($1+'"$1"')." tests, with ".($2+'"$2"')." tests skipped"/e'
}

# without LOG SUITE TEST — the run with that test deleted.
without() {
    grep -vF -- "[MetaWhispTests.$2 $3]" "$1" | recount -1 0
}

# replaced LOG SUITE TEST NEW — that test deleted and a new one in its suite:
# the count stays as it was.
replaced() {
    grep -vF -- "[MetaWhispTests.$2 $3]" "$1"
    echo "Test Case '-[MetaWhispTests.$2 $4]' passed (0.010 seconds)."
}

# skipping LOG SUITE TEST REASON — that test, which passed, now skips.
skipping() {
    sed "s/^Test Case '-\[MetaWhispTests\.$2 $3\]' passed (.*/Tests\/$2.swift:1: -[MetaWhispTests.$2 $3] : Test skipped - $4\\
Test Case '-[MetaWhispTests.$2 $3]' skipped (0.000 seconds)./" "$1" | recount 0 1
}

# newly_skipping LOG SUITE TEST REASON — a test the saved run does not show
# (it passed, outside the cases' suites) now skips.
newly_skipping() {
    recount 0 1 < "$1"
    echo "Tests/$2.swift:1: -[MetaWhispTests.$2 $3] : Test skipped - $4"
    echo "Test Case '-[MetaWhispTests.$2 $3]' skipped (0.000 seconds)."
}

LOCKED="$FIXTURES/locked.log"
UNLOCKED="$FIXTURES/unlocked.log"
NO_CHROME="$FIXTURES/no-chrome.log"

echo "No test removed, whatever the screen (Codex on I-04, P2-1)"
S=$(fresh locked "$LOCKED")
expect "a locked run passes the floor and inventory it recorded" PASS "$LOCKED" check "" "$S"
expect "an unlocked run passes them too" PASS "$UNLOCKED" check "" "$S"
S2=$(fresh unlocked "$UNLOCKED")
expect "a locked run passes the floor and inventory an unlocked run recorded" PASS "$LOCKED" check "" "$S2"
CASES=$((CASES + 1))
if cmp -s "$S/floor" "$S2/floor" && cmp -s "$S/inventory" "$S2/inventory"; then
    echo "  ✓ a locked and an unlocked run record the same floor and inventory"
else
    echo "  ✗ a locked and an unlocked run record different floors or inventories"
    BROKEN=1
fi
without "$LOCKED" AgentServiceTests testAnEmptyGoalIsRefused > "$WORK/locked-minus-one.log"
without "$UNLOCKED" AgentServiceTests testAnEmptyGoalIsRefused > "$WORK/unlocked-minus-one.log"
expect "a locked run with one critical test deleted fails" FAIL "$WORK/locked-minus-one.log" check "" "$S" \
    "❌ AgentServiceTests.testAnEmptyGoalIsRefused no longer exists"
expect "an unlocked run with one critical test deleted fails" FAIL "$WORK/unlocked-minus-one.log" check "" "$S" \
    "❌ AgentServiceTests.testAnEmptyGoalIsRefused no longer exists"
replaced "$UNLOCKED" AgentServiceTests testAnEmptyGoalIsRefused testSomethingNew > "$WORK/unlocked-replaced.log"
expect "a critical test deleted while another is added fails, though the count holds" FAIL \
    "$WORK/unlocked-replaced.log" check "" "$S" "❌ AgentServiceTests.testAnEmptyGoalIsRefused no longer exists" \
    "✅ count 2463 ≥ floor 2463"
newly_skipping "$LOCKED" LevenshteinTests test_identicalStringsDistanceZero "not now" > "$WORK/one-more-skip.log"
expect "a test outside the critical suites that skips for no named reason is not counted" FAIL \
    "$WORK/one-more-skip.log" check "" "$S" "❌ test count dropped"

echo "Only the listed Chrome tests may skip for want of Chrome, and only on purpose (Codex on I-04, P2-2)"
expect "the Chrome tests skipping fails the gate" FAIL "$NO_CHROME" check "" "$S" \
    "❌ no Google Chrome: 36 live Chrome tests did not run"
expect "with MW_ALLOW_NO_CHROME=1 they may, and the floor holds" PASS "$NO_CHROME" check 1 "$S" \
    "✅ count 2463 ≥ floor 2463 (MW_ALLOW_NO_CHROME=1 counts 36 live Chrome tests that did not run)" \
    "MW_ALLOW_NO_CHROME=1: 36 live Chrome tests did not run"
skipping "$LOCKED" AgentServiceTests testAnEmptyGoalIsRefused "needs Google Chrome" > "$WORK/fake-chrome.log"
expect "another critical test skipping for want of Chrome fails" FAIL "$WORK/fake-chrome.log" check "" "$S" \
    "❌ AgentServiceTests.testAnEmptyGoalIsRefused was SKIPPED"
expect "and fails with MW_ALLOW_NO_CHROME=1 too" FAIL "$WORK/fake-chrome.log" check 1 "$S" \
    "❌ AgentServiceTests.testAnEmptyGoalIsRefused was SKIPPED"
sed "s/testConnectsOnceAndKeepsTheConnection\] : Test skipped - needs Google Chrome/testConnectsOnceAndKeepsTheConnection] : Test skipped - Chrome did not open its DevTools port in time/" \
    "$NO_CHROME" > "$WORK/chrome-timeout.log"
expect "a Chrome test skipping for another reason fails with MW_ALLOW_NO_CHROME=1" FAIL \
    "$WORK/chrome-timeout.log" check 1 "$S" "❌ ChromeLinkTests.testConnectsOnceAndKeepsTheConnection was SKIPPED"

echo "Every critical test runs"
{
    skipping "$LOCKED" AgentServiceTests testAnEmptyGoalIsRefused "scratch" | recount 1 0
    echo "Test Case '-[MetaWhispTests.ChromeLinkTests testSomethingNew]' passed (0.010 seconds)."
} > "$WORK/critical-skip.log"
expect "a critical test that skips fails the gate, though a new test keeps the count" FAIL \
    "$WORK/critical-skip.log" check "" "$S" "❌ AgentServiceTests.testAnEmptyGoalIsRefused was SKIPPED (scratch)" \
    "✅ count 2463 ≥ floor 2463"

echo
if [ "$BROKEN" = "0" ]; then
    echo "gate checks: $CASES cases, all as they must be"
else
    echo "gate checks: FAILED — the gate decides a saved run wrongly"
fi
exit $BROKEN
