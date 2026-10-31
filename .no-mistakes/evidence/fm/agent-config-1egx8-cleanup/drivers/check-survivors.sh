#!/usr/bin/env bash
# Report at the given delays whether the probe's held watcher and arm still run, by
# pid plus start time; safe columns only. Kills any survivor at the end (they are ours).
out=$1
shift
delays=${*:-0 10 60}
w=$(cat "$out/watcher.pid" 2>/dev/null)
a=$(cat "$out/arm.pid" 2>/dev/null)
start=$(cat "$out/watcher.lstart" 2>/dev/null)
alive() { [ -n "$w" ] && [ "$(LC_ALL=C ps -o lstart= -p "$w" 2>/dev/null)" = "$start" ]; }
prev=0
survived=0
for d in $delays; do
  sleep $((d - prev))
  prev=$d
  if alive; then
    survived=1
    printf '+%ss watcher %s ALIVE: %s\n' "$d" "$w" "$(ps -o pid=,ppid=,pgid=,stat=,comm= -p "$w")"
  else
    printf '+%ss watcher %s gone\n' "$d" "$w"
  fi
done
if [ -n "$a" ] && ps -o pid= -p "$a" >/dev/null 2>&1; then
  printf 'arm %s still running: %s\n' "$a" "$(ps -o pid=,ppid=,pgid=,stat=,comm= -p "$a")"
  survived=1
  kill -KILL "$a" 2>/dev/null
fi
if alive; then
  kill -KILL "$w" 2>/dev/null
  printf 'killed surviving watcher %s by hand\n' "$w"
fi
exit "$survived"
