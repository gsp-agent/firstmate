#!/usr/bin/env bash
set -u
. ./tests/lib.sh
fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -n "${case_dir:-}" ]; then
    for diagnostic in "$case_dir/stderr" "$case_dir/stdout" "$case_dir/err" "$case_dir/out" "$case_dir/data/task-x1/record/data-cleanup.json"; do
      if [ -f "$diagnostic" ]; then
        printf 'Diagnostic from %s\n' "$diagnostic" >&2
        cat "$diagnostic" >&2
      fi
    done
  fi
  exit 1
}
. ./tests/fm-teardown.test.sh
