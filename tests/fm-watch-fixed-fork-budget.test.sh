#!/usr/bin/env bash
# Fixed process budget for the real watcher loop.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

# Four settled status logs, no windows, and no due cadence. Count all fixed
# loop processes after warmup, not just a selected helper or command.
WATCH_POLLS=0
home=$(make_watch_home fixed-reads 4 0)
watch_polls "$home" "$TMP_ROOT/fixed.forks"
printf 'fixed-read budget: %s processes over four polls = %s per poll\n' "$WATCH_POLLS" "$((WATCH_POLLS / 4))"
[ "$WATCH_POLLS" -le 416 ] || fail "fixed watcher reads started $WATCH_POLLS processes; budget is 104 per poll (416 total)"
pass "fixed poll reads stay within budget with the unchanged inactive scanner"
