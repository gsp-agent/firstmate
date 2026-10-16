#!/usr/bin/env bash
set -eu
cd /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA
EVIDENCE=/Users/dalecarman/.no-mistakes/evidence/01M53A6E4TERYTKTS6MTXY5YEA
export TMPDIR="$PWD/.queue-validation-tmp"
export FM_TEST_MACHINE_GATE=
# Account-wide orphan cleanup is unrelated to the queue behavior. The probe
# executes that real helper's supported --dry-run mode; no result is stubbed.
export FM_TEST_BASE_PATH="$EVIDENCE/safe-probe:/usr/bin:/bin:/usr/sbin:/sbin"
phase_remaining_boundary_tests() {
  for selector in \
    test_completed_repo_removals_survive_another_repo_failure \
    test_unobserved_merge_preserves_repository_before_cleanup_or_rearm \
    test_retirement_survives_device_renumbering \
    test_retirement_device_recovery_keeps_content_and_inode_checks \
    test_interrupted_template_upgrade_finishes_on_the_next_poll \
    test_progressing_sweep_survives_rearm_past_stall_bound \
    test_slow_registered_polls_survive_rearm; do
    printf 'SELECTOR %s\n' "$selector"
    "$selector"
  done
}
export -f phase_remaining_boundary_tests
export FM_TEST_ONLY=phase_remaining_boundary_tests
bin/fm-test-run.sh tests/fm-pr-check-security.test.sh --per-script-timeout-secs 1200 --json "$EVIDENCE/remaining-tests-timing.json"
