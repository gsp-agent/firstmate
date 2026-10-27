#!/usr/bin/env bash
# Direct fm-spawn --relaunch into a pre-claim slot (no .fm-slot-owner): must still launch.
set -u
REPO=$1 LAB=$2 id=nmlab-absent
cd "$REPO" || exit 1
TD=$(cat "$LAB/state/.fm-lab-tmux-dir")
echo "slot claim present: $([ -e "$LAB/pool/demo-5/.fm-slot-owner" ] && echo yes || echo no)"
echo "=== bin/fm-spawn.sh $id --relaunch"
rc=0
env -u TMUX FM_HOME="$LAB" TMUX_TMPDIR="$TD" HOME="$LAB/user-home" \
  CLAUDE_CONFIG_DIR="$LAB/claude-config" FM_SPAWN_NO_GUARD=1 \
  bin/fm-spawn.sh "$id" --relaunch 2>&1 || rc=$?
echo "exit=$rc"
for i in $(seq 1 60); do
  cmd=$(TMUX_TMPDIR="$TD" tmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')
  [ "$cmd" = bash ] || break
  sleep 2
done
echo "endpoint now runs: $cmd"
