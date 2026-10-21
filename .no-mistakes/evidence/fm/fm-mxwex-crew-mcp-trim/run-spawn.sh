#!/bin/bash
set -eu
BASE=$PWD/.mcp-validation
export TMPDIR=$BASE/tmp
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME=$BASE/user CLAUDE_CONFIG_DIR=$BASE/claude-config
export FM_HOME=$BASE/lab TMUX_TMPDIR=$(cat "$BASE/socket-dir") TMUX=$(cat "$BASE/tmux-env")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
id=$1
shift
bin/fm-spawn.sh "$id" "$BASE/project" --harness claude "$@"
