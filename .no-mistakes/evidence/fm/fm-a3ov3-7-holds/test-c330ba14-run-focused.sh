#!/usr/bin/env bash
set -eu
phase_worktree=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7
phase_evidence=/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7
cd "$phase_worktree"
mkdir -p .no-mistakes/test-c330ba14/tmp
export TMPDIR="$phase_worktree/.no-mistakes/test-c330ba14/tmp"
# These existing guards instrument dispatch without running the long case bodies.
env BASH_ENV="$phase_evidence/test-c330ba14-select-cases.bash" \
  FM_TEST_PHASE_CASES='test_captain_hold_lanes_partition_its_cases test_changed_captain_hold_subject_runs_each_case_once test_supervision_host_lanes_partition_its_cases' \
  bash "$phase_worktree/tests/fm-test-run.test.sh"
# Only the nightly-install case whose plist assertions changed at HEAD.
# Its fixture redirects the agent directory and launchctl into TMPDIR.
env BASH_ENV="$phase_evidence/test-c330ba14-select-cases.bash" \
  FM_TEST_PHASE_CASES=test_install_and_uninstall_round_trip \
  bash "$phase_worktree/tests/fm-drift-nightly.test.sh"
