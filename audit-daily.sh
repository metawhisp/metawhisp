#!/bin/bash
# Daily MetaWhisp health audit. Run at session start (or anytime) to surface
# regressions before the user has to notice them.
#
# Sources of truth:
#   • ~/Library/Application Support/MetaWhisp.store     — SwiftData DB
#   • ~/Library/Logs/MetaWhisp.log                       — NSLog file
#   • ~/Library/Logs/DiagnosticReports/MetaWhisp*       — crash reports
#   • ~/Library/Application Support/MetaWhisp/Recovery/  — unfinished wavs
#
# Usage: bash audit-daily.sh                  # today (local midnight → now)
#        bash audit-daily.sh 2026-05-10       # specific date

set -uo pipefail

DATE_ARG="${1:-$(date +%Y-%m-%d)}"
DAY_START_UNIX=$(date -j -f "%Y-%m-%d %T" "$DATE_ARG 00:00:00" "+%s")
DAY_END_UNIX=$((DAY_START_UNIX + 86400))
APPLE_EPOCH_DIFF=978307200
DAY_START_APPLE=$((DAY_START_UNIX - APPLE_EPOCH_DIFF))
DAY_END_APPLE=$((DAY_END_UNIX - APPLE_EPOCH_DIFF))

DB="$HOME/Library/Application Support/MetaWhisp.store"
LOG="$HOME/Library/Logs/MetaWhisp.log"
RECOVERY="$HOME/Library/Application Support/MetaWhisp/Recovery"
CRASHES="$HOME/Library/Logs/DiagnosticReports"

echo "════════════════════════════════════════════════════════════════"
echo "  MetaWhisp daily audit — $DATE_ARG"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ── 1. DB activity counts ──────────────────────────────────────────────
echo "▌ DB ACTIVITY"
if [ ! -f "$DB" ]; then
    echo "  ❌ store missing at $DB"
else
    for tbl in ZADVICEITEM ZSCREENOBSERVATION ZCONVERSATION ZHISTORYITEM ZTASKITEM ZUSERMEMORY ZPATTERNDIGEST ZDAILYSUMMARY; do
        n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $tbl WHERE ZCREATEDAT >= $DAY_START_APPLE AND ZCREATEDAT < $DAY_END_APPLE;" 2>/dev/null)
        printf "  %-22s %s\n" "$tbl" "${n:-?}"
    done
    ssc=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ZSCREENCONTEXT WHERE ZTIMESTAMP >= $DAY_START_APPLE AND ZTIMESTAMP < $DAY_END_APPLE;" 2>/dev/null)
    printf "  %-22s %s\n" "ZSCREENCONTEXT" "${ssc:-?}"
    insights=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ZUSERMEMORY WHERE ZCATEGORY='system' AND ZTAGSCSV LIKE '%insight%' AND ZCREATEDAT >= $DAY_START_APPLE AND ZCREATEDAT < $DAY_END_APPLE;" 2>/dev/null)
    printf "  %-22s %s (ITER-027 pipeline)\n" "└ system+insight tag" "${insights:-?}"
fi
echo ""

# ── 2. Log errors / warnings ───────────────────────────────────────────
echo "▌ LOG ERRORS / WARNINGS (last 5000 lines)"
if [ ! -f "$LOG" ]; then
    echo "  log missing at $LOG"
else
    err_count=$(tail -n 5000 "$LOG" 2>/dev/null | grep -ciE "❌|⚠️|error|fail|crash|fault" | head -1)
    echo "  total error-like lines: $err_count"
    # Distinct top markers
    tail -n 5000 "$LOG" 2>/dev/null \
        | grep -oE "\[[A-Za-z]+\] (❌|⚠️) [^:]*" \
        | sort | uniq -c | sort -rn | head -8 \
        | sed 's/^/  /'
fi
echo ""

# ── 3. Insight pipeline health ─────────────────────────────────────────
echo "▌ INSIGHT PIPELINE (last 5000 lines of log)"
if [ -f "$LOG" ]; then
    surfaced=$(tail -n 5000 "$LOG" 2>/dev/null | grep -c "✅ surfacing")
    parse_err=$(tail -n 5000 "$LOG" 2>/dev/null | grep -c "\[Insight\] parse error")
    no_advice=$(tail -n 5000 "$LOG" 2>/dev/null | grep -c "\[Insight\] no advice:")
    dropped=$(tail -n 5000 "$LOG" 2>/dev/null | grep -c "\[Insight\] dropped")
    printf "  surfacing       %s\n" "$surfaced"
    printf "  no_advice       %s\n" "$no_advice"
    printf "  dropped (dedup) %s\n" "$dropped"
    printf "  parse_error     %s   %s\n" "$parse_err" "$([ "$parse_err" -gt 5 ] && echo "🚨 markdown-wrapper regression?")"
fi
echo ""

# ── 4. Recovery orphans ────────────────────────────────────────────────
echo "▌ RECOVERY DIR"
if [ -d "$RECOVERY" ]; then
    wav_count=$(find "$RECOVERY" -maxdepth 1 -name "*.wav" -type f 2>/dev/null | wc -l | tr -d ' ')
    size_kb=$(du -sk "$RECOVERY" 2>/dev/null | awk '{print $1}')
    oldest=$(find "$RECOVERY" -maxdepth 1 -name "*.wav" -type f -exec stat -f "%Sm %N" -t "%Y-%m-%d" {} \; 2>/dev/null | sort | head -1)
    printf "  wav count: %s    dir size: %s KB\n" "$wav_count" "$size_kb"
    if [ "$wav_count" -gt 0 ]; then
        echo "  oldest: $oldest"
    fi
else
    echo "  (no Recovery dir — clean state)"
fi
echo ""

# ── 5. Crashes ─────────────────────────────────────────────────────────
echo "▌ CRASH REPORTS (last 7 days)"
crashes=$(find "$CRASHES" -name "MetaWhisp*" -mtime -7 -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  count: $crashes"
if [ "$crashes" -gt 0 ]; then
    find "$CRASHES" -name "MetaWhisp*" -mtime -7 -type f 2>/dev/null | sed 's/^/  /'
fi
echo ""

# ── 6. Running process ─────────────────────────────────────────────────
echo "▌ RUNNING PROCESS"
if pgrep -x MetaWhisp >/dev/null 2>&1; then
    pid=$(pgrep -x MetaWhisp | head -1)
    rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ')
    rss_mb=$((rss_kb / 1024))
    elapsed=$(ps -o etime= -p "$pid" | tr -d ' ')
    echo "  ✅ MetaWhisp running PID=$pid RSS=${rss_mb}MB elapsed=$elapsed"
else
    echo "  (not running)"
fi
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "  audit complete"
echo "════════════════════════════════════════════════════════════════"
