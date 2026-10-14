#!/usr/bin/env bash
# Behavior tests for bin/fm-drift-nightly.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=$ROOT/bin/fm-drift-nightly.sh
assert_present "$SCRIPT" "bin/fm-drift-nightly.sh is missing"

fixture_commit() { # <repo> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

run_check() { # <repo> [extra args...]
  local repo=$1
  shift
  CHECK_RC=0
  CHECK_OUT=$("$SCRIPT" check --no-fetch --repo "$repo" "$@" 2>"$repo.err") || CHECK_RC=$?
  CHECK_ERR=$(cat "$repo.err")
}

test_unproven_file_is_path_drift_and_exits_1() {
  local repo sha out
  repo=$(fm_test_tmproot drift-unproven)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "an unproven file exits 1"
  out=$CHECK_OUT
  assert_equals "behind: 0
ahead: 1
path-drift: notes.txt
unproven: $sha add notes" "$out" "unproven notes.txt is the whole report"
  pass "an unproven file is path-drift and the check exits 1"
}

test_proof_sha_makes_that_path_ok_and_exits_0() {
  local repo sha
  repo=$(fm_test_tmproot drift-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$sha" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a proven file exits 0"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
keep: $sha add notes" "$CHECK_OUT" "a proof sha marks the path and the commit"
  pass "a proof sha makes that path ok and the check exits 0"
}

test_guard_path_is_ok_and_a_sibling_file_still_drifts() {
  local repo sha
  repo=$(fm_test_tmproot drift-guard)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  mkdir -p "$repo/bin"
  printf '#!/bin/bash\n' > "$repo/bin/fm-drift-nightly.sh"
  printf 'other\n' > "$repo/extra.txt"
  git -C "$repo" add bin/fm-drift-nightly.sh extra.txt
  fixture_commit "$repo" "add guard and extra"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "a sibling of a guard path still exits 1"
  assert_equals "behind: 0
ahead: 1
path-ok: bin/fm-drift-nightly.sh
path-drift: extra.txt
unproven: $sha add guard and extra" "$CHECK_OUT" "the guard path is ok and extra.txt drifts"
  pass "the guard's own file is path-ok and a sibling file still drifts"
}

test_behind_count_is_reported_and_does_not_fail_alone() {
  local repo
  repo=$(fm_test_tmproot drift-behind)
  fm_git_init_commit "$repo"
  git -C "$repo" branch fork
  printf 'upstream\n' > "$repo/upstream.txt"
  git -C "$repo" add upstream.txt
  fixture_commit "$repo" "upstream only"
  git -C "$repo" switch -q fork
  run_check "$repo" --fork fork --upstream main
  expect_code 0 "$CHECK_RC" "behind alone exits 0: $CHECK_ERR"
  assert_equals "behind: 1
ahead: 0" "$CHECK_OUT" "behind is 1 and ahead is 0 with no path lines"
  pass "behind is reported and does not fail the check by itself"
}

test_merge_commit_is_labeled_merge() {
  local repo side merge
  repo=$(fm_test_tmproot drift-merge)
  fm_git_init_commit "$repo"
  git -C "$repo" branch side
  git -C "$repo" switch -q side
  printf 'side\n' > "$repo/side.txt"
  git -C "$repo" add side.txt
  fixture_commit "$repo" "side file"
  side=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q main
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge --no-ff -qm "merge side" side
  merge=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork main --upstream side
  expect_code 0 "$CHECK_RC" "a merge with no extra file exits 0: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
merge: $merge merge side" "$CHECK_OUT" "the merge commit is labeled merge"
  # side sha is not listed because it is the upstream ref.
  assert_not_contains "$CHECK_OUT" "$side" "the upstream side commit is not an ahead commit"
  pass "a merge commit is labeled merge and adds no path-drift when its tree matches upstream"
}

test_install_dry_run_writes_nothing() {
  local dir out rc
  dir=$(fm_test_tmproot drift-dry-install)
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir" "$SCRIPT" install --dry-run --hour 4 --minute 5 --repo /tmp/example-repo) || rc=$?
  expect_code 0 "$rc" "install --dry-run exits 0"
  assert_equals "dry-run: install
label: dev.firstmate.drift-nightly
hour: 4
minute: 5
plist: $dir/dev.firstmate.drift-nightly.plist
repo: /tmp/example-repo" "$out" "install --dry-run prints the job and does not describe a write"
  assert_absent "$dir/dev.firstmate.drift-nightly.plist" "install --dry-run created a plist"
  pass "install --dry-run prints the job and writes nothing"
}

test_install_and_uninstall_round_trip() {
  local dir log fake repo out rc plist
  dir=$(fm_test_tmproot drift-install)
  log=$dir/launchctl.log
  fake=$dir/launchctl
  repo=$dir/repo
  mkdir -p "$repo"
  cat > "$fake" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_DRIFT_LAUNCHCTL_LOG"
if [ "$1" = print ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$fake"
  plist=$dir/agents/dev.firstmate.drift-nightly.plist
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" install --hour 3 --minute 17 --repo "$repo") || rc=$?
  expect_code 0 "$rc" "install exits 0"
  assert_equals "installed: $plist" "$out" "install names the plist it wrote"
  assert_present "$plist" "install did not write the plist"
  assert_grep "bootstrap gui/$(id -u) $plist" "$log" "install did not bootstrap the agent"
  assert_grep '<integer>3</integer>' "$plist" "the plist hour is not 3"
  assert_grep '<integer>17</integer>' "$plist" "the plist minute is not 17"
  assert_grep "$repo" "$plist" "the plist does not name the repo"
  : > "$log"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall) || rc=$?
  expect_code 0 "$rc" "uninstall exits 0"
  assert_equals "uninstalled: removed" "$out" "uninstall reports removed"
  assert_absent "$plist" "uninstall left the plist"
  assert_grep "bootout gui/$(id -u)/dev.firstmate.drift-nightly" "$log" "uninstall did not bootout the agent"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall) || rc=$?
  expect_code 0 "$rc" "a second uninstall exits 0"
  assert_equals "uninstalled: absent" "$out" "a second uninstall reports absent"
  pass "install writes the nightly agent and uninstall removes it, including a second call"
}

test_bad_hour_exits_2() {
  local rc out
  rc=0
  out=$("$SCRIPT" install --hour 24 2>&1) || rc=$?
  expect_code 2 "$rc" "hour 24 exits 2"
  assert_equals "error: --hour must be 0 through 23" "$out" "hour 24 names the rejected range"
  pass "install rejects hour 24"
}

test_unproven_file_is_path_drift_and_exits_1
test_proof_sha_makes_that_path_ok_and_exits_0
test_guard_path_is_ok_and_a_sibling_file_still_drifts
test_behind_count_is_reported_and_does_not_fail_alone
test_merge_commit_is_labeled_merge
test_install_dry_run_writes_nothing
test_install_and_uninstall_round_trip
test_bad_hour_exits_2
