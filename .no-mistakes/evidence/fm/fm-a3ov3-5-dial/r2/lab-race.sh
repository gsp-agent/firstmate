#!/usr/bin/env bash
# Two real spawns of one project at its declared count, typed into two lab
# panes back to back, both racing for the project's one extra start.
# Usage: lab-race.sh <step> <id-1> <id-2> [project-name]
set -u
STEP=$1
A=$2
B=$3
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$(cat "$EV/.lab-sock")
rm -f "$EV/.done-$STEP-1" "$EV/.done-$STEP-2"
TMUX_TMPDIR="$SOCK" tmux -L fm-lab send-keys -t firstmate:0 "$EV/lab-spawn.sh $STEP-1 $A ${4:-project}" Enter
TMUX_TMPDIR="$SOCK" tmux -L fm-lab send-keys -t firstmate:9 "$EV/lab-spawn.sh $STEP-2 $B ${4:-project}" Enter
i=0
while [ ! -f "$EV/.done-$STEP-1" ] || [ ! -f "$EV/.done-$STEP-2" ]; do
  i=$((i + 1))
  if [ "$i" -gt 400 ]; then
    echo "race $STEP did not return in 200 s" >&2
    exit 1
  fi
  sleep 0.5
done
cat "$EV/spawn-$STEP-1.log" "$EV/spawn-$STEP-2.log"
