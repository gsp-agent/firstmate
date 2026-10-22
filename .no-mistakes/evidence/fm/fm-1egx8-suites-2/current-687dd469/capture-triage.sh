#!/usr/bin/env bash
capture_case() {
  "$CAPTURE_CASE"
  for file in "$TMP_ROOT"/*/watch.out "$TMP_ROOT"/*/state/.wake-queue "$TMP_ROOT"/*/state/.seen-task_status "$TMP_ROOT"/*/state/.watch-triage.log; do
    [ -f "$file" ] || continue
    printf '\nFILE %s\n' "${file#"$TMP_ROOT"/}"
    cat "$file"
  done
}
export FM_TEST_ONLY=capture_case
. "/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5H6NCKQJM2YC31BBNGTSVQQ/tests/fm-watch-triage.test.sh"
