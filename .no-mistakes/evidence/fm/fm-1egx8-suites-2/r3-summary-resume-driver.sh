#!/usr/bin/env bash
set -u
export EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ
export HOME="$PWD/.test-phase-r3/home" TMPDIR="$PWD/.test-phase-r3/tmp" TMP="$PWD/.test-phase-r3/tmp"
export FM_SNAPSHOT_REGISTRY_TIMEOUT=30
unset FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
bash .test-phase-r3/summary-resume.sh
