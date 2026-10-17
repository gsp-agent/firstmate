#!/usr/bin/env bash
# Print the lab's observable state: worker panes with their pids, task
# records, backlog states, extra-start records, and reading runs.
# Usage: lab-snap.sh <lab> [label]
set -u
LAB=$1
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$(cat "$EV/.lab-sock")
echo "== snapshot ${2:-} now=$(date +%s)"
echo "-- panes:"
TMUX_TMPDIR="$SOCK" tmux -L fm-lab list-windows -a -F '#{window_name} pid=#{pane_pid} cmd=#{pane_current_command} dead=#{pane_dead}' 2>&1
echo "-- task records:"
( cd "$LAB/state" && ls -1 ./*.meta 2>/dev/null | sed 's|^\./||' ) || :
echo "-- backlog:"
awk '/^## /{sec=substr($0,4)} /^- \[/{if (match($0,/task-[a-z0-9]+/)) print substr($0,RSTART,RLENGTH)" "sec}' "$LAB/data/backlog.md"
echo "-- extra-start records:"
for f in "$LAB"/state/project-capacity-overshare/*; do
  [ -e "$f" ] || { echo "(none)"; break; }
  printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
done
echo "-- reading runs:"
cat "$LAB/readings/runs.log"
