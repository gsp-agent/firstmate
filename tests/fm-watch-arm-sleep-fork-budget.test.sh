#!/usr/bin/env bash
# Sleep process budget for bin/fm-watch-arm.sh's steady waits
# (.agent-config-ks05d.4). An arm stays alive for its whole cycle, polling its
# owned watcher (or the holder it attached to) every FM_ARM_ATTACH_POLL seconds
# so it notices its caller going away; at the default 0.5s that was about two
# sleep processes a second for every armed home, the live captain's largest
# idle cost after #161. Where the running Bash has the sleep loadable beside it,
# those waits now start no process; elsewhere they run sleep(1) as before.
# Real processes, as in tests/fm-watch-arm.test.sh: a real watcher and a real
# arm, with a logging sleep stand-in on the arm's PATH that records its parent.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

export FM_TEST_HARNESS=unknown

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-arm-sleep-budget)
fm_test_trap_process_cleanup "$TMP_ROOT"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/procevent-claims"

# Detect the interpreter's capability independently of fm_sleep, so this exact
# test also runs against upstream-lean before the arm uses it. Keep the
# installation-relative path and disabled load aligned with _fm_sleep_load.
cat > "$TMP_ROOT/probe-sleep.sh" <<'SH'
lib="${BASH%/*}/../lib/bash/sleep"
[ -f "$lib" ] && enable -n -f "$lib" sleep 2>/dev/null
SH
SLEEP_BUILTIN=0
bash "$TMP_ROOT/probe-sleep.sh" && SLEEP_BUILTIN=1

SLEEPBIN="$TMP_ROOT/sleepbin"
mkdir -p "$SLEEPBIN"
REAL_SLEEP=$(command -v sleep)
# shellcheck disable=SC2016 # The stand-in, not this script, expands $PPID and $@.
printf '#!/bin/sh\nprintf "%%s\\n" "$PPID" >> "%s"\nexec %s "$@"\n' "$TMP_ROOT/sleeps.log" "$REAL_SLEEP" > "$SLEEPBIN/sleep"
chmod +x "$SLEEPBIN/sleep"

# Sleep processes the arm process itself started during a 2s window of its
# steady wait, polling every 0.05s (about 40 waits), into ARM_SLEEPS.
ARM_SLEEPS=0
arm_steady_sleeps() {  # <case-name> <owned|attached> [env...]
  local name=$1 mode=$2 dir state fakebin out armout arm i seed=''
  shift 2
  dir=$(make_case "$name")
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  if [ "$mode" = attached ]; then
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    seed=$!
    fm_test_track_pid "$seed"
    i=0
    while [ "$i" -lt 100 ]; do
      [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$seed" ] \
        && [ -e "$state/.last-watcher-beat" ] && break
      sleep 0.1
      i=$((i + 1))
    done
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$seed" ] \
      || fail "$name: the seed watcher did not take the lock"
  fi
  : > "$TMP_ROOT/sleeps.log"
  env "$@" PATH="$SLEEPBIN:$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.05 \
    FM_ARM_CONFIRM_TIMEOUT=30 "$WATCH_ARM" > "$armout" &
  arm=$!
  fm_test_track_pid "$arm"
  i=0
  while [ "$i" -lt 300 ]; do
    grep -qE '^watcher: (started|attached) pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qE '^watcher: (started|attached) pid=' "$armout" \
    || fail "$name: the arm never reported its watcher: $(cat "$armout")"
  : > "$TMP_ROOT/sleeps.log"
  sleep 2
  is_live_non_zombie "$arm" || fail "$name: the arm left its steady wait: $(cat "$armout")"
  ARM_SLEEPS=$(grep -cx "$arm" "$TMP_ROOT/sleeps.log" || true)
  printf '%s arm: %s sleep processes in 2s of 0.05s waits\n' "$name" "$ARM_SLEEPS"
  fm_test_stop_processes
}

for mode in owned attached; do
  arm_steady_sleeps "$mode-builtin" "$mode" FM_TEST_SEAM=0
  if [ "$SLEEP_BUILTIN" = 1 ]; then
    # Base f9fab1d4: about 30 to 40 here, one per wait.
    [ "$ARM_SLEEPS" -eq 0 ] || fail "$mode arm started $ARM_SLEEPS sleep processes while waiting; expected none"
    pass "an $mode arm's steady waits start no sleep process"
  else
    echo "skip: no Bash sleep loadable beside $BASH, so the $mode arm's waits still run sleep(1)"
  fi
  # The fallback on any Bash, forced even where the builtin exists.
  arm_steady_sleeps "$mode-fallback" "$mode" FM_TEST_SEAM=1 FM_TEST_NO_SLEEP_BUILTIN=1
  [ "$ARM_SLEEPS" -ge 5 ] || fail "$mode arm fallback started only $ARM_SLEEPS sleep processes; the stand-in saw no waits"
  pass "an $mode arm without the builtin still waits with sleep(1)"
done
