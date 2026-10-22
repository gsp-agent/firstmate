#!/usr/bin/env bash
set -u
export EVIDENCE_ROOT=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/current-test
export HOME="$EVIDENCE_ROOT/home" TMPDIR="$EVIDENCE_ROOT/tmp"
for script in working restart runner; do
  case "$script" in
    working) bash "$EVIDENCE_ROOT/triage-driver.sh" test_provably_working_signal_absorbed > "$EVIDENCE_ROOT/test_provably_working_signal_absorbed.log" 2>&1;;
    restart) bash "$EVIDENCE_ROOT/restart-current.sh" > "$EVIDENCE_ROOT/restart-current.log" 2>&1;;
    runner) bash "$EVIDENCE_ROOT/runner-current.sh" > "$EVIDENCE_ROOT/runner-current.log" 2>&1;;
  esac
  printf '%s exit=%s\n' "$script" "$?"
done
