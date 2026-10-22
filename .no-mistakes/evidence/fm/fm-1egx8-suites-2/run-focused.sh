#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ
export TMPDIR="$ROOT/.test-phase/tmp" TMP="$ROOT/.test-phase/tmp" HOME="$ROOT/.test-phase/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" CLAUDE_CONFIG_DIR="$HOME/.claude" FM_HOME="$HOME/fm"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_BACKEND
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data" "$FM_HOME/projects"
rc=0
for selection in test_provably_working_signal_absorbed test_turn_ended_not_working_surfaced; do
  FM_TEST_ONLY="$selection" bash tests/fm-watch-triage.test.sh > "$EVIDENCE/$selection.log" 2>&1
  status=$?
  printf '%s rc=%s\n' "$selection" "$status"
  cat "$EVIDENCE/$selection.log"
  [ "$status" -eq 0 ] || rc=1
done
for suite in fm-home-summary-refresh fm-timeout-lib fm-test-isolation-proof; do
  bash "tests/$suite.test.sh" > "$EVIDENCE/$suite.log" 2>&1
  status=$?
  printf '%s rc=%s\n' "$suite" "$status"
  tail -12 "$EVIDENCE/$suite.log"
  [ "$status" -eq 0 ] || rc=1
done
exit "$rc"
