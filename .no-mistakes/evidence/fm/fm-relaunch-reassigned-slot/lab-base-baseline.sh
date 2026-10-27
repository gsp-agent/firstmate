#!/usr/bin/env bash
# Failing-first baseline: the BASE commit's scripts against the same lab slot 3,
# which is claimed by another task. Shows the pre-fix advice and relaunch.
set -u
REPO=$1 LAB=$2 BASE=$3 id=nmlab-other
TD=$(cat "$LAB/state/.fm-lab-tmux-dir")
SRC="$LAB/base-src"
mkdir -p "$SRC"
git -C "$REPO" archive "$BASE" | tar -x -C "$SRC" || exit 1
echo "base commit: $BASE; slot demo-3 claim: $(sed -n 's/^task=//p' "$LAB/pool/demo-3/.fm-slot-owner")"
labrun() {
  env -u TMUX FM_HOME="$LAB" TMUX_TMPDIR="$TD" HOME="$LAB/user-home" \
    CLAUDE_CONFIG_DIR="$LAB/claude-config" FM_SPAWN_NO_GUARD=1 FM_CONTROL_LAUNCH_WAIT=180 "$@"
}
printf 'done: PR ready for merge\n' > "$LAB/state/$id.status"
printf 'bead=lab-acceptance\npid=%s\ntask=%s\n' "$$" "$id" > "$LAB/state/.pm-live-$id"
labrun bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" "$2" "$3" poll' \
  _ "$SRC" "$id" https://github.com/example/repo/pull/803 2>&1
echo "BASE status line: $(tail -n 1 "$LAB/state/$id.status")"
echo
echo "=== BASE bin/fm-control.sh $id relaunch --note 'Merged; activation pending'"
rc=0
(cd "$SRC" && labrun bin/fm-control.sh "$id" relaunch --note 'Merged; activation pending' 2>&1) || rc=$?
echo "exit=$rc"
echo "slot demo-3 (claimed by another task) endpoint now runs: $(TMUX_TMPDIR="$TD" tmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
