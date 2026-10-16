#!/usr/bin/env bash
set -eu
cd /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA
export TMPDIR="$PWD/.queue-validation-tmp"
export FM_TEST_MACHINE_GATE=
export BASELINE_WATCH="$TMPDIR/before-r37/bin/fm-watch.sh"
mkdir -p "$TMPDIR/before-r37"
cp -R bin "$TMPDIR/before-r37/bin"
git show '541af659^:bin/fm-watch.sh' > "$BASELINE_WATCH"
phase_before_r37() {
  WATCH="$BASELINE_WATCH"
  test_sweep_repos_added_after_startup_stay_separate
}
export -f phase_before_r37
export FM_TEST_ONLY=phase_before_r37
bin/fm-test-run.sh tests/fm-pr-check-security.test.sh --per-script-timeout-secs 240
