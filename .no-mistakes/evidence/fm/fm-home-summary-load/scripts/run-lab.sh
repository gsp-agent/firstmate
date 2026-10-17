#!/usr/bin/env bash
# run-lab.sh <tree> <args...> - run a command from <tree>/bin against the lab
# home, with the lab's stub PATH and the lab's private tmux socket as $TMUX.
# FM_SNAPSHOT_NOW pins observation time when FM_LAB_PIN_NOW=1.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
tree=$1; shift
sock=$(cat "$LAB/.lab-tmux-socket")
pid=$(TMUX_TMPDIR=$TDIR tmux -L fm-lab display-message -p '#{pid}')
pin=()
if [ "${FM_LAB_PIN_NOW:-0}" = 1 ]; then
  pin=(FM_SNAPSHOT_NOW=2026-10-17T14:00:00Z FM_SNAPSHOT_NOW_EPOCH=1792245600 FM_CONTRIBUTIONS_NOW=2026-10-17T14:00:00Z)
fi
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$SCR/fakebin:$PATH" TMUX="$sock,$pid,0" TMUX_TMPDIR="$TDIR" FM_HOME="$LAB" \
  ${pin[@]+"${pin[@]}"} "$tree/bin/$@"
