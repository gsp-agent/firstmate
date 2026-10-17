#!/usr/bin/env bash
# Build the disposable round-3 lab for the headroom-admission live check:
# a marked lab FM_HOME, five project clones each with a local bare origin
# (project, other, hang, race, zero), a markdown backlog, briefs, the reading
# programs, the real agent-observer reading (git archive of
# origin/fm/ac-a3ov3-5-dial), and a private tmux server whose panes use a
# lab-local Treehouse pool.
# Usage: lab-setup.sh <worktree-root> <lab>
set -eu
ROOT=$1
LAB=$2
EV=$(cd "$(dirname "$0")" && pwd)
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf '%s\n' "$SOCK" > "$EV/.lab-sock"
printf '%s\n' "$LAB" > "$EV/.lab-path"

g() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
mkdir -p "$LAB/origin" "$LAB/treehouse" "$LAB/readings" "$LAB/observer"
for p in project other hang race zero; do
  git init -q --bare -b main "$LAB/origin/$p.git"
  git init -q -b main "$LAB/projects/$p"
  printf 'lab %s\n' "$p" > "$LAB/projects/$p/README.md"
  g -C "$LAB/projects/$p" add README.md
  g -C "$LAB/projects/$p" commit -q -m init
  git -C "$LAB/projects/$p" remote add origin "$LAB/origin/$p.git"
  git -C "$LAB/projects/$p" push -q -u origin main
done

printf '%s\n' 'project 1' 'other 1' 'hang 1' 'race 1' 'zero 0' > "$LAB/config/project-capacity"

# The real shared reading, unmodified, from agent-observer's dial branch.
git -C "$HOME/dev/agent-observer" archive origin/fm/ac-a3ov3-5-dial | tar -x -C "$LAB/observer"
git -C "$HOME/dev/agent-observer" rev-parse origin/fm/ac-a3ov3-5-dial > "$LAB/observer/.commit"

R="$LAB/readings"
: > "$R/runs.log"
mk() { cat > "$R/$1"; chmod +x "$R/$1"; }
mk room <<EOF
#!/bin/sh
echo "room \$\$ \$(date +%s)" >> "$R/runs.log"
echo "cpu_idle_pct=41.5 load1=12.30 disk_free_gb=566.0 (lab room)"
exit 0
EOF
mk noroom <<EOF
#!/bin/sh
echo "noroom \$\$ \$(date +%s)" >> "$R/runs.log"
echo "cpu_idle_pct=3.0 load1=97.10 disk_free_gb=566.0 (lab busy)"
exit 1
EOF
mk silent <<EOF
#!/bin/sh
echo "silent \$\$ \$(date +%s)" >> "$R/runs.log"
exit 0
EOF
mk slowroom <<EOF
#!/bin/sh
# A reading slower than the old 5 s bound and slower than the slowest
# shared reading measured on this machine (12.7 s), that reports room.
echo "slowroom-start \$\$ \$(date +%s)" >> "$R/runs.log"
sleep 14
echo "slowroom-end \$\$ \$(date +%s)" >> "$R/runs.log"
echo "cpu_idle_pct=27.0 load1=33.00 disk_free_gb=563.0 (lab slow room, 14 s)"
exit 0
EOF
mk hang <<EOF
#!/bin/sh
echo "hang \$\$ \$(date +%s)" >> "$R/runs.log"
printf '%s\n' "\$\$" > "$R/hang.pid"
exec sleep 120
EOF
# Wrapper around the real shared reading that logs the reading's own duration,
# exit and line, then hands Firstmate exactly the reading's stdout and exit.
mk observed <<EOF
#!/bin/sh
s=\$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
out=\$(node "$LAB/observer/machine-headroom.mjs" 2>/dev/null)
rc=\$?
e=\$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
echo "observed-reading pid=\$\$ start=\$s end=\$e took=\$(echo "\$e - \$s" | bc)s exit=\$rc line=[\$out]" >> "$R/runs.log"
printf '%s\n' "\$out"
exit \$rc
EOF

touch "$LAB/state/.last-watcher-beat"
printf '%s\n' codex > "$LAB/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
cat > "$LAB/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
for id in task-a task-b task-c task-o1 task-o2 task-o3 task-h1 task-h2 task-h3 task-r0 task-r1 task-r2 task-z1; do
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

for w in 0 1 2; do
  if [ "$w" = 0 ]; then
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
      TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$LAB/treehouse" \
      tmux -L fm-lab new-session -d -s firstmate -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" /bin/bash --noprofile --norc
  else
    TMUX_TMPDIR="$SOCK" tmux -L fm-lab new-window -d -t "firstmate:$((w + 7))" -n "primary$w" -c "$ROOT" \
      -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" /bin/bash --noprofile --norc
  fi
done
TMUX_TMPDIR="$SOCK" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_index} #{window_name}'
echo "lab ready: $LAB (socket dir $SOCK, observer $(cat "$LAB/observer/.commit"))"
