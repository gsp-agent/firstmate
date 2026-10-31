#!/usr/bin/env bash
# Behavior tests for bin/fm-test-remote.sh, the transport that runs one
# Firstmate suite command on another Mac against this checkout's exact commit,
# and for the --remote modes of bin/fm-test-run.sh and
# bin/fm-stock-bash-check.sh that hand their runs to it.
#
# The host is this machine behind a stand-in ssh that, like real ssh, runs the
# command string under the account's shell (zsh where present) with none of the
# caller's environment: only its own HOME, SHELL, a minimal PATH, and TMPDIR.
# The host's tools are on PATH only in that shell's login environment. Each case
# commits a fixture repository holding this checkout's runner files and
# stand-in suites, so a case decides what the host runs. The host's machine
# gate is a stand-in that records each try, except in the two arrival-order
# cases, which run the real ~/.agent-state/machine-gate.sh where this machine
# has one and skip elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for var in $(compgen -e | grep -E '^FM_([A-Z0-9_]+_)?(LIVE|E2E|REAL)(_|$)'); do
  unset "$var"
done
TMP_ROOT=$(fm_test_tmproot fm-test-remote)
REAL_GATE="$HOME/.agent-state/machine-gate.sh"
GIT_BIN_DIR=$(dirname "$(command -v git)")

# The stand-in ssh: [-n] [-o <option>]... <host> <command words...>.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
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
  pull) case "$*" in "cat -- "*) echo "Connection to $host closed by remote host." >&2; exit 255 ;; esac ;;
  run) case "$*" in *__host*) echo "Connection to $host closed by remote host." >&2; exit 255 ;; esac ;;
esac
shell=/bin/zsh
[ -x "$shell" ] || shell=/bin/bash
# shellcheck disable=SC2086 # FAKE_HOST_ENV is NAME=value words without spaces
exec env -i HOME="$FAKE_HOST_HOME" SHELL="$shell" PATH="$FAKE_NONLOGIN_PATH" FAKE_LOGIN_PATH="$FAKE_HOST_PATH" \
  TMPDIR="$FAKE_HOST_TMP" ${FAKE_HOST_ENV:-} "$shell" -c "$*"
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
printf 'ok - $2 at %s in %s only=%s tmp=%s\n' "\$(git rev-parse HEAD)" "\$(pwd -P)" "\${FM_TEST_ONLY:-}" "\${TMPDIR:-}"
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
  FAKE_NONLOGIN_PATH="$GIT_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  FAKE_SSH_LOG="$w/ssh.log"
  export FAKE_HOST_HOME FAKE_HOST_TMP FAKE_HOST_PATH FAKE_NONLOGIN_PATH FAKE_HOST_ENV FAKE_SSH_LOG
  unset FAKE_SSH_FAIL
  mkdir -p "$REPO/bin" "$REPO/tests" "$SCRATCH" "$FAKE_HOST_TMP"
  write_host_gate "$FAKE_HOST_HOME"
  # shellcheck disable=SC2016 # the host's login shell expands this
  printf 'PATH=$FAKE_LOGIN_PATH\nexport PATH\n' | tee "$FAKE_HOST_HOME/.zprofile" >"$FAKE_HOST_HOME/.bash_profile"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-test-remote.sh" "$ROOT/bin/fm-test-machine-line-lib.sh" \
    "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-stock-bash-check.sh" "$REPO/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/remote-permitted-skips.txt" "$REPO/tests/"
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
  printf '%s\n' "$OUT" | grep -q "^ok - probe at $head in $SCRATCH/fm-test-remote\\.[^/]*/repo only= tmp=$SCRATCH/fm-test-remote\\.[^/]*/tmp\$" \
    || fail "the suite's TMPDIR is not the run's tmp/ on the scratch volume"$'\n'"$OUT"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=1 failed=0" "the host runner's summary comes back"
  assert_contains "$OUT" "fakehost finished bin/fm-test-run.sh at $head: exit 0" "the output names the result"
  grep -q '^try: run --cap 180 --needs firstmate -- ' "$FAKE_HOST_HOME/gate.log" \
    || fail "the host gate was not asked for firstmate: $(cat "$FAKE_HOST_HOME/gate.log")"
  grep -q '^env: MACHINE_LINE_NAME=fm-test-remote-fm-test-run-.* MACHINE_GATE_FIRSTMATE_WAIT=0 NO_MISTAKES_GATE=unset$' \
    "$FAKE_HOST_HOME/gate.log" || fail "the host gate did not get a named, arrival-logged try: $(cat "$FAKE_HOST_HOME/gate.log")"
  assert_scratch_empty "a finished run"
  assert_laptop_line_untouched "a remote run"
  pass "the runner runs the suite on the host at the exact head, through its gate, with temp files on the scratch volume, and removes the run"
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

test_the_host_copy_carries_this_checkouts_branch_remotes_and_tags() {
  local head here_branch here_url here_origin_head tested
  new_world refs
  cat >"$REPO/tests/fm-remote-refs.test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'branch=%s at=%s\n' "$(git symbolic-ref -q --short HEAD)" "$(git rev-parse HEAD)"
printf 'origin=%s\n' "$(git remote get-url origin)"
printf 'origin-head=%s\n' "$(git symbolic-ref -q refs/remotes/origin/HEAD)"
printf 'origin-main=%s tag=%s\n' "$(git rev-parse -q --verify refs/remotes/origin/main)" "$(git rev-parse -q --verify refs/tags/fixture-tag)"
EOF
  chmod +x "$REPO/tests/fm-remote-refs.test.sh"
  commit_all "a refs probe"
  head=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" remote add origin https://example.invalid/fixture.git
  git -C "$REPO" update-ref refs/remotes/origin/main "$head"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$REPO" tag fixture-tag
  git -C "$REPO" checkout -q -b fixture-feature
  write_probe "$REPO/tests/fm-remote-probe.test.sh" edited-probe
  here_branch=$(git -C "$REPO" symbolic-ref --short HEAD)
  here_url=$(git -C "$REPO" config --get remote.origin.url)
  here_origin_head=$(git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD)
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-refs.test.sh
  expect_code 0 "$RC" "a run that reads refs and remotes"$'\n'"$OUT"
  tested=$(printf '%s\n' "$OUT" | sed -n "s/^branch=$here_branch at=\\([0-9a-f]*\\)\$/\\1/p")
  [ -n "$tested" ] || fail "the host copy is not on branch $here_branch"$'\n'"$OUT"
  [ "$(git -C "$REPO" rev-parse "$tested^")" = "$head" ] \
    || fail "the host branch is at $tested, not the commit under test over HEAD $head"
  assert_contains "$OUT" "origin=$here_url" "the host copy has this checkout's origin URL"
  assert_contains "$OUT" "origin-head=$here_origin_head" "the host copy's origin/HEAD names the same branch"
  assert_contains "$OUT" "origin-main=$head tag=$head" "the host copy has this checkout's remote-tracking refs and tags"

  git -C "$REPO" checkout -q --detach
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-refs.test.sh
  expect_code 0 "$RC" "a detached run that reads refs and remotes"$'\n'"$OUT"
  printf '%s\n' "$OUT" | grep -q '^branch= at=[0-9a-f]*$' || fail "a detached HEAD here should run detached there"$'\n'"$OUT"
  assert_scratch_empty "runs that read refs and remotes"
  pass "a suite on the host sees this checkout's branch at the commit under test, origin URL, origin/HEAD, refs, and tags"
}

test_remote_urls_reach_the_host_without_user_info() {
  local secret=s3cret-fixture-token
  new_world urls
  cat >"$REPO/tests/fm-remote-urls.test.sh" <<'EOF'
#!/usr/bin/env bash
for remote in origin mirror scp plain; do
  printf '%s=%s\n' "$remote" "$(git remote get-url "$remote")"
done
EOF
  chmod +x "$REPO/tests/fm-remote-urls.test.sh"
  commit_all "a urls probe"
  git -C "$REPO" remote add origin "https://fixture-user:$secret@example.invalid/fixture.git"
  git -C "$REPO" remote add mirror "ssh://$secret@example.invalid:2222/fixture.git"
  git -C "$REPO" remote add scp "$secret@example.invalid:o/fixture.git"
  git -C "$REPO" remote add plain "https://example.invalid/at@sign.git"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-urls.test.sh
  expect_code 0 "$RC" "a run from a checkout whose remotes carry user info"$'\n'"$OUT"
  assert_contains "$OUT" "origin=https://example.invalid/fixture.git" "a token and user leave an https URL"
  assert_contains "$OUT" "mirror=ssh://example.invalid:2222/fixture.git" "user info leaves an ssh URL, keeping its port"
  assert_contains "$OUT" "scp=example.invalid:o/fixture.git" "user info leaves an scp-style URL"
  assert_contains "$OUT" "plain=https://example.invalid/at@sign.git" "an @ in a URL's path stays"
  assert_not_contains "$OUT" "$secret" "the token does not reach the host's copy"
  ! grep -q "$secret" "$FAKE_SSH_LOG" || fail "the token was on an ssh command line: $(grep "$secret" "$FAKE_SSH_LOG")"
  pass "every remote URL has its user info removed before it leaves this machine"
}

test_the_host_run_finds_what_the_login_environment_finds() {
  local login_bin
  new_world login
  login_bin="$TMP_ROOT/login/login-bin"
  mkdir -p "$login_bin"
  printf '#!/bin/sh\nexit 0\n' >"$login_bin/herdr"
  chmod +x "$login_bin/herdr"
  FAKE_HOST_PATH="$login_bin:$FAKE_HOST_PATH"
  cat >"$REPO/tests/fm-remote-login.test.sh" <<'EOF'
#!/usr/bin/env bash
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
echo "ok - herdr at $(command -v herdr)"
EOF
  chmod +x "$REPO/tests/fm-remote-login.test.sh"
  commit_all "a suite that needs a login-only tool"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-login.test.sh
  expect_code 0 "$RC" "a tool only the host's login environment finds"$'\n'"$OUT"
  assert_contains "$OUT" "ok - herdr at $login_bin/herdr" "the suite found the login environment's tool"
  assert_scratch_empty "a run in the login environment"
  pass "the host run finds what the host's login environment finds, and still removes its run"
}

test_the_remote_run_gets_the_laptop_pi_and_the_host_keeps_its_own() {
  local login_bin pkg_root
  new_world piwrap
  login_bin="$TMP_ROOT/piwrap/login-bin"
  pkg_root="$TMP_ROOT/piwrap/npm-root"
  mkdir -p "$login_bin" "$pkg_root/@earendil-works/pi-coding-agent/dist/bundle"
  printf '#!/bin/sh\necho 9.9.9-fixture\n' >"$pkg_root/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
  printf '#!/bin/sh\necho 1.1.1-host\n' >"$login_bin/pi"
  # shellcheck disable=SC2016 # the fake npm expands $1 when it runs, not here
  printf '#!/bin/sh\n[ "${1:-}" = root ] && printf "%%s\\n" "%s"\n' "$pkg_root" >"$login_bin/npm"
  chmod +x "$pkg_root/@earendil-works/pi-coding-agent/dist/bundle/cli.js" "$login_bin/pi" "$login_bin/npm"
  FAKE_HOST_PATH="$login_bin:$FAKE_HOST_PATH"
  cat >"$REPO/tests/fm-remote-pi.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - pi $(pi --version) at $(command -v pi)"
EOF
  chmod +x "$REPO/tests/fm-remote-pi.test.sh"
  commit_all "a suite that runs pi"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-pi.test.sh
  expect_code 0 "$RC" "a suite running pi on the host"$'\n'"$OUT"
  printf '%s\n' "$OUT" | grep -q "ok - pi 9.9.9-fixture at $SCRATCH/fm-test-remote\.[^/]*/bin/pi" \
    || fail "the suite did not get the run-dir pi wrapper at the package version:"$'\n'"$OUT"
  assert_scratch_empty "the pi wrapper run"
  pass "the remote run gets the laptop's Pi through the run dir, and the wrapper dies with it"
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

test_an_output_not_copied_back_fails_a_passing_run() {
  local json="$TMP_ROOT/pull-json/timing.json" absent="$TMP_ROOT/pull-json/absent.json"
  new_world pull
  mkdir -p "$TMP_ROOT/pull-json"
  echo stale >"$json"
  export FAKE_SSH_FAIL=pull
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --json "$json" tests/fm-remote-probe.test.sh
  unset FAKE_SSH_FAIL
  expect_code 2 "$RC" "a passing run whose artifact copy-back dropped"$'\n'"$OUT"
  assert_contains "$OUT" "ok - probe at " "the suite ran on the host"
  assert_contains "$OUT" "the ssh connection to fakehost failed while copying back timing.json" "the dropped copy-back is named"
  assert_contains "$OUT" "came back: $json" "the missing artifact is named"
  [ ! -e "$json" ] || fail "a failed copy-back left an earlier run's file at $json"

  echo stale >"$json"
  export FAKE_SSH_FAIL=run
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --json "$json" tests/fm-remote-probe.test.sh
  unset FAKE_SSH_FAIL
  expect_code 2 "$RC" "a connection dropped during the run"$'\n'"$OUT"
  assert_contains "$OUT" "its verdict is unknown" "the dropped run is named"
  [ ! -e "$json" ] || fail "a dropped run left an earlier run's file at $json"

  echo stale >"$json"
  export FAKE_SSH_FAIL=unreachable
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --json "$json" tests/fm-remote-probe.test.sh
  unset FAKE_SSH_FAIL
  expect_code 2 "$RC" "an unreachable host"$'\n'"$OUT"
  [ ! -e "$json" ] || fail "a run that never started left an earlier run's file at $json"

  run_remote bin/fm-test-remote.sh "fakehost:$SCRATCH" --pull "absent.json=$absent" -- tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "a passing run that wrote no requested output"$'\n'"$OUT"
  assert_contains "$OUT" "the run on fakehost wrote no absent.json, so $absent is not written" "the unwritten output is named"
  [ ! -e "$absent" ] || fail "an output the host never wrote exists at $absent"

  : >"$REPO/tests/probe.fail"
  commit_all "fail the probe"
  echo stale >"$absent"
  run_remote bin/fm-test-remote.sh "fakehost:$SCRATCH" --pull "absent.json=$absent" -- tests/fm-remote-probe.test.sh
  expect_code 1 "$RC" "a failing run that wrote no requested output"$'\n'"$OUT"
  [ ! -e "$absent" ] || fail "a failing run left an earlier run's file at $absent"
  assert_scratch_empty "runs whose outputs did not come back"
  pass "a passing run whose requested output does not come back exits 2 naming it, a failing run keeps its status, and no earlier run's file survives"
}

test_fm_test_only_reaches_the_host() {
  new_world only
  run_remote env FM_TEST_ONLY=test_one bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "a focused run on the host"$'\n'"$OUT"
  assert_contains "$OUT" "only=test_one" "FM_TEST_ONLY narrows the run on the host"
  pass "FM_TEST_ONLY reaches the host run"
}

# refuses_live_switch <assignment> <variable> <command...>: the command exits 2
# naming the variable, with no ssh and nothing run.
refuses_live_switch() {
  local assignment=$1 var=$2
  shift 2
  rm -f "$FAKE_SSH_LOG"
  run_remote env "$assignment" "$@"
  expect_code 2 "$RC" "$assignment on the remote path"$'\n'"$OUT"
  assert_contains "$OUT" "live switch set here: $var" "the refusal names $var"
  assert_contains "$OUT" "nothing ran" "the refusal says nothing ran"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran with $assignment"
  [ ! -e "$FAKE_SSH_LOG" ] || fail "$assignment still reached ssh: $(cat "$FAKE_SSH_LOG")"
}

test_a_live_switch_set_here_refuses_the_remote_run() {
  local remote_args
  new_world live
  cat >"$REPO/tests/fm-remote-live.test.sh" <<'EOF'
#!/usr/bin/env bash
. tests/lib.sh
fm_live_gate opt-in FM_FIXTURE_LIVE,FM_FIXTURE_SECOND_NAME tmux
  fm_live_gate default-on FM_FIXTURE_DEFAULT_ON jq
echo "ok - the live suite ran"
EOF
  chmod +x "$REPO/tests/fm-remote-live.test.sh"
  commit_all "a live suite"
  remote_args=(bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-live.test.sh)
  refuses_live_switch FM_LIVE=1 FM_LIVE "${remote_args[@]}"
  refuses_live_switch FM_LIVE=0 FM_LIVE "${remote_args[@]}"
  refuses_live_switch FM_FIXTURE_LIVE=1 FM_FIXTURE_LIVE "${remote_args[@]}"
  refuses_live_switch FM_FIXTURE_SECOND_NAME=1 FM_FIXTURE_SECOND_NAME "${remote_args[@]}"
  refuses_live_switch FM_FIXTURE_DEFAULT_ON=0 FM_FIXTURE_DEFAULT_ON "${remote_args[@]}"
  refuses_live_switch FM_LIVE=1 FM_LIVE bin/fm-stock-bash-check.sh --remote "fakehost:$SCRATCH"
  refuses_live_switch FM_CLAUDE_CALM_PLUGIN_TEST=0 FM_CLAUDE_CALM_PLUGIN_TEST \
    "$ROOT/bin/fm-test-remote.sh" "fakehost:$SCRATCH" -- tests/fm-remote-live.test.sh
  refuses_live_switch FM_HERDR_SMOKE_REAL_CLAUDE=1 FM_HERDR_SMOKE_REAL_CLAUDE "${remote_args[@]}"
  refuses_live_switch FM_UNDECLARED_SUITE_E2E=0 FM_UNDECLARED_SUITE_E2E "${remote_args[@]}"
  run_remote env FM_UNRELATED_SETTING=1 FM_LIVENESS_NOTE=1 FM_FAKE_LIVE=1 FM_TEST_REAL_GIT=/fixture/git \
    bin/fm-test-remote.sh "fakehost:$SCRATCH" -- tests/fm-remote-probe.test.sh
  expect_code 0 "$RC" "variables that are not live switches"$'\n'"$OUT"
  assert_laptop_line_untouched "a refused live run"
  pass "FM_LIVE, each declared live switch, and any variable named as one, on or off, refuse the remote run by name before any ssh"
}

# write_skip_suite <file name> <line...>: a stand-in suite that prints the lines.
write_skip_suite() {
  local file="$REPO/tests/$1"
  shift
  { echo '#!/usr/bin/env bash'; printf 'echo %q\n' "$@"; } >"$file"
  chmod +x "$file"
}

test_a_suite_skipping_for_a_missing_host_tool_fails_the_remote_run() {
  local tools
  new_world skip
  tools="$FAKE_HOST_HOME/tools"
  mkdir -p "$tools"
  # The suite looks only in the host's tool directory, so the case decides what
  # the host has wherever this test runs.
  cat >"$REPO/tests/fm-remote-needs-herdr.test.sh" <<EOF
#!/usr/bin/env bash
PATH="$tools"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
echo "ok - herdr is here"
EOF
  chmod +x "$REPO/tests/fm-remote-needs-herdr.test.sh"
  write_skip_suite fm-remote-caller-token.test.sh 'skip: live: opt-in; set FM_FIXTURE=1 to run'
  commit_all "suites that need a host tool"

  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-needs-herdr.test.sh
  expect_code 1 "$RC" "a suite skipping for a missing herdr on the host"$'\n'"$OUT"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=1 failed=1" "the summary counts the skip as a failure"
  assert_contains "$OUT" "does not permit: skip: herdr not found" "the run names the skip it refused"

  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --fail-on-gate-skip 'live: opt-in' tests/fm-remote-caller-token.test.sh
  expect_code 1 "$RC" "a caller's own --fail-on-gate-skip token on a permitted skip"$'\n'"$OUT"

  printf '#!/bin/sh\nexit 0\n' >"$tools/herdr"
  chmod +x "$tools/herdr"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-needs-herdr.test.sh
  expect_code 0 "$RC" "a host that has herdr"$'\n'"$OUT"
  assert_contains "$OUT" "ok - herdr is here" "the suite ran once the host has the tool"
  assert_scratch_empty "runs that skipped on the host"
  pass "a suite that skips because the host lacks a tool fails the remote run, and a caller's own token still holds"
}

test_any_skip_the_list_does_not_permit_fails_the_remote_run() {
  local n=0 line
  new_world wordings
  while IFS= read -r line; do
    n=$((n + 1))
    write_skip_suite "fm-remote-wording-$n.test.sh" "$line"
  done <<'EOF'
skip: a wording no suite uses yet
skip - a hyphenated wording no suite uses yet
# skip: a commented wording no suite uses yet
# a-suite: skipped (a reason no suite gives yet)
skip-runner: claude is not installed, so its pin check was not exercised
skip: live: herdr absent
skip: node or npm not found for Pi calm renderer test
skip: jq not found (required by the herdr adapter)
skip: installed @earendil-works/pi-coding-agent package not found
skip: Herdr lab helper not executable at /fixture/helper
skip: live: no supported runner (claude, pi, pi-signed) installed
skip: no C compiler, so the compiled stand-in cannot build
skip: installed tasks-axi predates 0.3.0, so the real backlog mutations cannot run
skip: this herdr build is below the events.subscribe capability
skip: kqueue state wait unavailable on this host (probe rc=3)
skip: could not source the cmux adapter
skip: fork counting requires BASHPID (Bash 4+)
# skip: agy is not installed on this machine, so its contract is unverified here
# skip - checkout has no upstream/github/origin remote to scope
skip - tmux not installed
skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)
note: claude not installed; skipping the real-agent busy_state check
ok - shellcheck not installed, skipping
ok - SKIP (ShellCheck 0.11.0 not resolved): fast lint-defect regression check
ok - skipped: tmux is not installed
ok - skipped (python3 is not installed; a queue start decides the note with it)
ok - skipped the Orca capacity case (node, which the Orca status check needs, is not installed)
ok - zsh: shell-portable backend matching skipped (zsh not found)
ok - herdr pane fallback skipped without jq
ok - a launcher argument guard (skipped, no python3)
ok - a stock case (skipped: needs /bin/bash 3.2.57, the stock macOS shell)
ok - skipped on markdown-only tasks-axi: a captain hold
ok - daemon permission recovery skipped because permissions cannot deny reads
ok - skip: macOS /tmp ancestor alias is not present on this host
EOF
  write_skip_suite fm-remote-wording-mid-run.test.sh 'ok - a case ran' 'skip: node not found for one case' 'ok - another case ran'
  commit_all "suites reporting skips the list does not permit"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --jobs 1 --family unclassified
  expect_code 1 "$RC" "suites reporting skips the list does not permit"$'\n'"$OUT"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=$((n + 2)) failed=$((n + 1)) skipped_gate=0" "each of them, and only those, fails"
  assert_contains "$OUT" "tests/fm-remote-wording-mid-run.test.sh exit=1" "a case-level skip mid-run fails the suite"
  pass "any skip the list does not permit fails the remote run, in whatever wording and form"
}

test_a_skip_the_list_cannot_read_fails_the_remote_run() {
  new_world nolist
  git -C "$REPO" rm -q --cached tests/remote-permitted-skips.txt
  rm -f "$REPO/tests/remote-permitted-skips.txt"
  write_skip_suite fm-remote-opt-in.test.sh 'skip: live: opt-in; set FM_FIXTURE=1 to run'
  commit_all "no permitted-skip list"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-opt-in.test.sh
  expect_code 1 "$RC" "a skip with no permitted-skip list"$'\n'"$OUT"
  pass "with no permitted-skip list, every skip fails the remote run"
}

test_a_probe_whose_command_is_missing_fails_the_remote_run() {
  new_world probe
  cat >"$REPO/tests/fm-remote-probe-rc.test.sh" <<EOF
#!/usr/bin/env bash
PATH="$FAKE_HOST_HOME/no-tools"
python3 -I /fixture/waiter >/dev/null 2>&1
echo "skip: kqueue state wait unavailable on this host (probe rc=\$?)"
EOF
  chmod +x "$REPO/tests/fm-remote-probe-rc.test.sh"
  commit_all "a suite whose probe needs python3"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe-rc.test.sh
  expect_code 1 "$RC" "a probe whose python3 is not on the host"$'\n'"$OUT"
  assert_contains "$OUT" "probe rc=127" "the probe's command was missing"
  pass "a suite whose probe's command is missing fails the remote run"
}

test_a_required_tool_fails_whichever_suite_or_form_names_it() {
  new_world byname
  write_skip_suite fm-backend-zellij.test.sh 'skip: jq not found (required by the zellij adapter)'
  write_skip_suite fm-backend-cmux-smoke.test.sh 'skip: jq not found (required by the cmux adapter)'
  write_skip_suite fm-backend-orca.test.sh 'ok - skipped the Orca capacity case (node, which the Orca status check needs, is not installed)'
  write_skip_suite fm-pi-codex-native.test.sh 'skip: live: node absent'
  write_skip_suite fm-remote-harness-note.test.sh 'ok - one harness ran' '# skip: opencode is not installed on this machine, so its contract is unverified here'
  write_skip_suite fm-remote-approve.test.sh '# fm-pi-seeded-home-trust-live-e2e: skipped (no --approve on installed pi)'
  commit_all "required tools named in optional backends' suites and other forms"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --jobs 1 tests/fm-backend-zellij.test.sh tests/fm-backend-cmux-smoke.test.sh \
    tests/fm-backend-orca.test.sh tests/fm-pi-codex-native.test.sh tests/fm-remote-harness-note.test.sh tests/fm-remote-approve.test.sh
  expect_code 1 "$RC" "skips for a required tool"$'\n'"$OUT"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=6 failed=6 skipped_gate=0" "a required tool is required whichever suite names it"
  pass "a required tool missing from an optional backend's suite, a missing harness, and an installed tool's shortfall fail the remote run"
}

test_a_permitted_skip_stays_a_counted_skip() {
  new_world counted
  write_skip_suite fm-backend-zellij-smoke.test.sh 'skip: zellij not found'
  write_skip_suite fm-backend-cmux-smoke.test.sh 'skip: cmux CLI not found on PATH or at the bundle path'
  write_skip_suite fm-backend-orca.test.sh 'skip: orca not found'
  write_skip_suite fm-pi-codex-native.test.sh 'skip: native Pi adapter not installed (PI_CODEX_NATIVE_PACKAGE to select it)'
  write_skip_suite fm-remote-stand-in-path.test.sh 'skip: cursor executable not resolvable in this environment, so the launch could not be built'
  write_skip_suite fm-remote-proc.test.sh 'skip: /proc not readable (the read-death shape needs process ancestry)'
  write_skip_suite fm-remote-live-omp.test.sh 'skip: live: omp absent'
  write_skip_suite fm-remote-opt-in.test.sh 'skip: live: opt-in; set FM_FIXTURE=1 to run'
  write_skip_suite fm-remote-platform.test.sh 'skip: native Windows Node required'
  write_skip_suite fm-remote-omp.test.sh 'ok - a harness ran' '# skip: omp is not installed on this machine, so its contract is unverified here'
  write_skip_suite fm-remote-pi-signed.test.sh 'ok - a runner ran' 'skip-runner: pi-signed is not installed, so its pin check was not exercised'
  write_skip_suite fm-remote-note.test.sh 'ok - a case ran' '# skip: unprivileged PID namespaces are unavailable here, so one case is unverified' \
    'note: FM_FIXTURE=1 not set; skipping the real-agent check' \
    'ok - SKIP: no standalone Pi Calm extension is installed, so dual-install coverage used the pinned contract' \
    'ok - index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat'
  write_skip_suite fm-remote-behavior.test.sh 'ok - no-origin clone is skipped (benign), not flagged STUCK' \
    'ok - a passing required check and a skipped one leave nothing to report' \
    'ok - run wrapper: an unrecognized or absent source takes the helm rather than skipping it' \
    'ok - INJECT_SKIP forces self-handle, bypassing captain-relevant classification' \
    'ok - an origin-less pooled worktree launches as-is, skipping the freshness gate' \
    'ok - sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps'
  commit_all "suites whose skips the list permits"
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" --jobs 1 tests/fm-backend-zellij-smoke.test.sh tests/fm-backend-cmux-smoke.test.sh \
    tests/fm-backend-orca.test.sh tests/fm-pi-codex-native.test.sh tests/fm-remote-stand-in-path.test.sh tests/fm-remote-proc.test.sh \
    tests/fm-remote-live-omp.test.sh tests/fm-remote-opt-in.test.sh tests/fm-remote-platform.test.sh tests/fm-remote-omp.test.sh \
    tests/fm-remote-pi-signed.test.sh tests/fm-remote-note.test.sh tests/fm-remote-behavior.test.sh
  expect_code 0 "$RC" "skips the list permits"$'\n'"$OUT"
  assert_contains "$OUT" "FM_TEST_SUMMARY total=13 failed=0 skipped_gate=9" "the listed skips stay counted, and a behavior named skipped is no skip"
  pass "the five tools, live suites not opted in, skips the laptop prints too, and passing cases about what the product skips do not fail the remote run"
}

# write_server_suite: a suite that leaves a server in its own session, its cwd in
# the host's copy, and records it, then sleeps while <home>/suite-sleeps exists.
write_server_suite() {
  cat >"$REPO/tests/fm-remote-server.test.sh" <<EOF
#!/usr/bin/env bash
perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' sleep 300 </dev/null >/dev/null 2>&1 &
echo \$! >"$FAKE_HOST_HOME/server.pid"
echo \$\$ >"$FAKE_HOST_HOME/suite.pid"
while [ -e "$FAKE_HOST_HOME/suite-sleeps" ]; do sleep 0.2; done
echo "ok - the suite ended"
EOF
  chmod +x "$REPO/tests/fm-remote-server.test.sh"
  commit_all "a suite that leaves a server behind"
}

wait_until() {  # <what> <command...>: up to 45 seconds
  local what=$1
  shift
  for _ in $(seq 1 225); do
    "$@" && return 0
    sleep 0.2
  done
  fail "$what"$'\n'"$(cat "$FAKE_SSH_LOG" 2>/dev/null | tail -n 2)"
}

process_gone() {  # <pid file>
  ! kill -0 "$(cat "$1")" 2>/dev/null
}

scratch_is_empty() {
  [ -z "$(find "$SCRATCH" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
}

test_a_finished_run_ends_what_it_left_and_removes_its_directory() {
  new_world server
  write_server_suite
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-server.test.sh
  expect_code 0 "$RC" "a suite that leaves a server behind"$'\n'"$OUT"
  wait_until "the server a finished suite started is still running" process_gone "$FAKE_HOST_HOME/server.pid"
  OUT=
  assert_scratch_empty "a finished run that left a server"
  pass "a finished run ends the server its suite left in another session and removes its directory"
}

# cut_off_run <signal>: the run is under way on the host when its laptop end gets
# the signal. Everything on the host then ends, and the directory goes.
cut_off_run() {
  local signal=$1 pid
  new_world "cut-$signal"
  : >"$FAKE_HOST_HOME/suite-sleeps"
  write_server_suite
  start_remote_run "$TMP_ROOT/cut-$signal/out" 1 tests/fm-remote-server.test.sh
  pid=$REMOTE_PID
  wait_until "the cut-off suite never started: $(cat "$TMP_ROOT/cut-$signal/out")" test -s "$FAKE_HOST_HOME/suite.pid"
  wait_until "the cut-off suite never recorded its server" test -s "$FAKE_HOST_HOME/server.pid"
  kill "-$signal" "$pid"
  wait "$pid" 2>/dev/null
  wait_until "a run cut off by $signal left its suite running" process_gone "$FAKE_HOST_HOME/suite.pid"
  wait_until "a run cut off by $signal left its server running" process_gone "$FAKE_HOST_HOME/server.pid"
  wait_until "a run cut off by $signal left its directory: $(find "$SCRATCH" -mindepth 1 -maxdepth 1)" scratch_is_empty
}

test_a_cut_off_run_leaves_nothing_on_the_host() {
  cut_off_run KILL
  cut_off_run TERM
  pass "a run whose laptop end is killed or stopped leaves no suite, server, or directory on the host"
}

test_a_cut_off_wait_gives_up_its_place_in_the_hosts_line() {
  local pid tries
  new_world cut-wait
  echo 100000 >"$FAKE_HOST_HOME/busy-tries"
  start_remote_run "$TMP_ROOT/cut-wait/out" 0.2
  pid=$REMOTE_PID
  wait_until "the run never reached the host's gate" test -s "$FAKE_HOST_HOME/gate.log"
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  wait_until "a cut-off wait left its directory" scratch_is_empty
  tries=$(grep -c '^try: ' "$FAKE_HOST_HOME/gate.log")
  sleep 1
  [ "$(grep -c '^try: ' "$FAKE_HOST_HOME/gate.log")" -eq "$tries" ] || fail "a cut-off wait kept asking the host's gate"
  pass "a run cut off while it waits stops asking the host's gate and removes its directory"
}

test_a_run_sweeps_only_abandoned_runs_of_its_own_making() {
  local dead holder
  new_world sweep
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  mkdir -p "$SCRATCH/fm-test-remote.abandoned/repo" "$SCRATCH/fm-test-remote.never-started" \
    "$SCRATCH/fm-test-remote.no-marker/repo" "$SCRATCH/fm-test-remote.running" "$SCRATCH/fm-test-remote.setting-up" \
    "$SCRATCH/fm-test-remote.in-use"
  for name in abandoned never-started running setting-up in-use; do
    : >"$SCRATCH/fm-test-remote.$name/.fm-test-remote-run"
  done
  echo "$dead" >"$SCRATCH/fm-test-remote.abandoned/host.pid"
  echo "$dead" >"$SCRATCH/fm-test-remote.no-marker/host.pid"
  echo "$dead" >"$SCRATCH/fm-test-remote.in-use/host.pid"
  echo "$$" >"$SCRATCH/fm-test-remote.running/host.pid"
  touch -t 202001010000 "$SCRATCH/fm-test-remote.never-started/.fm-test-remote-run"
  (cd "$SCRATCH/fm-test-remote.in-use" && exec sleep 60) &
  holder=$!
  run_remote bin/fm-test-run.sh --remote "fakehost:$SCRATCH" tests/fm-remote-probe.test.sh
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  expect_code 0 "$RC" "a run beside other directories"$'\n'"$OUT"
  [ ! -e "$SCRATCH/fm-test-remote.abandoned" ] || fail "a run whose supervisor is gone was not swept"
  [ ! -e "$SCRATCH/fm-test-remote.never-started" ] || fail "a run that never started was not swept"
  [ -d "$SCRATCH/fm-test-remote.no-marker/repo" ] || fail "a directory without the marker was removed"
  [ -d "$SCRATCH/fm-test-remote.running" ] || fail "a running run's directory was removed"
  [ -d "$SCRATCH/fm-test-remote.setting-up" ] || fail "a run still being set up was removed"
  [ -d "$SCRATCH/fm-test-remote.in-use" ] || fail "a directory a process still uses was removed"
  pass "a run sweeps runs of its own making that are gone, and leaves running, unmarked, and in-use directories alone"
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
  run_remote bin/fm-test-run.sh --remote "" tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "an empty --remote"$'\n'"$OUT"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran anywhere for an empty --remote"
  run_remote bin/fm-test-run.sh --remote= tests/fm-remote-probe.test.sh
  expect_code 2 "$RC" "an empty --remote="$'\n'"$OUT"
  assert_not_contains "$OUT" "FM_TEST_BEGIN" "no suite ran anywhere for an empty --remote="

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
  pass "an empty --remote, an unreachable host, a refused key, a missing scratch root, and a missing host gate each stop before any suite runs"
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

# real_gate_world <name>: a world whose host gate is this machine's real
# ~/.agent-state/machine-gate.sh with its line in the host home, an admission
# read that always has room, and a firstmate.lock held until
# TMP_ROOT/<name>/release exists. Sets LINE_LOG. Returns 1 where there is no
# real gate to run.
real_gate_world() {
  local line_dir
  [ -x "$REAL_GATE" ] && [ -x /usr/bin/lockf ] || return 1
  new_world "$1"
  ln -sf "$REAL_GATE" "$FAKE_HOST_HOME/.agent-state/machine-gate.sh"
  line_dir="$FAKE_HOST_HOME/.agent-state/machine-line"
  LINE_LOG="$line_dir/log.tsv"
  mkdir -p "$line_dir"
  printf '#!/bin/sh\necho "SLOT FREE = YES"\n' >"$TMP_ROOT/$1/read.sh"
  chmod +x "$TMP_ROOT/$1/read.sh"
  FAKE_HOST_ENV="MACHINE_GATE_READ=$TMP_ROOT/$1/read.sh"
  /usr/bin/lockf -k "$line_dir/firstmate.lock" /bin/sh -c \
    "while [ ! -e '$TMP_ROOT/$1/release' ] && [ -d '$TMP_ROOT' ]; do sleep 0.1; done" &
  for _ in $(seq 1 100); do
    [ -e "$line_dir/firstmate.lock" ] && break
    sleep 0.1
  done
}

# start_remote_run <out> <retry seconds> [suite]: a remote run of the suite, the
# probe by default, in the background; sets REMOTE_PID, which ends its line name.
start_remote_run() {
  (cd "$REPO" && exec env PATH="$TMP_ROOT/bin:$PATH" FM_TEST_REMOTE_BASH="$BASH" FM_TEST_REMOTE_RETRY_SECS="$2" \
    bin/fm-test-run.sh --remote "fakehost:$SCRATCH" "${3:-tests/fm-remote-probe.test.sh}") >"$1" 2>&1 &
  REMOTE_PID=$!
}

line_rows() {  # <name suffix> [kind]: count the line log's rows for that caller
  awk -F '\t' -v n="$1" -v k="${2:-}" 'substr($3, length($3) - length(n) + 1) == n && (k == "" || $2 == k) { c++ } END { print c + 0 }' "$LINE_LOG"
}

wait_for_rows() {  # <name suffix> <count>
  for _ in $(seq 1 300); do
    [ "$(line_rows "$1")" -ge "$2" ] && return 0
    sleep 0.1
  done
  fail "$1 never logged $2 rows in the line: $(cat "$LINE_LOG" 2>/dev/null)"
}

# The gate reads arrival from its log to the second, and two arrivals in one
# second have no order, so each later arrival below starts in a later second.
#
# Two remote runs queue on the real gate's held firstmate line; the later
# arrival retries far faster, and still the earlier arrival starts first.
test_remote_runs_start_in_arrival_order_on_the_real_gate() {
  local pid_a pid_b first tries_a tries_b
  real_gate_world order || {
    pass "remote runs start in arrival order on the real gate (skipped: no ~/.agent-state/machine-gate.sh or lockf here)"
    return 0
  }
  start_remote_run "$TMP_ROOT/order/a.out" 2
  pid_a=$REMOTE_PID
  wait_for_rows "-$pid_a" 1
  sleep 1.1
  start_remote_run "$TMP_ROOT/order/b.out" 0.3
  pid_b=$REMOTE_PID
  wait_for_rows "-$pid_b" 3
  : >"$TMP_ROOT/order/release"
  wait "$pid_a" || fail "the first run failed: $(cat "$TMP_ROOT/order/a.out")"
  wait "$pid_b" || fail "the second run failed: $(cat "$TMP_ROOT/order/b.out")"
  first=$(awk -F '\t' '$2 == "start" { print $3; exit }' "$LINE_LOG")
  tries_a=$(line_rows "-$pid_a")
  tries_b=$(line_rows "-$pid_b")
  [ "$tries_b" -gt "$tries_a" ] \
    || fail "the later run should have asked more often ($tries_b tries against $tries_a), or order proves nothing: $(cat "$LINE_LOG")"
  case "$first" in
    *"-$pid_a") ;;
    *) fail "the later arrival started first ($first): $(cat "$LINE_LOG")" ;;
  esac
  pass "on the real gate the earlier remote run starts first, though the later one asked $tries_b times to its $tries_a"
}

# A remote run waits on the held line; a plain gated run, as a long proof
# takes it, arrives later and polls ten times as often. When the line frees,
# the plain run reaches the lock first and the line sends it back, so the
# remote run starts first and the plain run after it.
test_a_remote_run_that_arrived_first_starts_before_a_later_plain_gated_run() {
  local pid_a pid_p before first
  real_gate_world plain || {
    pass "a remote run that arrived first starts before a later plain gated run (skipped: no ~/.agent-state/machine-gate.sh or lockf here)"
    return 0
  }
  start_remote_run "$TMP_ROOT/plain/a.out" 5
  pid_a=$REMOTE_PID
  wait_for_rows "-$pid_a" 1
  sleep 1.1
  (while :; do
    env -i HOME="$FAKE_HOST_HOME" PATH="$FAKE_HOST_PATH" TMPDIR="$FAKE_HOST_TMP" \
      MACHINE_GATE_READ="$TMP_ROOT/plain/read.sh" MACHINE_LINE_NAME=plain-gated-proof MACHINE_GATE_FIRSTMATE_POLL=0.5 \
      "$BASH" "$FAKE_HOST_HOME/.agent-state/machine-gate.sh" run --needs firstmate -- \
      /bin/sh -c "echo plain >>'$TMP_ROOT/plain/plain.ran'"
    [ $? -eq 75 ] || exit 0
    sleep 1
  done) >"$TMP_ROOT/plain/p.out" 2>&1 &
  pid_p=$!
  sleep 2
  # Free the line just after the remote run's latest try, so the plain run's
  # next poll comes long before the remote run asks again.
  before=$(line_rows "-$pid_a")
  wait_for_rows "-$pid_a" $((before + 1))
  : >"$TMP_ROOT/plain/release"
  wait "$pid_a" || fail "the remote run failed: $(cat "$TMP_ROOT/plain/a.out")"
  wait "$pid_p"
  first=$(awk -F '\t' '$2 == "start" { print $3; exit }' "$LINE_LOG")
  case "$first" in
    *"-$pid_a") ;;
    *) fail "the later plain gated run started first ($first): $(cat "$LINE_LOG")" ;;
  esac
  [ "$(line_rows plain-gated-proof queued)" -ge 1 ] \
    || fail "the plain run never reached the lock ahead of the remote run, so order proves nothing: $(cat "$LINE_LOG")"
  [ -s "$TMP_ROOT/plain/plain.ran" ] || fail "the plain gated run never ran after the remote run: $(cat "$TMP_ROOT/plain/p.out")"
  pass "a remote run that arrived first starts before a later, faster-polling plain gated run, which runs after it"
}

test_runs_the_suite_on_the_host_at_the_exact_head_and_cleans_up
test_a_failing_suite_returns_its_exit_status
test_uncommitted_changes_run_as_a_commit_over_head
test_the_host_copy_carries_this_checkouts_branch_remotes_and_tags
test_the_host_run_finds_what_the_login_environment_finds
test_the_remote_run_gets_the_laptop_pi_and_the_host_keeps_its_own
test_remote_urls_reach_the_host_without_user_info
test_changed_base_and_json_cross_the_transport
test_an_output_not_copied_back_fails_a_passing_run
test_fm_test_only_reaches_the_host
test_a_live_switch_set_here_refuses_the_remote_run
test_a_suite_skipping_for_a_missing_host_tool_fails_the_remote_run
test_any_skip_the_list_does_not_permit_fails_the_remote_run
test_a_skip_the_list_cannot_read_fails_the_remote_run
test_a_probe_whose_command_is_missing_fails_the_remote_run
test_a_finished_run_ends_what_it_left_and_removes_its_directory
test_a_cut_off_run_leaves_nothing_on_the_host
test_a_cut_off_wait_gives_up_its_place_in_the_hosts_line
test_a_run_sweeps_only_abandoned_runs_of_its_own_making
test_a_required_tool_fails_whichever_suite_or_form_names_it
test_a_permitted_skip_stays_a_counted_skip
test_a_busy_host_gate_is_a_wait_not_a_failure
test_transport_failures_stop_before_anything_runs
test_a_host_copy_at_another_commit_runs_nothing
test_inspection_modes_run_here
test_stock_bash_check_runs_on_the_host
test_remote_runs_start_in_arrival_order_on_the_real_gate
test_a_remote_run_that_arrived_first_starts_before_a_later_plain_gated_run
