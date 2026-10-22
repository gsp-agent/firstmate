#!/usr/bin/env bash
set -u
export EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ
export HOME="$PWD/.test-phase-r3/home" TMPDIR="$PWD/.test-phase-r3/tmp" TMP="$PWD/.test-phase-r3/tmp"
unset FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
FM_TEST_ONLY=test_check_sweep_reprobes_captain_holds bash .test-phase-r3/probe-evidence.sh
