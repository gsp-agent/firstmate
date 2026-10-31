#!/usr/bin/env bash
# Run bystander.test.sh in a copy through the real runner, report who survived, then
# stop the bystanders by recorded pid and start time and remove the lab home.
# usage: bystander.sh <copy>
set -u
copy=$1
drivers=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cp "$drivers/bystander.test.sh" "$copy/tests/zz-bystander.test.sh"
PROBE_OUT=$(mktemp -d "$copy/.probe-out.XXXXXX")
export PROBE_OUT
PROBE_LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
export PROBE_LAB
( cd "$copy" && bin/fm-lab-home.sh create "$PROBE_LAB" ) || exit 2
cd "$copy" || exit 2
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  bin/fm-test-run.sh tests/zz-bystander.test.sh </dev/null > "$PROBE_OUT/runner.log" 2>&1
printf 'runner exit: %s\n' "$?"
grep -E 'before the suite exit|probe:|not ok' "$PROBE_OUT/runner.log"
sleep 2
for name in bystander-watcher group-orphan; do
  p=$(cat "$PROBE_OUT/$name.pid" 2>/dev/null)
  start=$(cat "$PROBE_OUT/$name.lstart" 2>/dev/null)
  if [ -n "$p" ] && [ "$(LC_ALL=C ps -o lstart= -p "$p" 2>/dev/null)" = "$start" ]; then
    printf '%s after the suite exit: ALIVE %s\n' "$name" "$(ps -o pid=,ppid=,pgid=,stat=,comm= -p "$p")"
    kill -TERM "$p" 2>/dev/null
  else
    printf '%s after the suite exit: GONE (pid %s)\n' "$name" "$p"
  fi
done
sleep 3
for name in bystander-watcher group-orphan; do
  p=$(cat "$PROBE_OUT/$name.pid" 2>/dev/null)
  start=$(cat "$PROBE_OUT/$name.lstart" 2>/dev/null)
  if [ -n "$p" ] && [ "$(LC_ALL=C ps -o lstart= -p "$p" 2>/dev/null)" = "$start" ]; then
    kill -KILL "$p" 2>/dev/null
  fi
done
printf '%s\n' "$PROBE_LAB" > "$PROBE_OUT/lab-path"
printf 'lab home to remove: %s\n' "$PROBE_LAB"
