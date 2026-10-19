#!/usr/bin/env bash
set -u
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW
cd "$ROOT" || exit 2
export TMPDIR="$ROOT/.gate-test-phase/scratch"
export HOME="$ROOT/.gate-test-phase/user-home"
export CLAUDE_CONFIG_DIR=''
export FM_HOME="$ROOT/.gate-test-phase/fm-home"
export FM_TEST_MACHINE_GATE=''
export FM_TEST_SKIP_ORPHAN_REAP=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_TEST_MACHINE_LINE_HELD FM_TEST_MACHINE_LINE_ADMITTED FM_LIVE FM_HARNESS_LIVENESS_DRIFT
printf 'Target commit: %s\n' "$(git rev-parse HEAD)"
printf 'Isolated temporary root: %s\n' "$TMPDIR"
rc=0
bash bin/fm-test-run.sh --jobs 1 --json "$EVIDENCE/runner-timeout.json" tests/.gate-runner-focused.test.sh tests/fm-timeout-lib.test.sh || rc=$?
printf 'TARGETED_RUNNER_TIMEOUT_EXIT=%s\n' "$rc"
exit "$rc"
