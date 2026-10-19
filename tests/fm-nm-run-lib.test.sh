#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-run-lib.sh's bounded runners: the bound kills
# the whole process tree it started, and the no-mistakes specialization runs
# with GIT_NO_LAZY_FETCH=1 so a missing pipeline head never starts a lazy
# fetch in a partial clone.
# shellcheck disable=SC2016 # each bounded bash -c script expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib)

wait_for_file() {  # <path>
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 500 ] || fail "timed out waiting for $1"
    sleep 0.02
  done
}

test_bound_kills_a_child_that_outlives_its_parent() {
  local dir rc=0 pid
  dir="$TMP_ROOT/tree"
  mkdir -p "$dir"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-run-lib.sh"
    fm_nm_bounded "$dir" 1 bash -c '
      ( trap "" TERM; exec sleep 300 ) &
      echo $! > "$1"
      wait
    ' _ "$dir/child.pid"
  ) || rc=$?
  [ "$rc" -eq 124 ] || fail "an expired bound did not report 124 (rc=$rc)"
  wait_for_file "$dir/child.pid"
  pid=$(cat "$dir/child.pid")
  ! kill -0 "$pid" 2>/dev/null \
    || fail "a child that outlived its parent survived the bound (pid=$pid)"
  pass "fm_nm_bounded kills the whole process tree at the bound"
}

test_bound_passes_status_and_output_through() {
  local out rc=0
  out=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-run-lib.sh"
    fm_nm_bounded "$TMP_ROOT" 5 bash -c 'echo to-stdout; exit 7'
  ) || rc=$?
  [ "$rc" -eq 7 ] || fail "the bound did not pass the command's own status through (rc=$rc)"
  [ "$out" = to-stdout ] || fail "the bound lost the command's stdout: $out"
  pass "fm_nm_bounded passes a command's status and output through unchanged"
}

test_no_mistakes_runs_without_lazy_fetch() {
  local dir out
  dir="$TMP_ROOT/no-lazy"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'lazy=%s args=%s\n' "${GIT_NO_LAZY_FETCH-unset}" "$*"
SH
  chmod +x "$dir/bin/no-mistakes"
  out=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-run-lib.sh"
    PATH="$dir/bin:$PATH" fm_nm_run_bounded "$dir" 5 axi status
  ) || fail "the bounded no-mistakes call failed: $out"
  [ "$out" = "lazy=1 args=axi status" ] \
    || fail "no-mistakes did not run with GIT_NO_LAZY_FETCH=1: $out"
  out=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-run-lib.sh"
    PATH="$dir/bin:$PATH" fm_nm_bounded "$dir" 5 no-mistakes axi status
  ) || fail "the generic bounded call failed: $out"
  [ "$out" = "lazy=unset args=axi status" ] \
    || fail "the generic bounded call unexpectedly set GIT_NO_LAZY_FETCH: $out"
  pass "fm_nm_run_bounded sets GIT_NO_LAZY_FETCH=1 only for its no-mistakes call"
}

test_bound_reads_a_heredoc_on_stdin() {
  local out
  out=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-run-lib.sh"
    fm_nm_bounded "$TMP_ROOT" 5 python3 - hello <<'PY'
import sys
print("got:" + sys.argv[1])
PY
  ) || fail "the heredoc-fed bounded call failed: $out"
  [ "$out" = "got:hello" ] || fail "the bound starved a heredoc-fed command: $out"
  pass "fm_nm_bounded keeps a heredoc on the bounded command's stdin"
}

test_bound_kills_a_child_that_outlives_its_parent
test_bound_passes_status_and_output_through
test_no_mistakes_runs_without_lazy_fetch
test_bound_reads_a_heredoc_on_stdin
