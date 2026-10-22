#!/usr/bin/env bash
set -eu
ROOT=$PWD
export TMPDIR="$ROOT/.test-phase/tmp" TMP="$ROOT/.test-phase/tmp" HOME="$ROOT/.test-phase/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" CLAUDE_CONFIG_DIR="$HOME/.claude" FM_HOME="$HOME/fm"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_BACKEND
mkdir -p .test-phase/code/bin .test-phase/code/tests
for source in "$ROOT"/bin/*; do ln -s "$source" ".test-phase/code/bin/${source##*/}"; done
for source in "$ROOT"/tests/*.sh; do ln -s "$source" ".test-phase/code/tests/${source##*/}"; done
bash .test-phase/code/tests/fm-home-summary-refresh.test.sh > /Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/fm-home-summary-refresh-isolated.log 2>&1
