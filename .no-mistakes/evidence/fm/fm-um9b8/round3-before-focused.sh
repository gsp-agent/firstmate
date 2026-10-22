#!/usr/bin/env bash
set -u
. /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5JE8ZBBW8CTJJHBYEAVZSNQ/tests/lib.sh
LINT="$ROOT/bin/fm-lint.sh"
REQUIRED=$("$LINT" --required-version)
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_large_production_roots_fit_default_caps() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): production roots under default caps"
    return
  fi
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-default-caps)
  out=$(
    unset FM_LINT_ROOT_SECONDS FM_LINT_ROOT_GRACE FM_LINT_ROOT_MEMORY_KIB FM_LINT_JOBS
    "$LINT" --telemetry "$tmp/lint.tsv" bin/fm-spawn.sh bin/fm-teardown.sh \
      tests/fm-pending-reply.test.sh tests/fm-launch-prompt-signals-live-e2e.test.sh 2>&1
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "production roots failed at the default caps (exit $rc)"$'\n'"$out"
  awk -F '\t' '
    $1 == "meta" { meta[$2] = $3 }
    $1 == "end" {
      seen[$3]++
      completed++
      if ($5 != "full" || $9 != 0 || $10 != "ok" || $12 != 1) bad = 1
    }
    END {
      exit (bad || completed != 4 ||
        seen["bin/fm-spawn.sh"] != 1 || seen["bin/fm-teardown.sh"] != 1 ||
        seen["tests/fm-pending-reply.test.sh"] != 1 ||
        seen["tests/fm-launch-prompt-signals-live-e2e.test.sh"] != 1 ||
        meta["bounds_enforced"] != 1 || meta["jobs"] != 2 ||
        meta["root_deadline_seconds"] != 300 ||
        meta["root_memory_limit_kib"] != 8388608 || meta["result_exit"] != 0)
    }
  ' "$tmp/lint.roots.tsv" || fail "production roots did not complete full analysis within the default worker caps"
  pass "the heaviest clean roots complete full analysis under the default caps with two workers"
}

save_lint_evidence() {
  local file
  for file in "$FM_TEST_TMPDIR"/fm-lint-default-caps.*/lint*.tsv; do
    [ ! -f "$file" ] || cp "$file" /Users/dalecarman/.no-mistakes/evidence/01M5JE8ZBBW8CTJJHBYEAVZSNQ/round3-before-"${file##*/}"
  done
  fm_test_cleanup
}
trap save_lint_evidence EXIT
test_large_production_roots_fit_default_caps
