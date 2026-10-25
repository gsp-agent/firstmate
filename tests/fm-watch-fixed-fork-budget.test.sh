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
[ "$WATCH_POLLS" -le 12 ] || fail "fixed watcher reads started $WATCH_POLLS processes; budget is three per poll (12 total)"
pass "fixed poll work starts only its snapshots and ordinary sleep"
