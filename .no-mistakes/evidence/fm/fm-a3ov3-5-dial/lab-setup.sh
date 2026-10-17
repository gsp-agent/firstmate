#!/usr/bin/env bash
# Build the disposable lab for the headroom-admission live check:
# a marked lab FM_HOME, a project clone with a local bare origin, a markdown
# backlog, briefs, and a private tmux server whose panes use a lab-local
# Treehouse pool. Usage: lab-setup.sh <worktree-root> <lab>
set -eu
ROOT=$1
LAB=$2
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf '%s\n' "$SOCK" > "$EV/.lab-sock"

g() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
mkdir -p "$LAB/origin" "$LAB/treehouse"
git init -q --bare -b main "$LAB/origin/project.git"
git init -q -b main "$LAB/projects/project"
printf 'lab project\n' > "$LAB/projects/project/README.md"
g -C "$LAB/projects/project" add README.md
g -C "$LAB/projects/project" commit -q -m init
git -C "$LAB/projects/project" remote add origin "$LAB/origin/project.git"
git -C "$LAB/projects/project" push -q -u origin main

touch "$LAB/state/.last-watcher-beat"
printf '%s\n' codex > "$LAB/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
cat > "$LAB/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
for id in task-a task-b task-c task-d task-e task-f task-g task-z; do
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Lab check for $id: hold a project place.

## Firstmate spec
Exercise project capacity headroom admission.

# Definition of done
Delivery contract: mode=local-only
EOF
  tasks-axi add "$id" "lab item $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
done

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$LAB/treehouse" \
  tmux -L fm-lab new-session -d -s firstmate -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" /bin/bash --noprofile --norc
TMUX_TMPDIR="$SOCK" tmux -L fm-lab list-sessions
echo "lab ready: $LAB (socket dir $SOCK)"
