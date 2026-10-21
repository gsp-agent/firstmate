#!/bin/bash
set -eu
BASE=$PWD/.mcp-validation
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME=$BASE/user CLAUDE_CONFIG_DIR=$BASE/claude-config FM_HOME=$BASE/lab TMPDIR=$BASE/tmp
export TMUX_TMPDIR=$(cat "$BASE/socket-dir") TMUX=$(cat "$BASE/tmux-env")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
mkdir -p "$BASE/runtime"
# A disposable distribution lets the secondmate live outside its code root,
# while every source and home remains inside the authorized run directory.
git archive HEAD bin AGENTS.md CLAUDE.md .claude .agents .tasks.toml .gitignore | tar -x -C "$BASE/runtime"
git -C "$BASE/runtime" init -q -b main
git -C "$BASE/runtime" add bin AGENTS.md CLAUDE.md .claude .agents .tasks.toml .gitignore
git -C "$BASE/runtime" -c user.name=Lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -qm 'Disposable copy of target distribution'
export FM_SECONDMATE_CHARTER='Validate the Claude launch configuration. Remain idle and do not modify files.'
"$BASE/runtime/bin/fm-home-seed.sh" trim-secondmate "$BASE/secondmate" --no-projects
"$BASE/runtime/bin/fm-spawn.sh" trim-secondmate "$BASE/secondmate" --harness claude --secondmate
