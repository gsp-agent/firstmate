#!/usr/bin/env bash
# Window process budget for the real watcher loop.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

# Fixed poll overhead cancels: both homes have four settled status logs,
# identical cadence and no due checks; only the recorded windows differ.
# The ten-process budget covers five capture processes and five fresh-status
# read processes. A failed capture exercises all per-window preparation while
# keeping the fixture independent of any installed backend or agent.
WATCH_POLLS=0
empty_home=$(make_watch_home no-windows 4 0)
watch_polls "$empty_home" "$TMP_ROOT/no-windows.forks"
fixed=$WATCH_POLLS
window_home=$(make_watch_home four-windows 4 4)
watch_polls "$window_home" "$TMP_ROOT/four-windows.forks"
windows=$WATCH_POLLS
added=$((windows - fixed))
printf 'window budget: %s fixed processes; %s with four windows, over four polls; %s added processes = %s per window per poll\n' \
  "$fixed" "$windows" "$added" "$((added / 16))"
[ "$added" -ge 16 ] || fail "window counter did not observe capture processes"
[ "$added" -le 160 ] || fail "window reads added $added processes; budget is 10 per window per poll (160 total)"
pass "window preparation and fresh status reads use at most ten processes per failed capture"
