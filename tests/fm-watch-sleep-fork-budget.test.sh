#!/usr/bin/env bash
# Sleep process budget for the real watcher loop.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

# Detect the interpreter's capability independently of fm_sleep, so this exact
# test also runs against upstream-lean before that helper exists.
cat > "$TMP_ROOT/probe-sleep.sh" <<'SH'
lib="${BASH%/*}/../lib/bash/sleep"
[ -f "$lib" ] && enable -f "$lib" sleep 2>/dev/null
SH
WAIT_FORKS=1
bash "$TMP_ROOT/probe-sleep.sh" && WAIT_FORKS=0
WATCH_POLLS=0
home=$(make_watch_home sleep-waits 4 0)
watch_polls "$home" "$TMP_ROOT/sleep.forks"
sleeps=$(count_passes "$TMP_ROOT/sleep.forks" 1 4 sleep) || fail "incomplete sleep count"
printf 'sleep budget: %s total processes and %s sleep processes over four polls; %s sleep processes per poll\n' "$WATCH_POLLS" "$sleeps" "$((sleeps / 4))"
[ "$sleeps" -eq $((4 * WAIT_FORKS)) ] || fail "poll waits started $sleeps sleep processes; expected $((4 * WAIT_FORKS))"
# Explicitly exercise the fallback even on a machine with the loadable builtin.
export FM_TEST_SEAM=1 FM_TEST_NO_SLEEP_BUILTIN=1
home=$(make_watch_home fallback-waits 4 0)
watch_polls "$home" "$TMP_ROOT/fallback.forks"
sleeps=$(count_passes "$TMP_ROOT/fallback.forks" 1 4 sleep) || fail "incomplete fallback count"
[ "$sleeps" -eq 4 ] || fail "fallback waits started $sleeps sleep processes; expected four"
pass "poll waits use no child where the builtin exists, and one child per wait on fallback"
