#!/usr/bin/env bash
# Behavior tests for live-session admission: a fresh worker is never launched
# into a project while the machine's live-session detector reads live or cannot
# decide (bin/fm-live-session-lib.sh owns the contract; bin/fm-spawn.sh runs
# the check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# fake tmux and treehouse binaries that log every call, a stub detector that
# records the folder name it was asked about and answers with a chosen exit
# status, and a real markdown backlog when tasks-axi is installed. A deferred
# spawn is judged by what it left behind - no task record, no rendered launch
# brief, no endpoint, no worktree allocation, and a backlog item still queued.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-session)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

make_home() {  # <home> <task-id>
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/config" "$home/data/$id" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Change the project for $id.

## Firstmate spec
Exercise live-session admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
    tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  fi
}

# A case: one home, a project clone named <folder>, fake tmux/treehouse that
# record every call, and a stub detector at <case>/detector.py.
make_case() {  # <name> <task-id> [project-folder]
  local name=$1 id=$2 folder=${3:-project} case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  : > "$case_dir/detector.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  cat > "$case_dir/detector.py" <<'PY'
import os
import sys

with open(os.environ["FM_FAKE_DETECTOR_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("FM_FAKE_DETECTOR_LINE"):
    print(os.environ["FM_FAKE_DETECTOR_LINE"])
sys.exit(int(os.environ.get("FM_FAKE_DETECTOR_EXIT", "0")))
PY
  fm_git_init_commit "$case_dir/$folder"
  fm_git_add_origin "$case_dir/$folder" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$id"
  printf '%s\n' "$case_dir"
}

# One isolated worktree per admitted spawn.
new_worktree() {  # <case-dir> <project-dir> <name>
  git -C "$2" worktree add --quiet -b "wt-$3" "$1/wt-$3"
  printf '%s\n' "$1/wt-$3"
}

# Spawn <id> for <project-dir> with the stub detector answering <exit> and
# <line>. FM_LIVE_SESSION_CHECK is the case's stub unless the caller exported
# DETECTOR to another value.
run_spawn() {  # <case-dir> <pane-path> <exit> <line> <spawn-args...>
  local case_dir=$1 pane=$2 code=$3 line=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_LIVE_SESSION_CHECK="${DETECTOR-$case_dir/detector.py}" \
    FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" \
    FM_FAKE_DETECTOR_EXIT="$code" FM_FAKE_DETECTOR_LINE="$line" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

# Everything a deferred spawn must not have created for <id>.
assert_nothing_created() {  # <case-dir> <project-dir> <id> <worktrees-before>
  local case_dir=$1 project=$2 id=$3 worktrees=$4 home="$1/home"
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  [ "$(call_count "$case_dir")" -eq 0 ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(cat "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(git -C "$project" worktree list --porcelain)" \
    "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

# --- cases ------------------------------------------------------------------

test_clear_read_launches_the_worker() {
  local case_dir out rc=0
  case_dir=$(make_case clear task-c)
  out=$(run_spawn "$case_dir" "$(new_worktree "$case_dir" "$case_dir/project" task-c)" 0 '' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a clear live-session read refused the spawn: $out"
  assert_contains "$out" "spawned task-c" "a clear live-session read did not launch the worker"
  assert_equals "project" "$(cat "$case_dir/detector.log")" "the detector was not asked about the project folder once"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$case_dir/home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "a clear live-session read launches the worker"
}

test_live_read_defers_without_leaving_anything_behind() {
  local case_dir out rc=0 worktrees
  case_dir=$(make_case live task-c)
  worktrees=$(git -C "$case_dir/project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" 75 \
    'live signal=machine-line-reservation source=machine-line/reserve:ep-project' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a live read did not defer the spawn: $out"
  assert_contains "$out" "deferred: a person is live on project project (live-session check of folder project: live signal=machine-line-reservation source=machine-line/reserve:ep-project), and a live session is run by the project's own agent, never by Firstmate; task task-c was not launched and its backlog item stays queued" \
    "the deferral did not name the live signal and say the task stays queued"
  assert_nothing_created "$case_dir" "$case_dir/project" task-c "$worktrees"
  pass "a live read defers the spawn before any record, brief, endpoint, worktree, or backlog move exists"
}

test_unknown_read_defers() {
  local case_dir out rc=0 worktrees
  case_dir=$(make_case unknown task-c)
  worktrees=$(git -C "$case_dir/project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" 2 \
    'unknown signal=calendar source=calendar reason=source read failed' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unknown read did not defer the spawn: $out"
  assert_contains "$out" "deferred: the live-session check cannot tell whether a person is live on project project (folder project: unknown signal=calendar source=calendar reason=source read failed), and an undecided check never counts as clear" \
    "the deferral did not name the detector's reason"
  assert_nothing_created "$case_dir" "$case_dir/project" task-c "$worktrees"
  pass "an unknown read defers the spawn and names the detector's reason"
}

# The detector's contract only knows 0, 75, and 2; a crash or any other status
# is undecided, never clear.
test_out_of_contract_status_defers_as_unknown() {
  local case_dir out rc=0
  case_dir=$(make_case crash task-c)
  out=$(run_spawn "$case_dir" "$case_dir/unused" 1 '' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a detector that exited 1 was read as clear: $out"
  assert_contains "$out" "(folder project: exit 1 with no verdict line)" \
    "the deferral did not report the out-of-contract status"
  assert_absent "$case_dir/home/state/task-c.meta" "an out-of-contract read published a record"
  pass "a detector status outside its contract defers as unknown"
}

# Firstmate's registered name can differ from the captain's checkout folder: a
# registered agent-config whose directory links to .agent-config is asked about
# .agent-config, the name the captain's own panes carry.
test_symlinked_project_is_asked_about_its_checkout_folder() {
  local case_dir out rc=0
  case_dir=$(make_case symlink task-c .agent-config)
  ln -s "$case_dir/.agent-config" "$case_dir/agent-config"
  out=$(run_spawn "$case_dir" "$case_dir/unused" 75 \
    'live signal=herdr-keyboard source=herdr:w1:p2+macOS-HID-keydown' \
    task-c "$case_dir/agent-config" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a live read on the symlinked project did not defer: $out"
  assert_equals ".agent-config" "$(cat "$case_dir/detector.log")" \
    "the detector was not asked about the checkout folder behind the symlink"
  assert_contains "$out" "deferred: a person is live on project agent-config (live-session check of folder .agent-config:" \
    "the deferral did not name both the registered project and its checkout folder"
  pass "a symlinked project is asked about its checkout folder, not its registered name"
}

test_absent_detector_keeps_dispatch_unchanged() {
  local case_dir out rc=0
  case_dir=$(make_case absent task-c)
  out=$(DETECTOR="$case_dir/no-such-detector.py" run_spawn "$case_dir" \
    "$(new_worktree "$case_dir" "$case_dir/project" task-c)" 75 'live signal=x source=y' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a machine without the detector refused the spawn: $out"
  assert_contains "$out" "spawned task-c" "a machine without the detector did not launch the worker"
  assert_equals "" "$(cat "$case_dir/detector.log")" "a missing detector was run"
  pass "a machine without the detector keeps today's dispatch"
}

# The default detector lives under the operator's home when no override is set.
test_default_detector_location_is_used() {
  local case_dir out rc=0 home_dir
  case_dir=$(make_case default task-c)
  home_dir="$case_dir/operator-home"
  mkdir -p "$home_dir/.agent-config/scripts"
  cp "$case_dir/detector.py" "$home_dir/.agent-config/scripts/live-session.py"
  out=$(FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" FM_FAKE_DETECTOR_EXIT=75 \
    FM_FAKE_DETECTOR_LINE='live signal=calendar source=outlook:e1' HOME="$home_dir" \
    env -u FM_LIVE_SESSION_CHECK FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" task-c "$case_dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the default detector location was not consulted: $out"
  assert_equals "project" "$(cat "$case_dir/detector.log")" "the default detector was not asked about the project"
  pass "with no override, the detector under ~/.agent-config/scripts is consulted"
}

test_batch_reports_a_live_deferral() {
  local case_dir out rc=0
  case_dir=$(make_case batch task-c)
  out=$(run_spawn "$case_dir" "$case_dir/unused" 75 'live signal=gj-device source=devicectl:d1+pid:7' \
    "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair met a live session did not exit with the deferral status: $out"
  assert_contains "$out" "deferred: a person is live on project project" "the batch did not show the pair's live deferral"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its deferred: line above says why, and it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a live deferral as a failure"
  pass "a batch reports a live-session deferral as deferred, not failed"
}

test_clear_read_launches_the_worker
test_live_read_defers_without_leaving_anything_behind
test_unknown_read_defers
test_out_of_contract_status_defers_as_unknown
test_symlinked_project_is_asked_about_its_checkout_folder
test_absent_detector_keeps_dispatch_unchanged
test_default_detector_location_is_used
test_batch_reports_a_live_deferral
