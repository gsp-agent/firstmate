#!/usr/bin/env bash
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5G3MH318E8QVNSE345AGS9W/focused-reconcile-definitions.sh
make_world exact-note-after-load
write_herdr_child "$MAIN" child 'paused: session context limit reached'
start=$SECONDS
FM_INACTIVE_RECONCILE_BUDGET_SECS=10 run_reconcile "$MAIN" --startup
printf 'standalone_budget=10 scan_seconds=%s pane_closes=%s\n' "$((SECONDS-start))" "$(herdr_close_count)"
[ "$(herdr_close_count)" = 1 ] || fail 'exact note did not close after startup load ended'
read_child_state "$MAIN" child
