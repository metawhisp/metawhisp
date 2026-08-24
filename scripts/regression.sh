#!/usr/bin/env bash
# scripts/regression.sh
#
# The check that runs after EVERY iteration, before anything is called done.
#
# It exists because a green `swift test` is not by itself evidence that the
# working product still works: a suite can be deleted, renamed, skipped, or
# quietly emptied, and the run stays green while a shipped flow is broken.
# So this asserts three things a bare test run does not:
#
#   1. the total test count has not DROPPED (tests removed to force green),
#   2. every named critical suite still EXISTS and still RUNS tests,
#   3. the layout corpus has not regressed.
#
# Usage:
#   bash scripts/regression.sh              # run the gates
#   bash scripts/regression.sh --update     # accept the current count as the floor
#
# Exit 0 = safe to continue. Any non-zero = do not report the iteration done.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FLOOR_FILE="scripts/.regression-baseline"
LOG=$(mktemp -t mw-regression)
FAILED=0

fail() { echo "  ❌ $*"; FAILED=1; }
ok()   { echo "  ✅ $*"; }

# The flows a user would notice within a minute of them breaking. Adding a
# feature here is cheap; the point is that renaming or deleting one of these
# suites is loud instead of silent.
CRITICAL_SUITES=(
    # dictation: record → transcribe → recover
    TranscriptionCoordinatorRecoveryTests
    TranscriptionConfidenceGateTests
    CloudTransientErrorTests
    HallucinationStripTests
    # the text actually landing in the user's app
    TextInsertionClipboardTests
    FocusedTextGatewayTests
    # layout fix (flagship)
    LayoutCorpusBenchmarkTests
    LayoutKeystrokeReplacementTests
    LayoutClipboardOwnershipTests
    LayoutTypingRaceTests
    # meetings
    MeetingRecorderSilenceTests
    MeetingAudioSilenceCutterTests
    DualStreamMergerTests
    MeetingTranscriptSanitizerTests
    # microphone health
    DeadMicDetectorTests
    # screen capture privacy + freshness
    ScreenContextPolicyTests
    CaptureHighWaterMarkTests
    ScreenContextFanoutTests
    ScreenExtractorVisitIndexTests
    ScreenRetentionTests
    # user data must survive an update
    SchemaMigrationTests
    StoreBackupTests
    # agent actions cannot fire without confirmation
    MutationServiceTests
    ChatToolExecutorSB2Tests
)

echo "▸ 1/4  Build"
if swift build > "$LOG" 2>&1; then
    ok "swift build"
else
    fail "swift build FAILED"
    grep -E ": error:" "$LOG" | head -10
    echo "Stopping: nothing below is meaningful against a broken build."
    exit 1
fi

echo "▸ 2/4  Full suite"
swift test > "$LOG" 2>&1
TEST_EXIT=$?
SUMMARY=$(grep -aE "Executed [0-9]+ tests, with" "$LOG" | tail -1)
# Two shapes: "Executed N tests, with F failures" and
# "Executed N tests, with S tests skipped and F failures".
TOTAL=$(echo "$SUMMARY" | grep -oE "Executed [0-9]+ tests" | head -1 | awk '{print $2}')
FAILS=$(echo "$SUMMARY" | grep -oE "[0-9]+ failures" | head -1 | awk '{print $1}')
[ -z "${TOTAL:-}" ] && TOTAL=0
[ -z "${FAILS:-}" ] && FAILS=0

if [ "$TEST_EXIT" -eq 0 ] && [ "$FAILS" = "0" ]; then
    ok "$TOTAL tests, 0 failures"
else
    fail "$SUMMARY"
    grep -aE "error: -\[" "$LOG" | head -15
fi

if [ "${1:-}" = "--update" ]; then
    echo "$TOTAL" > "$FLOOR_FILE"
    echo "  ↻ baseline set to $TOTAL"
elif [ -f "$FLOOR_FILE" ]; then
    FLOOR=$(cat "$FLOOR_FILE")
    if [ "$TOTAL" -lt "$FLOOR" ]; then
        fail "test count dropped: $TOTAL < $FLOOR — tests were removed or stopped running"
        echo "     If the removal is deliberate: bash scripts/regression.sh --update"
    else
        ok "count $TOTAL ≥ floor $FLOOR"
    fi
else
    echo "$TOTAL" > "$FLOOR_FILE"
    echo "  ↻ baseline created at $TOTAL"
fi

echo "▸ 3/4  Critical suites present and running"
MISSING=0
for suite in "${CRITICAL_SUITES[@]}"; do
    if ! grep -rq "class ${suite}\b" Tests/; then
        fail "$suite — SUITE NO LONGER EXISTS"
        MISSING=1
        continue
    fi
    n=$(grep -ac "Test Case '-\[MetaWhispTests.${suite} " "$LOG")
    if [ "$n" = "0" ]; then
        fail "$suite exists but ran 0 tests"
        MISSING=1
    fi
done
[ "$MISSING" = "0" ] && ok "${#CRITICAL_SUITES[@]} critical suites ran"

echo "▸ 4/4  Layout corpus"
CORPUS=$(grep -aE "recall|corpus" "$LOG" | grep -aiE "[0-9]+\.[0-9]+" | tail -1)
if grep -aq "Test Case '-\[MetaWhispTests.LayoutCorpusBenchmarkTests" "$LOG"; then
    if grep -aq "LayoutCorpusBenchmarkTests.*failed" "$LOG"; then
        fail "layout corpus REGRESSED below its floor"
    else
        ok "corpus within floor ${CORPUS:+($CORPUS)}"
    fi
else
    fail "layout corpus benchmark did not run"
fi

echo
if [ "$FAILED" = "0" ]; then
    echo "PASS — safe to continue."
else
    echo "FAIL — do not report the iteration done."
fi
rm -f "$LOG"
exit $FAILED
