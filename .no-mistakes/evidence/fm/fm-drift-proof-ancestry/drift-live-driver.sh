#!/usr/bin/env bash
set -u
run_selected_tests() {
  run_check() {
    local repo=$1
    shift
    CHECK_RC=0
    CHECK_OUT=$("$SCRIPT" check --no-fetch --repo "$repo" "$@" 2>"$repo.err") || CHECK_RC=$?
    CHECK_ERR=$(cat "$repo.err")
    printf '\n$ fm-drift-nightly.sh check --no-fetch --repo %q ' "$repo"
    printf '%q ' "$@"
    printf '\n%s\n' "$CHECK_OUT"
    [ -z "$CHECK_ERR" ] || printf 'stderr: %s\n' "$CHECK_ERR"
    printf 'observed exit: %s\n' "$CHECK_RC"
  }
  run_nightly() {
    NIGHTLY_RC=0
    FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" FM_DATA_OVERRIDE="$1/home/data" \
      "$SCRIPT" nightly --repo "$1/repo" --log "$1/drift.log" >> "$1/drift.log" 2>&1 || NIGHTLY_RC=$?
    printf '\n$ fm-drift-nightly.sh nightly --repo %q --log %q\n' "$1/repo" "$1/drift.log"
    cat "$1/drift.log"
    printf 'observed nightly exit: %s\n' "$NIGHTLY_RC"
    local note
    for note in "$1/home/state/inbox/"*.note; do
      [ -f "$note" ] || continue
      printf 'Persisted notification:\n'
      cat "$note"
    done
  }
  local selected
  for selected in \
    test_squash_merged_branch_carries_its_own_manifest_line \
    test_merge_merged_branch_carries_its_own_pending_line \
    test_pending_commit_is_accepted_and_printed_with_its_bead \
    test_proven_patches_are_replayed_in_ancestry_order \
    test_default_proof_comes_from_the_committed_fork_tree \
    test_guard_files_have_no_exemptions \
    test_unproven_edit_to_proven_file_exits_1 \
    test_unproven_deletion_cannot_rename_into_proven_file \
    test_proven_commit_does_not_accept_earlier_unproven_content \
    test_cut_unproven_changes_do_not_fail_after_restoration \
    test_proven_change_can_also_cut_unproven_changes \
    test_missing_proven_patch_is_drift \
    test_unproven_mode_change_is_drift \
    test_forgotten_manifest_line_is_path_drift_and_unproven \
    test_wrong_proof_pr_number_stays_red_and_is_named \
    test_reverted_numbered_pr_without_manifest_stays_red \
    test_open_pr_own_line_is_unmatched_until_its_squash_lands \
    test_snapshot_includes_fetched_upstream \
    test_behind_count_is_reported_and_does_not_fail_alone \
    test_nightly_red_sends_one_note_a_day_and_green_sends_none \
    test_nightly_check_error_is_red \
    test_nightly_note_names_at_most_ten_red_lines; do
    printf '\nSCENARIO: %s\n' "$selected"
    "$selected"
  done
}
export FM_TEST_ONLY=run_selected_tests
. "$PWD/tests/fm-drift-nightly.test.sh"
