#!/usr/bin/env bash
set -u
ROOT=$PWD
export EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ
export HOME="$ROOT/.test-phase-r3/home" TMPDIR="$ROOT/.test-phase-r3/tmp" TMP="$ROOT/.test-phase-r3/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" CLAUDE_CONFIG_DIR="$HOME/.claude" FM_HOME="$HOME/fm"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FM_TEST_MACHINE_GATE=''
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_BACKEND FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data" "$FM_HOME/projects"
rc=0
for selection in test_provably_working_signal_absorbed test_turn_ended_not_working_surfaced test_actionable_signal_surfaced test_check_sweep_reprobes_captain_holds test_check_sweep_surfaces_interrupted_probe_releases; do
  FM_TEST_ONLY="$selection" bash tests/fm-watch-triage.test.sh > "$EVIDENCE/r3-$selection.log" 2>&1
  status=$?
  printf '%s rc=%s\n' "$selection" "$status"
  cat "$EVIDENCE/r3-$selection.log"
  [ "$status" -eq 0 ] || rc=1
done
for suite in summary-evidence fm-timeout-lib fm-test-isolation-proof; do
  if [ "$suite" = summary-evidence ]; then path=.test-phase-r3/summary-evidence.sh; else path="tests/$suite.test.sh"; fi
  bash "$path" > "$EVIDENCE/r3-$suite.log" 2>&1
  status=$?
  printf '%s rc=%s\n' "$suite" "$status"
  tail -10 "$EVIDENCE/r3-$suite.log"
  [ "$status" -eq 0 ] || rc=1
done
exit "$rc"
