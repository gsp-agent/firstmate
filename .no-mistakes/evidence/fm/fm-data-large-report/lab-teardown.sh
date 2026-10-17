#!/usr/bin/env bash
# Run the real bin/fm-teardown.sh from the gate worktree against the marked lab
# home only: FM_HOME=<lab>, no FM_*_OVERRIDE, no gate bypass, HOME=<lab>/home,
# and TMUX pointed at the lab's private fm-lab server.
# Usage: lab-teardown.sh <worktree> <lab> <id> [extra env assignments...]
set -uo pipefail
WT=${1:?worktree} LAB=${2:?lab} ID=${3:?id}
shift 3
sock="$LAB/tmux/tmux-$(id -u)/fm-lab"
pid=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}')
cd "$WT" || exit 1
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BEADS_DIR -u BEADS_DB -u BR_DB \
  FM_HOME="$LAB" HOME="$LAB/home" TMUX_TMPDIR="$LAB/tmux" TMUX="$sock,$pid,0" "$@" \
  bin/fm-teardown.sh "$ID"
