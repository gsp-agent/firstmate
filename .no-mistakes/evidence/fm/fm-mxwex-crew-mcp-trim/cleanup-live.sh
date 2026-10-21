#!/bin/bash
set -eu
BASE=$PWD/.mcp-validation
export HOME=$BASE/user CLAUDE_CONFIG_DIR=$BASE/claude-config FM_HOME=$BASE/lab TMPDIR=$BASE/tmp
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export TMUX_TMPDIR=$(cat "$BASE/socket-dir") TMUX=$(cat "$BASE/tmux-env")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
# All four records belong to this disposable run and contain no requested work.
for id in trim-default trim-off trim-scout; do
  bin/fm-teardown.sh "$id" --force
done
"$BASE/runtime/bin/fm-teardown.sh" trim-secondmate --force
tmux -L fm-lab kill-server
bin/fm-lab-home.sh teardown "$BASE/lab"
echo 'Disposable Claude processes, task temp roots, launch namespaces, and private tmux server cleaned up.'
