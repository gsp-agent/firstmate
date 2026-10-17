#!/usr/bin/env bash
# dead-lock.sh <tree> <log> - dead publication lock recovery on the lab home.
#
# 1. Let a refresh die at its deadline the way the 79 failed attempts did:
#    fm_run_timed's TERM then KILL to the worker group (bound forced short only
#    for this step, FM_HOME_SUMMARY_TIMEOUT=3). If the worker's cleanup did not
#    run, the refresh lock is left pointing at a dead pid.
# 2. If the deadline kill happened to release the lock, plant the same shape a
#    KILLed worker leaves (lock -> owner dir whose pid is dead) by SIGKILLing a
#    refresh worker mid-run directly.
# 3. Run the ordinary direct refresh (default 60 s bound, no override, no
#    --best-effort) and record whether it reclaims the dead lock, publishes a
#    new ledger with all endpoints, and leaves no lock behind.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
E=/Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK
tree=$1 log=$2
lock=$LAB/state/.home-summary-refresh.lock
ledger=$LAB/state/home-summary.json
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
say() { printf '%s\n' "$*" | tee -a "$log"; }
lock_report() {
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock"); pid=$(cat "$owner/pid" 2>/dev/null || echo none)
    if [ "$pid" != none ] && kill -0 "$pid" 2>/dev/null; then alive=alive; else alive=dead; fi
    say "  lock: present -> ${owner##*/} pid=$pid ($alive)"
  elif [ -e "$lock" ]; then
    say "  lock: present (non-symlink)"
  else
    say "  lock: absent"
  fi
}

: > "$log"
say "== tree: $tree ($(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo snapshot))"
say "== step 1: refresh killed at a forced 3 s deadline"
env FM_HOME_SUMMARY_TIMEOUT=3 "$E/scripts/run-lab.sh" "$tree" fm-home-summary-refresh.sh \
  > "$SCR/dl1.out" 2> "$SCR/dl1.err"
say "  rc=$? stderr=$(tail -1 "$SCR/dl1.err")"
lock_report

if [ ! -L "$lock" ]; then
  say "== step 2: deadline kill released the lock; SIGKILL a worker mid-run instead"
  (
    set -m
    "$E/scripts/run-lab.sh" "$tree" fm-home-summary-refresh.sh --_worker \
      > "$SCR/dl2.out" 2> "$SCR/dl2.err" &
    wpid=$!
    until [ -L "$lock" ]; do sleep 0.05; done
    sleep 1
    kill -KILL -- "-$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    printf '  worker pgid %s SIGKILLed\n' "$wpid"
  ) | tee -a "$log"
  lock_report
fi

say "== step 3: ordinary direct refresh (default bound, no override, no --best-effort)"
unset FM_HOME_SUMMARY_TIMEOUT
prev=$(jq -r '.generated_epoch // 0' "$ledger" 2>/dev/null || echo 0)
l0=$(load1); t0=$(now)
"$E/scripts/run-lab.sh" "$tree" fm-home-summary-refresh.sh > "$SCR/dl3.out" 2> "$SCR/dl3.err"
rc=$?
t1=$(now); l1=$(load1)
gen=$(jq -r '.generated_epoch // 0' "$ledger" 2>/dev/null || echo 0)
eps=$(jq -r '.counts.endpoints // "none"' "$ledger" 2>/dev/null || echo none)
if [ "$rc" -eq 0 ] && [ "$gen" != "$prev" ]; then pub=published; else pub=NOT-published; fi
say "  rc=$rc wall=$(echo "$t1 - $t0" | bc)s load1=$l0->$l1 $pub generated_epoch $prev->$gen endpoints=$eps stderr=$(tail -1 "$SCR/dl3.err")"
lock_report
say "  ledger mode=$(stat -f %Lp "$ledger") schema=$(jq -r .schema "$ledger") valid=$(jq -r .valid "$ledger")"
