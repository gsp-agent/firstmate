#!/usr/bin/env bash
# Behavior tests for bin/fm-stock-bash-check.sh, the stock macOS Bash 3.2
# check the no-mistakes stock-macos-bash gate runs before push.
#
# Each case copies the script and bin/fm-timeout-lib.sh into a fixture repo
# whose bin/fm-lint.sh and regression suites are stand-ins, so a case decides
# exactly what the parse sweep sees and how many tests each suite passes.
# The refusal case runs everywhere. The cases that need a real Bash 3.2.57
# run only where /bin/bash is one (stock macOS) and print a skip note
# elsewhere: a fake 3.2 interpreter would only prove the fake.
# shellcheck disable=SC2016 # stand-in scripts expand their own variables
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stock-bash-check)

# Stand-in jq and tasks-axi: the check requires both on PATH but never runs
# them itself; the real suites that need them are replaced here.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
for tool in jq tasks-axi; do
  printf '#!/bin/sh\nexit 0\n' > "$TOOLS/$tool"
  chmod +x "$TOOLS/$tool"
done

# write_suite <path> <count>: a stand-in suite that passes <count> tests.
write_suite() {
  local path=$1 count=$2
  printf '#!/usr/bin/env bash\ni=0\nwhile [ "$i" -lt %s ]; do\n  i=$((i + 1))\n  echo "ok - stand-in $i"\ndone\n' \
    "$count" > "$path"
}

# make_fixture <dir>: a repo where every check passes under stock Bash 3.2.
# Its suite counts are the script's expected counts.
make_fixture() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-stock-bash-check.sh" "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  cat > "$repo/bin/fm-lint.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --list-files ] || exit 2
printf '%s\n' bin/fm-stock-bash-check.sh bin/fm-timeout-lib.sh
[ ! -f tests/extra-parse-target.sh ] || printf '%s\n' tests/extra-parse-target.sh
EOF
  chmod +x "$repo/bin/fm-lint.sh"
  write_suite "$repo/tests/fm-fleet-snapshot-view.test.sh" 19
  write_suite "$repo/tests/fm-bearings-snapshot.test.sh" 62
  write_suite "$repo/tests/fm-public-followup.test.sh" 1
  write_suite "$repo/tests/fm-watch-triage.test.sh" 1
  write_suite "$repo/tests/fm-fork-free-helpers.test.sh" 19
  write_suite "$repo/tests/fm-backend.test.sh" 2
}

# run_check <repo> [NAME=value...]: run the fixture's check, capturing
# combined output in OUT and the exit status in RC.
run_check() {
  local repo=$1
  shift
  OUT=$(env PATH="$TOOLS:$PATH" "$@" "$repo/bin/fm-stock-bash-check.sh" 2>&1)
  RC=$?
}

STOCK_OK=0
case "$(/bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in
  3.2.57*) STOCK_OK=1 ;;
esac

stock_only() {  # <case name>
  [ "$STOCK_OK" -eq 1 ] && return 0
  pass "$1 (skipped: needs /bin/bash 3.2.57, the stock macOS shell)"
  return 1
}

test_refuses_an_interpreter_that_is_not_stock_bash() {
  local repo="$TMP_ROOT/refuse" fake="$TMP_ROOT/bash5/bash"
  make_fixture "$repo"
  mkdir -p "$(dirname "$fake")"
  printf '#!/bin/sh\nprintf 5.2.37\n' > "$fake"
  chmod +x "$fake"
  run_check "$repo" FM_STOCK_BASH="$fake"
  expect_code 2 "$RC" "a non-3.2 interpreter"
  assert_contains "$OUT" "expected stock macOS Bash 3.2.57" "the refusal names the required version"
  assert_not_contains "$OUT" "ok - " "no step runs on a refused host"
  pass "refuses to run, and so cannot pass, without stock Bash 3.2.57"
}

test_help_prints_the_whole_header() {
  local rc
  OUT=$("$ROOT/bin/fm-stock-bash-check.sh" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$OUT" "FM_STOCK_BASH_LOAD_FACTOR" "--help documents the load factor override"
  assert_contains "$OUT" "Exit status: 0 every step passed" "--help documents the exit status"
  assert_equals "  fm-stock-bash-check.sh --help   print this usage" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "--help ends with the usage block's last line"
  pass "--help prints the whole header through its usage lines"
}

test_passes_when_every_check_passes() {
  stock_only "every passing step yields exit 0" || return 0
  local repo="$TMP_ROOT/pass"
  make_fixture "$repo"
  run_check "$repo"
  expect_code 0 "$RC" "an all-green fixture"$'\n'"$OUT"
  assert_contains "$OUT" "ok - parse-sweep: 2 files parse" "the parse sweep covers the listed files"
  assert_contains "$OUT" "every stock Bash 3.2.57" "the summary reports the pass"
  pass "every passing step yields exit 0"
}

test_a_bash4_only_construct_fails_the_parse_sweep() {
  stock_only "a Bash-4-only construct fails the parse sweep naming its file" || return 0
  local repo="$TMP_ROOT/parse"
  make_fixture "$repo"
  # `;&` case fall-through arrived in Bash 4.0; Bash 3.2 rejects it at parse time.
  printf 'case x in\n  x) echo one ;&\n  y) echo two ;;\nesac\n' > "$repo/tests/extra-parse-target.sh"
  run_check "$repo"
  expect_code 1 "$RC" "a Bash-4-only parse target"
  assert_contains "$OUT" "stock Bash failed to parse tests/extra-parse-target.sh" "the failure names the file"
  assert_contains "$OUT" "FAIL parse-sweep" "the parse sweep step fails"
  pass "a Bash-4-only construct fails the parse sweep naming its file"
}

test_a_count_mismatch_fails_naming_the_suite() {
  stock_only "a suite short of its expected count fails naming the suite" || return 0
  local repo="$TMP_ROOT/count"
  make_fixture "$repo"
  write_suite "$repo/tests/fm-bearings-snapshot.test.sh" 59
  run_check "$repo"
  expect_code 1 "$RC" "a short suite"
  assert_contains "$OUT" "bearings: expected 62 passing tests from tests/fm-bearings-snapshot.test.sh, got 59" \
    "the failure names the suite and both counts"
  assert_contains "$OUT" "backend-adapter-file: " "later steps still run after a failure"
  pass "a suite short of its expected count fails naming the suite"
}

test_the_memory_cap_stops_a_growing_step() {
  stock_only "a step past the memory cap is stopped and fails naming the cap" || return 0
  local repo="$TMP_ROOT/memory" started elapsed
  make_fixture "$repo"
  printf '#!/usr/bin/env bash\nexec perl -e '"'"'$x = "a" x (256 * 1024 * 1024); sleep 120'"'"'\n' \
    > "$repo/tests/fm-fleet-snapshot-view.test.sh"
  started=$(date +%s)
  run_check "$repo" FM_STOCK_BASH_RSS_KIB=65536
  elapsed=$(($(date +%s) - started))
  expect_code 1 "$RC" "a step past the memory cap"
  assert_contains "$OUT" "snapshot-view: stopped at the 65536 KiB process-tree memory cap" "the failure names the cap"
  [ "$elapsed" -lt 90 ] || fail "the memory cap took ${elapsed}s to stop a step sleeping 120s"
  pass "a step past the memory cap is stopped and fails naming the cap"
}

test_a_failed_process_list_fails_the_step() {
  stock_only "a failed process list fails the step instead of reporting 0 KiB" || return 0
  local repo="$TMP_ROOT/badps" stub="$TMP_ROOT/badps-bin"
  make_fixture "$repo"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/ps"
  chmod +x "$stub/ps"
  run_check "$repo" PATH="$stub:$TOOLS:$PATH"
  expect_code 1 "$RC" "a failed process list"$'\n'"$OUT"
  assert_contains "$OUT" "process list could not be read, so the 2097152 KiB tree cap was not enforced" \
    "the failure names the unread process list"
  assert_not_contains "$OUT" "every stock Bash" "a failed read is not a pass"
  pass "a failed process list fails the step instead of reporting 0 KiB"
}

test_the_wall_bound_stops_a_hung_step() {
  stock_only "a step past the wall bound is stopped and fails naming the bound" || return 0
  local repo="$TMP_ROOT/time" started elapsed
  make_fixture "$repo"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$repo/tests/fm-fork-free-helpers.test.sh"
  started=$(date +%s)
  run_check "$repo" FM_STOCK_BASH_STEP_SECONDS=3 FM_STOCK_BASH_LOAD_FACTOR=1
  elapsed=$(($(date +%s) - started))
  expect_code 1 "$RC" "a step past the wall bound"
  assert_contains "$OUT" "fork-free-helpers: stopped at the 3s wall bound" "the failure names the bound"
  [ "$elapsed" -lt 90 ] || fail "the wall bound took ${elapsed}s to stop a step sleeping 120s"
  pass "a step past the wall bound is stopped and fails naming the bound"
}

test_the_wall_bound_grows_with_load_and_still_stops_a_hang() {
  stock_only "the wall bound grows with load and still stops a hung step" || return 0
  local repo="$TMP_ROOT/time-load" started elapsed
  make_fixture "$repo"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$repo/tests/fm-fork-free-helpers.test.sh"
  started=$(date +%s)
  run_check "$repo" FM_STOCK_BASH_STEP_SECONDS=3 FM_STOCK_BASH_LOAD_FACTOR=3
  elapsed=$(($(date +%s) - started))
  expect_code 1 "$RC" "a step past the load-grown wall bound"
  assert_contains "$OUT" "fork-free-helpers: stopped at the 9s wall bound (load factor 3 times 3s at idle load)" \
    "the failure names the grown bound, its load factor, and the idle bound"
  [ "$elapsed" -ge 6 ] || fail "the load-grown wall stopped a hung step after only ${elapsed}s"
  [ "$elapsed" -lt 90 ] || fail "the load-grown wall took ${elapsed}s to stop a step sleeping 120s"
  pass "the wall bound grows with load and still stops a hung step"
}

test_a_load_rise_mid_step_grows_the_wall_for_the_rest_of_the_step() {
  stock_only "a load rise mid-step grows the wall for the rest of the step" || return 0
  local repo="$TMP_ROOT/time-rise" stub="$TMP_ROOT/time-rise-bin" load="$TMP_ROOT/time-rise-load" started elapsed
  make_fixture "$repo"
  mkdir -p "$stub"
  printf '0.50\n' > "$load"
  # A stand-in sysctl: one CPU, the load average in $FM_TEST_LOAD, and a
  # marker once it has reported the raised load.
  cat > "$stub/sysctl" <<'EOF2'
#!/bin/sh
[ "$2" = hw.ncpu ] && { echo 1; exit 0; }
read -r load < "$FM_TEST_LOAD"
[ "$load" != 50.00 ] || : > "$FM_TEST_LOAD.seen"
printf '{ %s 0.00 0.00 }\n' "$load"
EOF2
  chmod +x "$stub/sysctl"
  # The step starts at factor 1 (a 3s wall), raises the load to factor 6,
  # drops it back once the check has read it, then outlives the 3s wall.
  cat > "$repo/tests/fm-fork-free-helpers.test.sh" <<'EOF2'
#!/usr/bin/env bash
printf '50.00\n' > "$FM_TEST_LOAD"
while [ ! -e "$FM_TEST_LOAD.seen" ]; do sleep 0.1; done
printf '0.50\n' > "$FM_TEST_LOAD"
sleep 5
i=0
while [ "$i" -lt 19 ]; do
  i=$((i + 1))
  echo "ok - stand-in $i"
done
EOF2
  started=$(date +%s)
  run_check "$repo" PATH="$stub:$TOOLS:$PATH" FM_STOCK_BASH_STEP_SECONDS=3 FM_TEST_LOAD="$load"
  elapsed=$(($(date +%s) - started))
  expect_code 0 "$RC" "a step that outlives its starting wall after load rose"$'\n'"$OUT"
  assert_not_contains "$OUT" "FAIL fork-free-helpers" "the step is not stopped at its starting wall"
  printf '%s\n' "$OUT" | grep -q '^fork-free-helpers: [0-9]*s, load factor 6, ' \
    || fail "the step reports the highest load factor it ran under"$'\n'"$OUT"
  [ "$elapsed" -ge 5 ] || fail "the rising-load step finished after only ${elapsed}s"
  pass "a load rise mid-step grows the wall for the rest of the step"
}

test_refuses_an_interpreter_that_is_not_stock_bash
test_help_prints_the_whole_header
test_passes_when_every_check_passes
test_a_bash4_only_construct_fails_the_parse_sweep
test_a_count_mismatch_fails_naming_the_suite
test_the_memory_cap_stops_a_growing_step
test_a_failed_process_list_fails_the_step
test_the_wall_bound_stops_a_hung_step
test_the_wall_bound_grows_with_load_and_still_stops_a_hang
test_a_load_rise_mid_step_grows_the_wall_for_the_rest_of_the_step
