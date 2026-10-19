#!/usr/bin/env bash
set -u
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW
cd "$ROOT" || exit 2
export TMPDIR="$ROOT/.gate-test-phase/scratch"
export HOME="$ROOT/.gate-test-phase/user-home"
export CLAUDE_CONFIG_DIR=''
export FM_HOME="$ROOT/.gate-test-phase/fm-home"
export FM_TEST_MACHINE_GATE='' FM_TEST_SKIP_ORPHAN_REAP=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_TEST_MACHINE_LINE_HELD FM_TEST_MACHINE_LINE_ADMITTED FM_LIVE FM_HARNESS_LIVENESS_DRIFT
rc=0
bash bin/fm-test-run.sh --jobs 1 --json "$EVIDENCE/watcher-sandbox-isolated.json" tests/.gate-wake-sandbox.test.sh tests/fm-harness-liveness-drift-live-e2e.test.sh || rc=$?
printf 'WATCHER_FOCUSED_EXIT=%s\n' "$rc"
exit "$rc"
