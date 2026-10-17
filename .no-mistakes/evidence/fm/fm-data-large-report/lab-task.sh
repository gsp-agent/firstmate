#!/usr/bin/env bash
# Start one lab task the way spawn leaves it: an In-flight backlog row, a task
# record in state/, a live tmux window on the lab server, and data/<id>/.
# Usage: lab-task.sh <lab> <id>
set -euo pipefail
LAB=${1:?lab} ID=${2:?id}
cd "$LAB"
tasks-axi add "$ID" "lab task $ID" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start "$ID" --file "$LAB/data/backlog.md" >/dev/null
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t firstmate: -n "fm-$ID" 'sleep 86400'
printf '%s\n' "window=firstmate:fm-$ID" "endpoint_task_id=$ID" "worktree=$LAB/missing-$ID" \
  "project=$LAB/projects/demo" "kind=ship" "mode=local-only" "spawn_gen=lab-$ID" \
  > "$LAB/state/$ID.meta"
mkdir -p "$LAB/data/$ID"
