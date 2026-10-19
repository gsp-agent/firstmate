#!/usr/bin/env bash
set -u
PHASE_ROOT="$PWD/.agent-state/drift-test-phase"
EVIDENCE_ROOT=/Users/dalecarman/.no-mistakes/evidence/01M5999CSVGBG7SM5134TYA5NC
mkdir -p "$PHASE_ROOT/tmp" "$EVIDENCE_ROOT"
export TMPDIR="$PHASE_ROOT/tmp"
bin/fm-test-run.sh tests/fm-drift-nightly.test.sh tests/fm-cursor-guard.test.sh tests/fm-task-delivery.test.sh tests/fm-self-repo-role.test.sh --per-script-timeout-secs 300 --json "$EVIDENCE_ROOT/targeted-tests.json" > "$EVIDENCE_ROOT/targeted-tests.log" 2>&1
rc=$?
cat "$EVIDENCE_ROOT/targeted-tests.log"
exit "$rc"
