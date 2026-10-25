#!/usr/bin/env bash
# Inactive process budget for the real watcher loop.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

# The first poll creates the existing scan marker. Polls 2-5 are not due,
# but exercise the complete real watcher loop rather than a mocked scan.
WATCH_POLLS=0
home=$(make_watch_home inactive-not-due 4 0)
watch_polls "$home" "$TMP_ROOT/inactive.forks"
printf 'inactive budget: %s processes over four not-due polls = %s per poll\n' "$WATCH_POLLS" "$((WATCH_POLLS / 4))"
[ "$WATCH_POLLS" -le 256 ] || fail "not-due watcher started $WATCH_POLLS processes; budget is 64 per poll (256 total)"
pass "the watcher does not start an inactive scan before its cadence is due"
