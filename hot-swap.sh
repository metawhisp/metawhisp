#!/bin/bash
set -euo pipefail

# Builds the current code and installs it over the working app in /Applications
# (owner, 2026-09-26: no separate test copy): bash build.sh --swap.
#
# ITER-076 0.1 — on 2026-09-25 a failed signing step left the working app dead
# and stripped of its permissions. A swap now tests the signing first, refuses
# while the app records or transcribes, keeps the installed app until the new
# one has started and written its activity lease, and puts it back on any
# failure (scripts/lib/app-install.sh).
#
# Usage:
#   bash hot-swap.sh [--debug] [--confirm-idle]
#   bash hot-swap.sh --rollback [--confirm-idle]   # put back the build the last swap replaced

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--rollback" ]; then
    for arg in "${@:2}"; do
        case "$arg" in
            --confirm-idle) export MW_CONFIRM_IDLE=1 ;;
            *) echo "Unknown option: $arg (see the usage at the top of hot-swap.sh)" >&2; exit 2 ;;
        esac
    done
    source "$SCRIPT_DIR/scripts/lib/app-install.sh"
    mw_trap_exit ':'
    mw_restore_previous || exit 1
    exit 0
fi
exec bash "$SCRIPT_DIR/build.sh" --swap "$@"
