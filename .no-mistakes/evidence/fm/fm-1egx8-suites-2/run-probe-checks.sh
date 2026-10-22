#!/usr/bin/env bash
set -u
ROOT=$PWD
export TMPDIR="$ROOT/.test-phase/tmp" TMP="$ROOT/.test-phase/tmp" HOME="$ROOT/.test-phase/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" CLAUDE_CONFIG_DIR="$HOME/.claude" FM_HOME="$HOME/fm"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_BACKEND
result=0
for selection in test_check_sweep_reprobes_captain_holds test_check_sweep_surfaces_interrupted_probe_releases; do
  FM_TEST_ONLY="$selection" bash tests/fm-watch-triage.test.sh > "/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/$selection.log" 2>&1
  rc=$?
  printf '%s rc=%s\n' "$selection" "$rc"
  tail -8 "/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/$selection.log"
  [ "$rc" = 0 ] || result=1
done
exit "$result"
