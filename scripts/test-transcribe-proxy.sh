#!/usr/bin/env bash
# scripts/test-transcribe-proxy.sh
#
# Integration test for /api/pro/transcribe on the Cloudflare proxy.
# Verifies that at least ONE transcription provider returns text for a real WAV.
#
# Usage:
#   MW_LICENSE_KEY=<key> ./scripts/test-transcribe-proxy.sh [path/to/audio.wav]
#
# Default WAV: newest file in ~/Library/Application Support/MetaWhisp/Recovery/
#
# Exit codes:
#   0 — provider returned non-empty text
#   1 — bad license / HTTP 401
#   2 — all providers failed (HTTP 502) — error detail printed
#   3 — other HTTP error
#   4 — missing license env var

set -eu

LICENSE="${MW_LICENSE_KEY:-}"
if [ -z "$LICENSE" ]; then
  echo "FAIL: set MW_LICENSE_KEY env var (Pro license token from app)"
  exit 4
fi

WAV="${1:-}"
if [ -z "$WAV" ]; then
  RECOVERY="$HOME/Library/Application Support/MetaWhisp/Recovery"
  WAV="$(ls -t "$RECOVERY"/*.wav 2>/dev/null | head -1 || true)"
fi
if [ -z "$WAV" ] || [ ! -f "$WAV" ]; then
  echo "FAIL: no WAV file (arg or recovery dir empty)"
  exit 3
fi

ENDPOINT="${MW_PROXY:-https://api.metawhisp.com}/api/pro/transcribe"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

HTTP=$(curl -sS -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $LICENSE" \
  -H "Content-Type: audio/wav" \
  --data-binary "@$WAV" \
  --max-time 120 \
  -o "$TMP" -w "%{http_code}")

case "$HTTP" in
  200)
    TEXT=$(python3 -c "import sys, json; d=json.load(open('$TMP')); print((d.get('text') or '').strip())")
    if [ -z "$TEXT" ]; then
      echo "FAIL: 200 but empty text"
      cat "$TMP"
      exit 2
    fi
    echo "PASS: $HTTP"
    echo "WAV: $WAV ($(du -h "$WAV" | cut -f1))"
    echo "Text (first 200 chars): ${TEXT:0:200}"
    exit 0
    ;;
  401)
    echo "FAIL: 401 — bad license"
    exit 1
    ;;
  502)
    echo "FAIL: 502 — all providers failed"
    python3 -m json.tool < "$TMP" || cat "$TMP"
    exit 2
    ;;
  *)
    echo "FAIL: HTTP $HTTP"
    cat "$TMP"
    exit 3
    ;;
esac
