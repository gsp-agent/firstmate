#!/usr/bin/env bash
set -eu
unset FM_TEST_MACHINE_GATE FM_TEST_MACHINE_LINE_HELD FM_TEST_MACHINE_LINE_ADMITTED
unset FM_TEST_MACHINE_LINE_STARTED_ISO FM_TEST_MACHINE_LINE_STARTED_MS FM_TASK_ID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME
export TMPDIR="$PWD/.live-machine-line/temp"
export TMP="$TMPDIR"
export GIT_CEILING_DIRECTORIES="$TMPDIR"
export MACHINE_LINE_DIR="$PWD/.live-machine-line/actual-repository-suite-corrected/line"
export MACHINE_GATE_HOLD_FILE="$PWD/.live-machine-line/actual-repository-suite-corrected/absent-hold"
export MACHINE_LINE_NAME=fm-test-run-live-repository-suite
export FM_TEST_MACHINE_LINE_RETRY_SECS=1
exec bash bin/fm-test-run.sh --jobs 4 \
  --json /Users/dalecarman/.no-mistakes/evidence/01M4WN4HWS9WNQ0STXQVSD1KF2/actual-repository-suite-corrected.json \
  tests/fm-forge-detect.test.sh tests/fm-project-mode.test.sh \
  tests/fm-operational-input.test.sh tests/fm-composer-ghost.test.sh
