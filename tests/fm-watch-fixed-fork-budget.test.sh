#!/usr/bin/env bash
# Fixed process budget for the real watcher loop.
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

# Pin the successful-exit race without timing guesses: the first marker read
# sees five; the liveness check then releases and waits for our stand-in child,
# which appends marker six and exits. A completed child is no longer a live
# job, but the final marker still makes the wait successful. Also keep an early
# exit with only five markers failing. Overrides stay inside each subshell.
test_marker_read_racing_child_exit() (
  complete=$1 expected=$2
  log="$TMP_ROOT/marker-exit-$complete.log"
  gate="$TMP_ROOT/marker-exit-$complete.gate"
  mkfifo "$gate" || fail "marker exit: cannot make child gate"
  printf 'm fixture\nm fixture\nm fixture\nm fixture\nm fixture\n' > "$log"
  trap budget_stop_watcher EXIT
  (
    IFS= read -r _ < "$gate"
    if [ "$complete" = 1 ]; then printf 'm %s\n' "$BASHPID" >> "$log"; fi
  ) &
  BUDGET_WATCHER_PID=$!
  budget_watcher_live() {
    local child_rc=0
    printf '\n' > "$gate"
    wait "$BUDGET_WATCHER_PID" || child_rc=$?
    BUDGET_WATCHER_PID=
    [ "$child_rc" -eq 0 ] || fail "marker exit: stand-in child failed"
    return 1
  }
  rc=0
  wait_markers "$log" 6 1 || rc=$?
  markers=$(markers_in "$log")
  printf 'marker-exit interleaving: markers=%s, wait=%s, expected=%s\n' "$markers" "$rc" "$expected"
  [ "$markers" -eq $((5 + complete)) ] || fail "marker exit: the child did not publish the expected count"
  [ "$rc" -eq "$expected" ] || fail "marker exit: wait rejected a completed run or accepted an incomplete run"
)
test_marker_read_racing_child_exit 1 0 || exit 1
test_marker_read_racing_child_exit 0 1 || exit 1
pass "marker wait accepts completion during the liveness check and rejects an incomplete exit"

# Four settled status logs, no windows, and no due cadence. Count all fixed
# loop processes after warmup, not just a selected helper or command.
WATCH_POLLS=0
home=$(make_watch_home fixed-reads 4 0)
watch_polls "$home" "$TMP_ROOT/fixed.forks"
printf 'fixed-read budget: %s processes over four polls = %s per poll\n' "$WATCH_POLLS" "$((WATCH_POLLS / 4))"
[ "$WATCH_POLLS" -le 12 ] || fail "fixed watcher reads started $WATCH_POLLS processes; budget is three per poll (12 total)"
pass "fixed poll work starts only its snapshots and ordinary sleep"
