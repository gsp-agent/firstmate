#!/usr/bin/env bash
export FM_HOME=$1
for n in 1 2 3; do
  bin/fm-cursor-guard.sh take lab-third-cap
  printf 'Take %s exit=%s\n' "$n" "$?"
done
cat "$FM_HOME/state/cursor-dispatch.json"
