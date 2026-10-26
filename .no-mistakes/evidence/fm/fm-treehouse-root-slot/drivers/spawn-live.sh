#!/usr/bin/env bash
# spawn-live.sh <work-dir> <gate-worktree> <fm-root> <layout> <label> <evidence-dir> [treehouse-bin-dir]
# One full ship spawn against real tmux and real Treehouse:
#   - mints a marked lab home with bin/fm-lab-home.sh (runbook contract) and a
#     private tmux socket under it; never the default tmux server
#   - builds the pool layout with the real Treehouse binary
#   - starts the lab tmux server, whose "primary" pane runs fm-spawn.sh from
#     <fm-root> (the gate worktree for the fix, an archive of the base commit
#     for the failing-first replay)
#   - reports what the spawn printed, the worktree it recorded, where the task
#     window's pane really is, and the configured pool afterwards
# Leaves the lab home and layout on disk; the caller removes them by literal path.
set -u
W=$1 GATE=$2 FMROOT=$3 LAYOUT=$4 LABEL=$5 EVID=$6 TH_DIR=${7:-}
DRV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -z "$TH_DIR" ] || PATH="$TH_DIR:$PATH"
export PATH
. "$DRV/scenario-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$GATE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
touch "$LAB/state/.last-watcher-beat"
printf '%s\n' "$LAB" >> "$W/labs.list"
id="rootswitch-$LABEL"
mkdir -p "$LAB/data/$id"
cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Live root-switch slot steering check for $id; the worker is a sleep loop.

## Firstmate spec
Exercise the spawn behavior under test.
EOF

dir="$W/spawn/$LABEL"
build_layout "$LAYOUT" "$dir" >/dev/null || { echo "layout build failed"; exit 1; }
proj="$dir/proj"
transcript="$EVID/spawn-$LABEL.fm-spawn-output.txt"
rcfile="$LAB/spawn.rc"

lab_tmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }

printf '### spawn scenario: %s (layout %s)\n' "$LABEL" "$LAYOUT"
printf 'fm-spawn.sh from: %s\n' "$FMROOT"
printf 'treehouse: %s %s\n' "$(command -v treehouse)" "$(treehouse --version 2>/dev/null | tr -d '[:space:]')"
printf -- '--- pool layout before the spawn ---\n'
describe_layout "$dir"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$GATE" \
  -e FM_HOME="$LAB" -e FM_SPAWN_NO_GUARD=1 -e PATH="$PATH" "/bin/bash --noprofile --norc"
if [ -n "$TH_DIR" ]; then
  # The task window's shell must also find the pinned Treehouse first.
  lab_tmux set -g default-command "env PATH='$PATH' /bin/bash --noprofile --norc"
fi
lab_tmux send-keys -t primary "bash '$DRV/spawn-one.sh' '$FMROOT' '$id' '$proj' '$transcript' '$rcfile'" Enter

waited=0
while [ ! -s "$rcfile" ] && [ "$waited" -lt 180 ]; do
  sleep 1
  waited=$((waited + 1))
done

printf -- '--- spawn result ---\n'
if [ -s "$rcfile" ]; then cat "$rcfile"; else printf 'spawn did not finish within 180s\n'; fi
printf 'fm-spawn output (scrubbed, %s):\n' "$transcript"
sed 's/^/  | /' "$transcript" 2>/dev/null | grep -v '^  | $' | tail -25
meta="$LAB/state/$id.meta"
if [ -f "$meta" ]; then
  printf 'state/%s.meta worktree=%s\n' "$id" "$(sed -n 's/^worktree=//p' "$meta")"
else
  printf 'state/%s.meta: none (no task was recorded)\n' "$id"
fi
win="primary:fm-$id"
if lab_tmux list-windows -t primary -F '#{window_name}' 2>/dev/null | grep -qx "fm-$id"; then
  printf 'task window %s pane_current_path=%s\n' "fm-$id" "$(lab_tmux display-message -p -t "$win" '#{pane_current_path}' 2>/dev/null)"
  printf 'treehouse lines the spawn typed into the task pane (full pane history):\n'
  lab_tmux capture-pane -p -S - -t "$win" 2>/dev/null | grep -E 'treehouse (enter|get)|no worktree|not found|Error' | no-mistakes redact 2>/dev/null | sed 's/^/  > /'
  printf 'task window pane (last rows):\n'
  lab_tmux capture-pane -p -t "$win" 2>/dev/null | grep -v '^$' | tail -8 | no-mistakes redact 2>/dev/null | sed 's/^/  > /'
else
  printf 'task window fm-%s: not present (spawn closed it or never made it)\n' "$id"
fi
printf -- '--- configured pool after the spawn ---\n'
describe_layout "$dir"
lab_tmux kill-server 2>/dev/null || true
printf 'lab tmux server killed; lab home %s\n' "$LAB"
