#!/usr/bin/env bash
# Re-run the BASE relaunch against lab slot 3 (claimed by another task) after
# giving the extracted base tree a git history, so fm-spawn's history check can
# read its code root. Shows whether the base starts a worker in that slot.
set -u
LAB=$1 id=nmlab-other
TD=$(cat "$LAB/state/.fm-lab-tmux-dir")
SRC="$LAB/base-src"
if [ ! -d "$SRC/.git" ]; then
  git init -q -b main "$SRC" && git -C "$SRC" add -A \
    && git -C "$SRC" -c user.name=lab -c user.email=lab@example.invalid commit -q -m base || exit 1
fi
echo "slot demo-3 claim: $(sed -n 's/^task=//p' "$LAB/pool/demo-3/.fm-slot-owner")"
echo "=== BASE bin/fm-control.sh $id relaunch --note 'Merged; activation pending'"
rc=0
(cd "$SRC" && env -u TMUX FM_HOME="$LAB" TMUX_TMPDIR="$TD" HOME="$LAB/user-home" \
  CLAUDE_CONFIG_DIR="$LAB/claude-config" FM_SPAWN_NO_GUARD=1 FM_CONTROL_LAUNCH_WAIT=180 \
  bin/fm-control.sh "$id" relaunch --note 'Merged; activation pending' 2>&1) || rc=$?
echo "exit=$rc"
echo "slot demo-3 (claimed by gsp-p35kr-2-lab) endpoint now runs: $(TMUX_TMPDIR="$TD" tmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
echo "progress notes appended to $id brief: $(grep -c 'Merged; activation pending' "$LAB/data/$id/brief.md")"
