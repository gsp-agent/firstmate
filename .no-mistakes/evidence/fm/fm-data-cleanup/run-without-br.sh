#!/usr/bin/env bash
set -u
. "$PWD/tests/lib.sh"
portable=$(fm_test_base_path_sans "$PATH" br) || exit 1
if PATH="$portable" command -v br >/dev/null 2>&1; then
  printf 'error: real br remains visible\n' >&2
  exit 1
fi
printf 'The focused cleanup group runs with no br executable on PATH.\n'
PATH="$portable" FM_TEARDOWN_TEST_GROUP=task-data bin/fm-test-run.sh tests/fm-teardown.test.sh
