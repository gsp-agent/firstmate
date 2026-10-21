#!/usr/bin/env bash
set -u
run_baseline() {
  SCRIPT="$PWD/.drift-validation/$BASELINE_SCRIPT"
  "$BASELINE_TEST"
}
export FM_TEST_ONLY=run_baseline
. "$PWD/tests/fm-drift-nightly.test.sh"
