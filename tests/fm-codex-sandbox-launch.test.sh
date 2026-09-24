#!/usr/bin/env bash
# Direct Codex launch-contract checks, including argv fidelity for ampersand paths.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot 'fm-codex-sandbox-R&D')
export FM_BACKEND=tmux

prepare_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  WORKTREE_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  ARGV_LOG="$CASE_DIR/codex-argv.log"
  HOME_LOG="$CASE_DIR/codex-home.log"
  ID="fm-codex-$name"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" "codex-$name"
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  : > "$LAUNCH_LOG"
}

install_fake_codex() {
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$FM_TEST_CODEX_ARGV_LOG"
printf '%s\n' "${FM_HOME-unset}" > "$FM_TEST_CODEX_HOME_LOG"
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

run_canonical_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$ID" "$PROJECT_DIR" --harness codex --model gpt-6-luna --effort max \
    --mode no-mistakes --yolo off
}

assert_argv_pair() {
  local option=$1 value=$2 log=$3 message=$4
  awk -v option="$option" -v value="$value" '
    previous == option && $0 == value { found = 1 }
    { previous = $0 }
    END { exit !found }
  ' "$log" || fail "$message"
}

test_ampersand_path_preserves_max_and_git_root_argv() {
  local out status launch worktree_real git_dir common_dir status_file inbox_dir
  prepare_case argv
  install_fake_codex
  printf 'FM_TEST_CODEX_ARGV_LOG\nFM_TEST_CODEX_HOME_LOG\n' \
    > "$HOME_DIR/config/launch-env-allowlist"

  out=$(run_canonical_spawn 2>&1)
  status=$?
  expect_code 0 "$status" "canonical Codex spawn should construct its launch: $out"
  launch=$(cat "$LAUNCH_LOG")
  worktree_real=$(cd "$WORKTREE_DIR" && pwd -P) || fail "could not resolve fixture worktree"
  git_dir=$(git -C "$worktree_real" rev-parse --absolute-git-dir) || fail "could not resolve fixture Git dir"
  common_dir=$(git -C "$worktree_real" rev-parse --path-format=absolute --git-common-dir) \
    || fail "could not resolve fixture common Git dir"
  status_file="$HOME_DIR/state/$ID.status"
  inbox_dir="$HOME_DIR/state/$ID.inbox"
  [ -f "$status_file" ] && [ ! -L "$status_file" ] \
    || fail "canonical Codex launch did not pre-create a regular task status file"
  [ -d "$inbox_dir/handled" ] && [ ! -L "$inbox_dir" ] && [ ! -L "$inbox_dir/handled" ] \
    || fail "canonical Codex launch did not prepare the task inbox acknowledgement directory"

  out=$(FM_HOME="$CASE_DIR/stale-pilot" FM_TEST_CODEX_ARGV_LOG="$ARGV_LOG" \
    FM_TEST_CODEX_HOME_LOG="$HOME_LOG" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "captured canonical command should execute the fake Codex argv recorder: $out"
  assert_argv_pair --model gpt-6-luna "$ARGV_LOG" "Codex argv lost the requested model"
  assert_argv_pair -c 'model_reasoning_effort="max"' "$ARGV_LOG" \
    "Codex argv lost the catalog-supported max effort"
  assert_argv_pair --cd "$worktree_real" "$ARGV_LOG" \
    "Codex argv changed the ampersand-bearing task worktree path"
  assert_argv_pair --add-dir "$git_dir" "$ARGV_LOG" \
    "Codex argv changed the ampersand-bearing worktree Git directory"
  assert_argv_pair --add-dir "$common_dir" "$ARGV_LOG" \
    "Codex argv changed the ampersand-bearing common Git directory"
  assert_argv_pair --add-dir "$status_file" "$ARGV_LOG" \
    "Codex argv did not scope the status write grant to the exact pre-created task file"
  assert_argv_pair --add-dir "$inbox_dir" "$ARGV_LOG" \
    "Codex argv did not scope steering and acknowledgement writes to this task inbox"
  assert_argv_pair --sandbox workspace-write "$ARGV_LOG" "Codex argv lost workspace-write"
  assert_argv_pair --ask-for-approval never "$ARGV_LOG" "Codex argv lost approval=never"
  assert_argv_pair -c sandbox_workspace_write.network_access=true "$ARGV_LOG" \
    "Codex argv lost explicit workspace-write network access"
  assert_no_grep --dangerously-bypass-approvals-and-sandbox "$ARGV_LOG" \
    "canonical Codex argv must not bypass sandbox or approval controls"
  assert_no_grep __CODEXSANDBOXFLAGS__ "$ARGV_LOG" \
    "the sandbox placeholder leaked into actual Codex argv"
  [ "$(cat "$HOME_LOG")" = "$HOME_DIR" ] \
    || fail "canonical Codex command inherited a stale FM_HOME instead of the selected operational home"
  assert_contains "$launch" "R&D" "captured launch no longer contains the ampersand path"
  pass "Codex preserves ampersand-bearing roots and gpt-6-luna max, scopes status/inbox writes, and pins FM_HOME"
}

test_unresolved_git_admin_root_still_fails_closed() {
  local out status real_git worktree_real
  prepare_case unresolved
  install_fake_codex
  real_git=$(command -v git) || fail "could not resolve real Git executable"
  worktree_real=$(cd "$WORKTREE_DIR" && pwd -P) || fail "could not resolve fixture worktree"
  cat > "$FAKEBIN_DIR/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "${FM_TEST_CODEX_ROOT_FAIL_PATH:-}" ] \
  && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --path-format=absolute ] \
  && [ "${5:-}" = --git-common-dir ]; then
  exit 1
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN_DIR/git"

  out=$(FM_TEST_CODEX_ROOT_FAIL_PATH="$worktree_real" FM_TEST_REAL_GIT="$real_git" \
    run_canonical_spawn 2>&1)
  status=$?
  expect_code 1 "$status" "Codex must refuse when a Git admin root cannot be resolved"
  assert_contains "$out" "Codex task worktree Git administration roots could not be resolved" \
    "root-resolution refusal must name the unresolved bounded roots"
  assert_contains "$out" "refusing Codex launch" "root-resolution failure must not downgrade"
  assert_absent "$HOME_DIR/state/$ID.meta" "failed Codex root resolution must precede task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unresolved Codex roots still delivered a launch"
  pass "Codex refuses an unresolved Git administration root without launching"
}

test_unwritable_task_inbox_refuses_before_launch() {
  local out status inbox_dir
  prepare_case inbox-permissions
  install_fake_codex
  inbox_dir="$HOME_DIR/state/$ID.inbox"
  mkdir -p "$inbox_dir/handled"
  chmod 500 "$inbox_dir"

  out=$(run_canonical_spawn 2>&1)
  status=$?
  chmod 700 "$inbox_dir" || fail "could not restore fixture inbox permissions"
  expect_code 1 "$status" "canonical Codex spawn should refuse an unwritable existing inbox: $out"
  assert_contains "$out" "Codex task inbox is not readable, writable, and traversable: $inbox_dir" \
    "inbox permission refusal should identify the exact task inbox"
  [ ! -s "$LAUNCH_LOG" ] || fail "unwritable task inbox still delivered a worker launch"
  pass "Codex refuses a pre-existing unwritable task inbox before worker launch"
}

test_unwritable_handled_dir_refuses_before_launch() {
  local out status handled_dir
  prepare_case handled-permissions
  install_fake_codex
  handled_dir="$HOME_DIR/state/$ID.inbox/handled"
  mkdir -p "$handled_dir"
  chmod 500 "$handled_dir"

  out=$(run_canonical_spawn 2>&1)
  status=$?
  chmod 700 "$handled_dir" || fail "could not restore fixture handled permissions"
  expect_code 1 "$status" "canonical Codex spawn should refuse an unwritable existing handled directory: $out"
  assert_contains "$out" "Codex task inbox acknowledgement path is not readable, writable, and traversable: $handled_dir" \
    "handled permission refusal should identify the exact acknowledgement directory"
  [ ! -s "$LAUNCH_LOG" ] || fail "unwritable handled directory still delivered a worker launch"
  pass "Codex refuses a pre-existing unwritable inbox acknowledgement directory before worker launch"
}

test_ampersand_path_preserves_max_and_git_root_argv
test_unwritable_task_inbox_refuses_before_launch
test_unwritable_handled_dir_refuses_before_launch
test_unresolved_git_admin_root_still_fails_closed
