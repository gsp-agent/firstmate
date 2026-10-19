# Run only named existing cases after the real subject has defined its helpers.
# This selects test functions; it does not extract source or replace their bodies.
case "$0" in
  */tests/fm-test-run.test.sh|*/tests/fm-drift-nightly.test.sh)
    unset BASH_ENV
    test_phase_select_cases() {
      case "$BASH_COMMAND" in
        test_list_all_exact_suite_coverage|test_unproven_file_is_path_drift_and_exits_1) ;;
        *) return ;;
      esac
      trap - DEBUG
      local test_phase_case
      for test_phase_case in $FM_TEST_PHASE_CASES; do
        printf 'selected-case: %s\n' "$test_phase_case"
        "$test_phase_case" || exit 1
      done
      exit 0
    }
    trap test_phase_select_cases DEBUG
    ;;
esac
