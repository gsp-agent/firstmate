#!/usr/bin/env bash
# Cross-home race: the root lab home spawns <root-id> and the local secondmate
# lab home spawns <mate-id>, both on a clone of the same project, typed into
# two lab panes back to back so both reach the shared project lock.
# Usage: lab-race-homes.sh <step> <root-id> <mate-id>
set -u
STEP=$1
A=$2
B=$3
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$(cat "$EV/.lab-sock")
LAB2=$(cat "$EV/.lab2-path")
rm -f "$EV/.done-$STEP-root" "$EV/.done-$STEP-mate"
TMUX_TMPDIR="$SOCK" tmux -L fm-lab send-keys -t firstmate:0 "$EV/lab-spawn.sh $STEP-root $A project" Enter
TMUX_TMPDIR="$SOCK" tmux -L fm-lab send-keys -t firstmate:9 "FM_HOME=$LAB2 $EV/lab-spawn.sh $STEP-mate $B project" Enter
i=0
while [ ! -f "$EV/.done-$STEP-root" ] || [ ! -f "$EV/.done-$STEP-mate" ]; do
  i=$((i + 1))
  if [ "$i" -gt 400 ]; then
    echo "race $STEP did not return in 200 s" >&2
    exit 1
  fi
  sleep 0.5
done
cat "$EV/spawn-$STEP-root.log" "$EV/spawn-$STEP-mate.log"
