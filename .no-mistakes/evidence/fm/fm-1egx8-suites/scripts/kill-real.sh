#!/usr/bin/env bash
# kill-real.sh <KILL-runner|TERM-group|INT-group>: start the real
# bin/fm-test-run.sh on a real watcher suite followed by a second suite, wait
# until the suite has a live fm-watch.sh, stop the runner from outside, and
# report every process that still carries this run's private TMPDIR.
set -u
mode=$1
suite=${2:-tests/fm-wake-queue.test.sh}
attempt=${3:-1}
EV=/Users/dalecarman/.no-mistakes/evidence/01M55Y5XKTJTJD73274HVHFNG1
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M55Y5XKTJTJD73274HVHFNG1
out="$EV/kill-$mode"
[ "$attempt" = 1 ] || out="$out-attempt$attempt"
mkdir -p "$out"
D=$(mktemp -d "/tmp/fm-kill-$mode.XXXXXX")
D=$(cd "$D" && pwd -P)
echo "$D" >>/tmp/fm-alone-cleanup.list
mine() {  # processes started by this run: its TMPDIR is in their environment
  ps -axE -ww -o pid=,pgid=,command= | grep -F "TMPDIR=$D" | grep -v -F 'grep -F' \
    | awk '{c=$0; sub(/ [A-Z_][A-Z0-9_]*=.*/, "", c); print substr(c, 1, 160)}'
}
cd "$WT" || exit 2
# A job started with & from this non-interactive shell inherits INT ignored.
# The gated mode re-executes the runner under the real machine gate, on a
# private line directory (the gate's own proof seam) so no real turn is taken.
gate=
case $mode in
  *-gated) gate=$HOME/.agent-state/machine-gate.sh ;;
esac
env FM_TEST_MACHINE_GATE="$gate" MACHINE_LINE_DIR="$D/line" MACHINE_LINE_NAME=fm-kill-proof \
  MACHINE_GATE_READ='echo "SLOT FREE = YES"' \
  FM_TEST_MACHINE_LINE_RETRY_SECS=2 TMPDIR="$D" perl -e 'setpgrp(0, 0); exec @ARGV' \
  bin/fm-test-run.sh --jobs 1 "$suite" tests/fm-host-mirror.test.sh \
  >"$out/runner.out" 2>&1 &
runner=$!
i=0
until mine | grep -q 'bin/fm-watch.sh' || [ "$i" -ge 120 ]; do sleep 0.5; i=$((i + 1)); done
sleep 2
{
  echo "mode=$mode runner_pid=$runner (its own process group)"
  echo "--- processes carrying TMPDIR=$D just before the signal:"
  mine
  echo "watchers live: $(mine | grep -c 'bin/fm-watch.sh')"
} >"$out/report.txt"
case $mode in
  KILL-runner|KILL-runner-gated) kill -KILL "$runner" ;;
  TERM-group) kill -TERM -- "-$runner" ;;
  INT-group) kill -INT -- "-$runner" ;;
esac
t0=$(date +%s)
rc=0
wait "$runner" 2>/dev/null || rc=$?
{
  echo "--- signal sent at $(date -u +%FT%TZ); runner exited rc=$rc after $(( $(date +%s) - t0 ))s"
  for s in 1 3 6 10 15 20 30; do
    while [ $(( $(date +%s) - t0 )) -lt "$s" ]; do sleep 0.2; done
    echo "t+${s}s: $(mine | grep -c .) processes left ($(mine | grep -c 'bin/fm-watch.sh') fm-watch.sh, $(mine | grep -c -E 'fm-home-summary|fm-fleet-snapshot') summary/snapshot)"
  done
  echo "--- still alive at t+30s:"
  mine
  echo "--- scripts the runner announced (a second one means it moved on):"
  grep -E '^FM_TEST_(BEGIN|END)' "$out/runner.out" || true
  grep -E 'starting no further|interrupted' "$out/runner.out" || true
  if [ -n "$gate" ]; then
    echo "--- private machine-line log (start/end rows; an end row means the gate let go):"
    cat "$D/line/log.tsv" 2>/dev/null || echo "(no log)"
  fi
} >>"$out/report.txt"
# Anything still alive is a defect; stop it so it does not run on.
left=$(mine | awk '{print $1}')
[ -z "$left" ] || kill -KILL $left 2>/dev/null
cat "$out/report.txt"
