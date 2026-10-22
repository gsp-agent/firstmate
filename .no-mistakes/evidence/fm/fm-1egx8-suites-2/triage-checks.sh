#!/usr/bin/env bash
set -u
export HOME="$PWD/.test-phase/home" TMPDIR="$PWD/.test-phase/tmp" TMP="$PWD/.test-phase/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME FM_TASK_ID
result=0
for selector in test_provably_working_signal_absorbed test_turn_ended_not_working_surfaced test_actionable_signal_surfaced test_check_sweep_reprobes_captain_holds test_check_sweep_surfaces_interrupted_probe_releases; do
  printf '\nSCENARIO %s\n' "$selector"
  FM_TEST_ONLY="$selector" bash tests/fm-watch-triage.test.sh || result=1
done
exit "$result"
