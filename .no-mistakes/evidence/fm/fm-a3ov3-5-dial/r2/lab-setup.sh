#!/usr/bin/env bash
# Round 2: build the disposable lab for the headroom-admission live check.
# A marked lab FM_HOME with three project clones (project, other, zero), each
# with a local bare origin; a markdown backlog; briefs; two copies of the
# shared reading from agent-observer (86a7756c, whose main() guard prints
# nothing under a non-canonical path, and the current fm/ac-a3ov3-5-dial);
# lab reading programs; and a private tmux server on the lab socket.
# Usage: lab-setup.sh <worktree-root> <lab>
set -eu
ROOT=$1
LAB=$2
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf '%s\n' "$SOCK" > "$EV/.lab-sock"

g() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
mkdir -p "$LAB/origin" "$LAB/treehouse" "$LAB/readings"
for p in project other zero; do
  git init -q --bare -b main "$LAB/origin/$p.git"
  git init -q -b main "$LAB/projects/$p"
  printf 'lab %s\n' "$p" > "$LAB/projects/$p/README.md"
  g -C "$LAB/projects/$p" add README.md
  g -C "$LAB/projects/$p" commit -q -m init
  git -C "$LAB/projects/$p" remote add origin "$LAB/origin/$p.git"
  git -C "$LAB/projects/$p" push -q -u origin main
done

touch "$LAB/state/.last-watcher-beat"
printf '%s\n' codex > "$LAB/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
cat > "$LAB/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
for id in task-a task-b task-c task-d task-o1 task-o2 task-z task-r1 task-r2; do
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

# Shared reading, two revisions, extracted read-only from agent-observer.
mkdir -p "$LAB/observer-old" "$LAB/observer"
git -C "$HOME/dev/agent-observer" archive 86a7756c | tar -x -C "$LAB/observer-old"
git -C "$HOME/dev/agent-observer" archive fm/ac-a3ov3-5-dial | tar -x -C "$LAB/observer"

# Lab reading programs. Each appends one line to readings/runs.log per run.
R="$LAB/readings"
cat > "$R/room" <<EOF
#!/bin/sh
echo "room \$\$" >> "$R/runs.log"
echo "cpu_idle_pct=41.5 load1=12.30 disk_free_gb=566.0 (lab room)"
exit 0
EOF
cat > "$R/noroom" <<EOF
#!/bin/sh
echo "noroom \$\$" >> "$R/runs.log"
echo "cpu_idle_pct=3.0 load1=97.10 disk_free_gb=566.0 (lab busy)"
exit 1
EOF
cat > "$R/silent" <<EOF
#!/bin/sh
echo "silent \$\$" >> "$R/runs.log"
exit 0
EOF
cat > "$R/blankfirst" <<EOF
#!/bin/sh
echo "blankfirst \$\$" >> "$R/runs.log"
printf '\ncpu_idle_pct=41.5 load1=12.30 disk_free_gb=566.0 (second line)\n'
exit 0
EOF
cat > "$R/hang" <<EOF
#!/bin/sh
echo "hang \$\$" >> "$R/runs.log"
exec sleep 30
EOF
chmod +x "$R"/room "$R"/noroom "$R"/silent "$R"/blankfirst "$R"/hang
: > "$R/runs.log"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$LAB/treehouse" \
  tmux -L fm-lab new-session -d -s firstmate -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" /bin/bash --noprofile --norc
TMUX_TMPDIR="$SOCK" tmux -L fm-lab list-sessions
echo "lab ready: $LAB (socket dir $SOCK)"
