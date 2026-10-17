#!/usr/bin/env bash
# Add a local secondmate lab home under the round-3 root lab home: a marked
# lab home whose parent marker names the root, registered in the root's
# data/secondmates.md, with its own clone of the root's 'hang' project origin
# (same directory name, so the root's 'hang 1' declaration and its shared
# project lock apply), a brief and backlog item for task-m1, and its own
# config/project-capacity-headroom naming the no-room reading, which must not
# be consulted. Usage: lab-mate-setup.sh <worktree-root> <mate-lab>
set -eu
ROOT=$1
MATE=$2
EV=$(cd "$(dirname "$0")" && pwd)
LAB=$(cat "$EV/.lab-path")
printf '%s\n' "$MATE" > "$EV/.lab2-path"
git clone -q "$LAB/origin/hang.git" "$MATE/projects/hang"
printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$LAB" > "$MATE/.fm-secondmate-parent"
printf -- '- mate - a local lab mate (home: %s; scope: project work; projects: hang; added 2026-10-17)\n' "$MATE" \
  > "$LAB/data/secondmates.md"
printf '%s\n' "$LAB/readings/noroom" > "$MATE/config/project-capacity-headroom"
touch "$MATE/state/.last-watcher-beat"
printf '%s\n' codex > "$MATE/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$MATE/data/backlog.md"
cat > "$MATE/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
mkdir -p "$MATE/data/task-m1"
cat > "$MATE/data/task-m1/brief.md" <<'EOF'
# Task
## Captain's intent
Lab check for task-m1: a secondmate home's extra start.

## Firstmate spec
Exercise project capacity headroom admission from a secondmate home.

# Definition of done
Delivery contract: mode=local-only
EOF
tasks-axi add task-m1 "lab item task-m1" --kind ship --file "$MATE/data/backlog.md" >/dev/null
echo "mate ready: $MATE (parent $LAB)"
