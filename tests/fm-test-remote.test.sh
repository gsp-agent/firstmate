#!/usr/bin/env bash
# Behavior tests for bin/fm-test-remote.sh, the transport that runs one
# Firstmate suite command on another Mac against this checkout's exact commit,
# and for the --remote modes of bin/fm-test-run.sh and
# bin/fm-stock-bash-check.sh that hand their runs to it.
#
# The host is this machine behind a stand-in ssh that, like real ssh, runs the
# command string under a login-style shell (zsh where present) with none of
# the caller's environment: only its own HOME, PATH, and TMPDIR. Each case
# commits a fixture repository holding this checkout's runner files and
# stand-in suites, so a case decides what the host runs. The host's machine
# gate is a stand-in that records each try, except in the arrival-order case,
# which runs the real ~/.agent-state/machine-gate.sh where this machine has
# one and skips elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-remote)
REAL_GATE="$HOME/.agent-state/machine-gate.sh"
GIT_BIN_DIR=$(dirname "$(command -v git)")

# The stand-in ssh: [-n] [-o <option>]... <host> <command words...>.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -n | -T) shift ;;
    -o) shift 2 ;;
    -o*) shift ;;
    *) break ;;
  esac
done
host=$1
shift
case "${FAKE_SSH_FAIL:-}" in
  unreachable) echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255 ;;
  key) echo "$host: Permission denied (publickey)." >&2; exit 255 ;;
esac
shell=/bin/zsh
[ -x "$shell" ] || shell=/bin/bash
# shellcheck disable=SC2086 # FAKE_HOST_ENV is NAME=value words without spaces
exec env -i HOME="$FAKE_HOST_HOME" PATH="$FAKE_HOST_PATH" TMPDIR="$FAKE_HOST_TMP" ${FAKE_HOST_ENV:-} "$shell" -c "$*"
EOF
chmod +x "$TMP_ROOT/bin/ssh"

# The laptop's own gate: taking it at all is the failure these cases look for.
cat >"$TMP_ROOT/bin/laptop-gate.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP_ROOT/laptop-gate.taken"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/laptop-gate.sh"

# A stand-in host gate: records each try and its environment, refuses the
# first <home>/busy-tries tries as a held firstmate line would, then runs the
# command after --.
write_host_gate() {  # <host home>
  mkdir -p "$1/.agent-state"
  cat >"$1/.agent-state/machine-gate.sh" <<'EOF'
#!/usr/bin/env bash
log="$HOME/gate.log"
printf 'try: %s\n' "$*" >>"$log"
printf 'env: MACHINE_LINE_NAME=%s MACHINE_GATE_FIRSTMATE_WAIT=%s NO_MISTAKES_GATE=%s\n' \
  "${MACHINE_LINE_NAME-unset}" "${MACHINE_GATE_FIRSTMATE_WAIT-unset}" "${NO_MISTAKES_GATE-unset}" >>"$log"
tries=$(grep -c '^try: ' "$log")
if [ "$tries" -le "$(cat "$HOME/busy-tries" 2>/dev/null || echo 0)" ]; then
  echo "machine-gate run: NOT STARTED: firstmate is held by a stand-in suite."
  exit 75
fi
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
  chmod +x "$1/.agent-state/machine-gate.sh"
}

# A stand-in suite that reports where and at what commit it ran, and fails
# while tests/probe.fail exists in that copy.
write_probe() {  # <path> <label>
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf 'ok - $2 at %s in %s only=%s\n' "\$(git rev-parse HEAD)" "\$(pwd -P)" "\${FM_TEST_ONLY:-}"
[ ! -e tests/probe.fail ] || { echo "not ok - $2 told to fail"; exit 1; }
EOF
  chmod +x "$1"
}

# new_world <name>: a committed fixture repo, a host home with a stand-in
# gate, and an empty scratch root, all under TMP_ROOT/<name>. Sets REPO,
# SCRATCH, and the host environment the stand-in ssh reads.
new_world() {
  local w="$TMP_ROOT/$1"
  REPO="$w/repo"
  SCRATCH="$w/scratch"
  FAKE_HOST_HOME="$w/host-home"
  FAKE_HOST_TMP="$w/host-tmp"
  FAKE_HOST_PATH="$(dirname "$BASH"):$GIT_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  FAKE_HOST_ENV=
  export FAKE_HOST_HOME FAKE_HOST_TMP FAKE_HOST_PATH FAKE_HOST_ENV
  unset FAKE_SSH_FAIL
  mkdir -p "$REPO/bin" "$REPO/tests" "$SCRATCH" "$FAKE_HOST_TMP"
  write_host_gate "$FAKE_HOST_HOME"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-test-remote.sh" "$ROOT/bin/fm-test-machine-line-lib.sh" \
    "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-stock-bash-check.sh" "$REPO/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$REPO/tests/"
  : >"$REPO/tests/lib.sh"
  write_probe "$REPO/tests/fm-remote-probe.test.sh" probe
  commit_all "fixture"
}

commit_all() {  # <message>
  git -C "$REPO" init -q 2>/dev/null
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "$1"
}

# run_remote <command...>: run in REPO with the stand-ins, capturing combined
# output in OUT and the exit status in RC.
run_remote() {
  OUT=$(cd "$REPO" && env PATH="$TMP_ROOT/bin:$PATH" FM_TEST_REMOTE_BASH="$BASH" \
    FM_TEST_MACHINE_GATE="$TMP_ROOT/bin/laptop-gate.sh" "$@" 2>&1)
  RC=$?
}

assert_scratch_empty() {  # <what>
  local left
  left=$(find "$SCRATCH" -mindepth 1 -maxdepth 1 2>/dev/null)
  [ -z "$left" ] || fail "$1: the host's scratch root still holds $left"$'\n'"$OUT"
}

assert_laptop_line_untouched() {  # <what>
  [ ! -e "$TMP_ROOT/laptop-gate.taken" ] \
    || fail "$1: the laptop's machine gate was taken: $(cat "$TMP_ROOT/laptop-gate.taken")"
}

test_runs_the_suite_on_the_host_at_the_exact_head_and_cleans_up() {
  local head
  new_world exact
  head=$(git -C "$REPO" rev-parse HEAD)
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "a passing suite on the host"$'\n'"$OUT"
  assert_contains "$OUT" "fakehost runs bin/fm-test-run.sh at $head" "the output names the commit under test"
  assert_contains "$OUT" "ok - probe at $head in $SCRATCH/fm-test-remote." "the suite ran in the host's copy at that commit"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=1 failed=0" "the host runner's summary comes back"
  assert_contains "$OUT" "fakehost finished bin/fm-test-run.sh at $head: exit 0" "the output names the result"
  grep -q '^try: run --cap 180 --needs firstmate -- ' "$FAKE_HOST_HOME/gate.log" \
    || fail "the host gate was not asked for firstmate: $(cat "$FAKE_HOST_HOME/gate.log")"
  grep -q '^env: MACHINE_LINE_NAME=fm-test-remote-fm-test-run-.* MACHINE_GATE_FIRSTMATE_WAIT=0 NO_MISTAKES_GATE=unset$' \
    "$FAKE_HOST_HOME/gate.log" || fail "the host gate did not get a named, arrival-logged try: $(cat "$FAKE_HOST_HOME/gate.log")"
  assert_scratch_empty "a finished run"
  assert_laptop_line_untouched "a remote run"
  pass "the runner runs the suite on the host at the exact head, through its gate, and removes the run"
}

test_a_failing_suite_returns_its_exit_status() {
  new_world failing
  : >"$REPO/tests/probe.fail"
  commit_all "fail the probe"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 1 "$RC" "a failing suite on the host"$'\n'"$OUT"
  assert_contains "$OUT" "not ok - probe told to fail" "the failing suite's output comes back"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=1 failed=1" "the summary counts the failure"
  assert_scratch_empty "a failed run"
  pass "a suite that fails on the host fails here with its exit status"
}

test_uncommitted_changes_run_as_a_commit_over_head() {
  local head status_before tested
  new_world dirty
  head=$(git -C "$REPO" rev-parse HEAD)
  write_probe "$REPO/tests/fm-remote-probe.test.sh" edited-probe
  write_probe "$REPO/tests/fm-remote-new.test.sh" new-probe
  status_before=$(git -C "$REPO" status --porcelain --untracked-files=all)
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh tests/fm-remote-new.test.sh
  expect_code 0 "$RC" "a run of uncommitted changes"$'\n'"$OUT"
  assert_contains "$OUT" "ok - edited-probe at " "the host ran the edited suite, not HEAD's"
  assert_contains "$OUT" "ok - new-probe at " "the host ran the untracked new suite"
  assert_contains "$OUT" "HEAD $head plus this checkout's 2 uncommitted paths" "the output names HEAD and the uncommitted changes"
  tested=$(printf '%s\n' "$OUT" | sed -n 's/^ok - edited-probe at \([0-9a-f]*\) in .*/\1/p')
  [ "$(git -C "$REPO" rev-parse "$tested^")" = "$head" ] \
    || fail "the commit the host ran ($tested) is not a child of HEAD $head"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ] || fail "HEAD moved"
  [ "$(git -C "$REPO" status --porcelain --untracked-files=all)" = "$status_before" ] \
    || fail "the checkout's index or working tree changed: $(git -C "$REPO" status --porcelain)"
  assert_scratch_empty "a run of uncommitted changes"
  pass "uncommitted and untracked changes run on the host as one commit over HEAD, leaving the checkout as it was"
}

test_changed_base_and_json_cross_the_transport() {
  local json="$TMP_ROOT/changed-json/timing.json"
  new_world changed
  git -C "$REPO" branch fixture-base
  write_probe "$REPO/tests/fm-remote-probe.test.sh" changed-probe
  commit_all "change the probe"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --changed --base fixture-base --json "$json"
  expect_code 0 "$RC" "a --changed run on the host"$'\n'"$OUT"
  assert_contains "$OUT" "ok - changed-probe at " "the host selected the suite changed since the base it was sent"
  [ -s "$json" ] || fail "the timing artifact was not copied back to $json"$'\n'"$OUT"
  grep -q '"tests/fm-remote-probe.test.sh"' "$json" || fail "the copied-back artifact does not record the suite: $(cat "$json")"
  assert_scratch_empty "a --changed run"
  pass "--changed's base and --json's artifact cross to the host and back"
}

test_fm_test_only_reaches_the_host() {
  new_world only
  run_remote env FM_TEST_ONLY=test_one bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "a focused run on the host"$'\n'"$OUT"
  assert_contains "$OUT" "only=test_one" "FM_TEST_ONLY narrows the run on the host"
  pass "FM_TEST_ONLY reaches the host run"
}

test_a_busy_host_gate_is_a_wait_not_a_failure() {
  new_world busy
  echo 3 >"$FAKE_HOST_HOME/busy-tries"
  run_remote env FM_TEST_REMOTE_RETRY_SECS=0.2 bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "a run that waited on the host's gate"$'\n'"$OUT"
  [ "$(grep -c '^try: ' "$FAKE_HOST_HOME/gate.log")" -eq 4 ] \
    || fail "expected three refused tries and one admitted: $(cat "$FAKE_HOST_HOME/gate.log")"
  [ "$(printf '%s\n' "$OUT" | grep -c 'waiting on .*firstmate is held by a stand-in suite')" -eq 1 ] \
    || fail "an unchanged wait should be said once"$'\n'"$OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c '^ok - probe at ')" -eq 1 ] || fail "the suite should run exactly once"$'\n'"$OUT"
  assert_contains "$OUT" "in its machine gate's line" "the output says when the host started it"
  pass "a busy host gate is waited out, said once, and the suite then runs once"
}

test_transport_failures_stop_before_anything_runs() {
  new_world refused
  export FAKE_SSH_FAIL=unreachable
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "an unreachable host"$'\n'"$OUT"
  assert_contains "$OUT" "cannot reach fakehost over ssh (ssh: connect to host fakehost port 22: Connection refused); nothing ran" \
    "an unreachable host is named"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran anywhere for an unreachable host"

  export FAKE_SSH_FAIL=key
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "a refused key"$'\n'"$OUT"
  assert_contains "$OUT" "fakehost refused this account's ssh key" "a refused key is named as one"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran anywhere for a refused key"
  unset FAKE_SSH_FAIL

  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH/unmounted" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "a missing scratch root"$'\n'"$OUT"
  assert_contains "$OUT" "scratch root $SCRATCH/unmounted does not exist on this host" "a missing scratch root is named"
  [ ! -e "$SCRATCH/unmounted" ] || fail "the missing scratch root was created"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran anywhere for a missing scratch root"

  rm -f "$FAKE_HOST_HOME/.agent-state/machine-gate.sh"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "a host with no machine gate"$'\n'"$OUT"
  assert_contains "$OUT" "has no machine gate at $FAKE_HOST_HOME/.agent-state/machine-gate.sh" "a missing host gate is named"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran without the host's gate"
  assert_scratch_empty "a run refused for a missing gate"
  assert_laptop_line_untouched "a refused remote run"
  pass "an unreachable host, a refused key, a missing scratch root, and a missing host gate each stop before any suite runs"
}

test_a_host_copy_at_another_commit_runs_nothing() {
  local head
  new_world mismatch
  head=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$TMP_ROOT/mismatch/host-bin"
  cat >"$TMP_ROOT/mismatch/host-bin/git" <<EOF
#!/bin/sh
if [ "\$1" = rev-parse ] && [ "\$2" = HEAD ]; then echo 0000000000000000000000000000000000000000; exit 0; fi
exec "$GIT_BIN_DIR/git" "\$@"
EOF
  chmod +x "$TMP_ROOT/mismatch/host-bin/git"
  FAKE_HOST_PATH="$TMP_ROOT/mismatch/host-bin:$FAKE_HOST_PATH"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "a host copy at the wrong commit"$'\n'"$OUT"
  assert_contains "$OUT" "the host copy is at 0000000000000000000000000000000000000000, not $head; nothing ran" \
    "a rev-parse mismatch is named"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran on a mismatched copy"
  [ ! -e "$FAKE_HOST_HOME/gate.log" ] || fail "the host gate was asked for a mismatched copy"
  assert_scratch_empty "a mismatched run"
  pass "a host copy whose rev-parse is not the commit under test runs nothing"
}

test_inspection_modes_run_here() {
  new_world inspect
  export FAKE_SSH_FAIL=unreachable
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --list tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "--list with --remote"$'\n'"$OUT"
  [ "$OUT" = tests/fm-remote-probe.test.sh ] || fail "--list should print the selection here: $OUT"
  unset FAKE_SSH_FAIL
  pass "inspection modes run here and ignore --remote"
}

test_stock_bash_check_runs_on_the_host() {
  local head stock_ok=0 suite count tools
  new_world stock
  case "$(/bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in 3.2.57*) stock_ok=1 ;; esac
  cat >"$REPO/bin/fm-lint.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --list-files ] || exit 2
printf '%s\n' bin/fm-stock-bash-check.sh bin/fm-timeout-lib.sh
EOF
  chmod +x "$REPO/bin/fm-lint.sh"
  for suite in fm-fleet-snapshot-view:19 fm-bearings-snapshot:62 fm-public-followup:1 fm-watch-triage:1 \
    fm-fork-free-helpers:16 fm-backend:2; do
    count=${suite#*:}
    # shellcheck disable=SC2016 # the stand-in suite expands its own variables
    printf '#!/usr/bin/env bash\ni=0\nwhile [ "$i" -lt %s ]; do i=$((i + 1)); echo "ok - stand-in $i"; done\n' \
      "$count" >"$REPO/tests/${suite%%:*}.test.sh"
  done
  commit_all "stand-in stock suites"
  head=$(git -C "$REPO" rev-parse HEAD)
  tools="$TMP_ROOT/stock/host-tools"
  mkdir -p "$tools"
  for suite in jq tasks-axi; do
    printf '#!/bin/sh\nexit 0\n' >"$tools/$suite"
    chmod +x "$tools/$suite"
  done
  FAKE_HOST_PATH="$FAKE_HOST_PATH:$tools"
  run_remote bin/fm-stock-bash-check.sh --remote "fakehost:$SCRATCH"
  assert_contains "$OUT" "fakehost runs bin/fm-stock-bash-check.sh at $head" "the check names the commit it ran"
  if [ "$stock_ok" -eq 1 ]; then
    expect_code 0 "$RC" "the stock Bash check on the host"$'\n'"$OUT"
    assert_contains "$OUT" "every stock Bash 3.2.57" "the host's check verdict comes back"
  else
    expect_code 2 "$RC" "the stock Bash check on a host without Bash 3.2.57"$'\n'"$OUT"
    assert_contains "$OUT" "expected stock macOS Bash 3.2.57 at /bin/bash" "the host's refusal comes back"
  fi
  assert_scratch_empty "a remote stock Bash check"
  pass "fm-stock-bash-check.sh --remote runs the check on the host and returns its verdict"
}

# Two runs queue on the real gate's held firstmate line; the later arrival
# retries far faster, and still the earlier arrival starts first.
test_waiters_start_in_arrival_order_on_the_real_gate() {
  local line_dir log pid_a pid_b first tries_a tries_b
  if [ ! -x "$REAL_GATE" ] || [ ! -x /usr/bin/lockf ]; then
    pass "waiters start in arrival order on the real gate (skipped: no ~/.agent-state/machine-gate.sh or lockf here)"
    return 0
  fi
  new_world order
  ln -sf "$REAL_GATE" "$FAKE_HOST_HOME/.agent-state/machine-gate.sh"
  line_dir="$FAKE_HOST_HOME/.agent-state/machine-line"
  log="$line_dir/log.tsv"
  mkdir -p "$line_dir"
  printf '#!/bin/sh\necho "SLOT FREE = YES"\n' >"$TMP_ROOT/order/read.sh"
  chmod +x "$TMP_ROOT/order/read.sh"
  FAKE_HOST_ENV="MACHINE_GATE_READ=$TMP_ROOT/order/read.sh"
  /usr/bin/lockf -k "$line_dir/firstmate.lock" /bin/sh -c \
    "while [ ! -e '$TMP_ROOT/order/release' ] && [ -d '$TMP_ROOT' ]; do sleep 0.1; done" &
  for _ in $(seq 1 100); do
    [ -e "$line_dir/firstmate.lock" ] && break
    sleep 0.1
  done
  (cd "$REPO" && exec env PATH="$TMP_ROOT/bin:$PATH" FM_TEST_REMOTE_BASH="$BASH" FM_TEST_REMOTE_RETRY_SECS=2 \
    bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh) >"$TMP_ROOT/order/a.out" 2>&1 &
  pid_a=$!
  for _ in $(seq 1 300); do
    grep -q "fm-test-remote-fm-test-run-.*-$pid_a	on firstmate" "$log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- "-$pid_a	on firstmate" "$log" || fail "the first run never queued: $(cat "$log" 2>/dev/null)"
  (cd "$REPO" && exec env PATH="$TMP_ROOT/bin:$PATH" FM_TEST_REMOTE_BASH="$BASH" FM_TEST_REMOTE_RETRY_SECS=0.3 \
    bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh) >"$TMP_ROOT/order/b.out" 2>&1 &
  pid_b=$!
  for _ in $(seq 1 300); do
    [ "$(grep -c -- "-$pid_b	on firstmate" "$log")" -ge 3 ] && break
    sleep 0.1
  done
  : >"$TMP_ROOT/order/release"
  wait "$pid_a" || fail "the first run failed: $(cat "$TMP_ROOT/order/a.out")"
  wait "$pid_b" || fail "the second run failed: $(cat "$TMP_ROOT/order/b.out")"
  first=$(awk -F '\t' '$2 == "start" { print $3; exit }' "$log")
  tries_a=$(grep -c -- "-$pid_a	" "$log")
  tries_b=$(grep -c -- "-$pid_b	" "$log")
  [ "$tries_b" -gt "$tries_a" ] \
    || fail "the later run should have asked more often ($tries_b tries against $tries_a), or order proves nothing: $(cat "$log")"
  case "$first" in
    *"-$pid_a") ;;
    *) fail "the later arrival started first ($first): $(cat "$log")" ;;
  esac
  pass "on the real gate the earlier waiter starts first, though the later one asked $tries_b times to its $tries_a"
}

test_runs_the_suite_on_the_host_at_the_exact_head_and_cleans_up
test_a_failing_suite_returns_its_exit_status
test_uncommitted_changes_run_as_a_commit_over_head
test_changed_base_and_json_cross_the_transport
test_fm_test_only_reaches_the_host
test_a_busy_host_gate_is_a_wait_not_a_failure
test_transport_failures_stop_before_anything_runs
test_a_host_copy_at_another_commit_runs_nothing
test_inspection_modes_run_here
test_stock_bash_check_runs_on_the_host
test_waiters_start_in_arrival_order_on_the_real_gate
