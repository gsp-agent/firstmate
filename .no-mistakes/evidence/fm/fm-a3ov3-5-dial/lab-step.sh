#!/usr/bin/env bash
# Drive one spawn step through the lab primary pane on the private fm-lab
# tmux socket, wait for it to return (up to 150 s), and print its transcript.
# Usage: [LAB_PANE=firstmate:N] lab-step.sh <step> <id> [project-name]
set -u
STEP=$1
ID=$2
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$(cat "$EV/.lab-sock")
rm -f "$EV/.done-$STEP"
TMUX_TMPDIR="$SOCK" tmux -L fm-lab send-keys -t "${LAB_PANE:-firstmate:0}" "$EV/lab-spawn.sh $STEP $ID ${3:-project}" Enter
i=0
while [ ! -f "$EV/.done-$STEP" ]; do
  i=$((i + 1))
  if [ "$i" -gt 300 ]; then
    echo "step $STEP did not return in 150 s" >&2
    exit 1
  fi
  sleep 0.5
done
cat "$EV/spawn-$STEP.log"
