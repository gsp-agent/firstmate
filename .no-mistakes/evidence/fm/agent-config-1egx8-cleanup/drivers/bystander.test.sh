#!/usr/bin/env bash
# Disposable probe: what the suite did not start must survive its exit sweep.
#  - a real fm-watch.sh from this same checkout in a real lab home, reparented to
#    launchd, in a process group of its own (named as the sweep's rule reads, wrong group)
#  - an orphan in the suite's own group whose command line names neither its scripts
#    nor its tree (right group, not named)
# Both pids go to PROBE_OUT for the driver.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$SELF_DIR/fm-supervision-host.test.sh"
out=${PROBE_OUT:?}
lab=${PROBE_LAB:?}
perl -e 'exit if fork; setpgrp(0, 0); exec @ARGV or die' env FM_HOME="$lab" "$ROOT/bin/fm-watch.sh" > "$out/bystander-watcher.log" 2>&1 < /dev/null
wait_until 900 test -s "$lab/state/.watch.lock/pid" || fail "probe: the bystander watcher never took its lock: $(cat "$out/bystander-watcher.log")"
cp "$lab/state/.watch.lock/pid" "$out/bystander-watcher.pid"
( sleep 3000 & printf '%s\n' "$!" > "$out/group-orphan.pid" ) &
wait "$!"
sleep 1
for name in bystander-watcher group-orphan; do
  p=$(cat "$out/$name.pid")
  LC_ALL=C ps -o lstart= -p "$p" > "$out/$name.lstart"
  printf '%s before the suite exit: %s (suite pgid %s)\n' "$name" "$(ps -o pid=,ppid=,pgid=,stat=,comm= -p "$p")" "$(ps -o pgid= -p "$$" | tr -d ' ')"
done
trap 'suite_cleanup; printf "probe: after cleanup\n"' EXIT
fail "forced red with bystanders running"
