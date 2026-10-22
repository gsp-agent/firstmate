#!/usr/bin/env bash
set -u
export EVIDENCE_ROOT=/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/current-test
export HOME="$EVIDENCE_ROOT/home" TMPDIR="$EVIDENCE_ROOT/tmp"
rc=0
for scenario in test_provably_working_signal_absorbed test_working_note_not_working_surfaced test_check_sweep_reprobes_captain_holds; do
  bash "$EVIDENCE_ROOT/triage-driver.sh" "$scenario" > "$EVIDENCE_ROOT/$scenario.log" 2>&1
  result=$?
  printf '%s exit=%s\n' "$scenario" "$result"
  [ "$result" = 0 ] || rc=1
done
bash tests/fm-test-isolation-proof.test.sh > "$EVIDENCE_ROOT/proof-suite.log" 2>&1
result=$?
printf 'isolation-proof exit=%s\n' "$result"
[ "$result" = 0 ] || rc=1
exit "$rc"
