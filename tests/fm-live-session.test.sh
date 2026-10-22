#!/usr/bin/env bash
# Behavior tests for live-session admission: a worker is never launched
# into a project while the machine's live-session detector reads live or cannot
# decide (bin/fm-live-session-lib.sh owns the contract; its callers run
# the check).
#
# Cases drive the real bin/fm-spawn.sh or bin/fm-control.sh against a project clone with
# fake tmux and treehouse binaries that log every call, a stub detector that
# records the folder name it was asked about and answers with a chosen exit
# status, and a real markdown backlog when tasks-axi is installed. A deferred
# fresh spawn is judged by its observable outcome - no worker launch or task
# record, and a backlog item still queued.
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
  : > "$case_dir/actions.log"
  printf 'zsh\n' > "$case_dir/command"
  mkdir -p "$case_dir/operator-home"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    if [ -f "${FM_FAKE_COMMAND_FILE:-}" ]; then cat "$FM_FAKE_COMMAND_FILE"; else printf '%s\n' zsh; fi
    exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -f "$FM_FAKE_WINDOWS" ] || cat "$FM_FAKE_WINDOWS" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" != -n ] || name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" >> "$FM_FAKE_WINDOWS"
    printf '@1\n'
    ;;
  kill-window)
    target=${3:-}
    window=${target##*:=}
    awk -v window="$window" '$0 != window' "$FM_FAKE_WINDOWS" > "$FM_FAKE_WINDOWS.next"
    mv "$FM_FAKE_WINDOWS.next" "$FM_FAKE_WINDOWS"
    ;;
  capture-pane) printf '›\n' ;;
  send-keys)
    if [ -f "${FM_FAKE_COMMAND_FILE:-}" ]; then
      for payload in "$@"; do
        if [ "${FM_FAKE_LIVE_BOUNDARY:-}" = launch ] &&
          [ "$payload" = 'export COMPACT_ADVISER_DISABLE=1' ]; then
          printf '75\n' > "$FM_FAKE_DETECTOR_STATE"
        fi
        case "$payload" in
          ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
        esac
        case "$payload" in
          /quit)
            printf 'stop\n' >> "$FM_FAKE_ACTION_LOG"
            printf '%s\n' zsh > "$FM_FAKE_COMMAND_FILE" ;;
          *'encode launch-brief'*|*'Firstmate operational input waiting: read'*)
            printf 'launch\n' >> "$FM_FAKE_ACTION_LOG"
            printf '%s\n' codex > "$FM_FAKE_COMMAND_FILE" ;;
        esac
      done
    fi
    ;;
esac
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
code = int(os.environ.get("FM_FAKE_DETECTOR_EXIT", "0"))
state = os.environ.get("FM_FAKE_DETECTOR_STATE")
if state and os.path.isfile(state):
    with open(state) as source:
        code = int(source.read())
if os.environ.get("FM_FAKE_DETECTOR_AFTER_ENDPOINT"):
    windows = os.environ["FM_FAKE_WINDOWS"]
    if os.path.isfile(windows):
        with open(windows) as source:
            if "fm-" + os.environ["FM_FAKE_TASK_ID"] in source.read().splitlines():
                code = int(os.environ["FM_FAKE_DETECTOR_AFTER_ENDPOINT"])
if code and os.environ.get("FM_FAKE_DETECTOR_LINE"):
    print(os.environ["FM_FAKE_DETECTOR_LINE"])
sys.exit(code)
PY
  fm_git_init_commit "$case_dir/$folder"
  fm_git_add_origin "$case_dir/$folder" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$id"
  printf '%s\n' "$case_dir"
}

# One isolated worktree per admitted spawn.
new_worktree() {  # <case-dir> <project-dir> <name>
  git -C "$2" worktree add --quiet -b "fm/$3" "$1/wt-$3"
  printf '%s\n' "$1/wt-$3"
}

# Spawn <id> for <project-dir> with the stub detector answering <exit> and
# <line>. FM_LIVE_SESSION_CHECK is the case's stub unless the caller exported
# DETECTOR to another value.
run_spawn() {  # <case-dir> <pane-path> <exit> <line> <spawn-args...>
  local case_dir=$1 pane=$2 code=$3 line=$4
  shift 4
  HOME="$case_dir/operator-home" CLAUDE_CONFIG_DIR='' FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_FAKE_ACTION_LOG="$case_dir/actions.log" \
    FM_FAKE_TASK_ID="$1" FM_FAKE_WINDOWS="$case_dir/windows" \
    FM_FAKE_COMMAND_FILE="$case_dir/command" \
    FM_LIVE_SESSION_CHECK="${DETECTOR-$case_dir/detector.py}" \
    FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" \
    FM_FAKE_DETECTOR_EXIT="$code" FM_FAKE_DETECTOR_LINE="$line" \
    FM_BACKLOG_ROW_TIMEOUT_SECS=30 \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_control() {
  local case_dir=$1 code=$2 line=$3
  shift 3
  HOME="$case_dir/operator-home" CLAUDE_CONFIG_DIR='' FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$case_dir/wt-$1" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_FAKE_ACTION_LOG="$case_dir/actions.log" \
    FM_FAKE_TASK_ID="$1" FM_FAKE_WINDOWS="$case_dir/windows" \
    FM_FAKE_COMMAND_FILE="$case_dir/command" \
    FM_LIVE_SESSION_CHECK="$case_dir/detector.py" \
    FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" \
    FM_FAKE_DETECTOR_EXIT="$code" FM_FAKE_DETECTOR_LINE="$line" \
    FM_BACKLOG_ROW_TIMEOUT_SECS=30 \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

assert_not_launched() {  # <case-dir> <project-dir> <id> <worktrees-before>
  local case_dir=$1 project=$2 id=$3 worktrees=$4 home="$1/home"
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_equals '' "$(cat "$case_dir/actions.log")" "a deferred spawn launched a worker for $id"
  assert_equals "$worktrees" "$(git -C "$project" worktree list --porcelain)" \
    "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

# --- cases ------------------------------------------------------------------

test_headroom_reading_defers_with_the_shared_exit_status() {
  local case_dir id=headroom-contender lock kind out rc STATE FM_HOME
  local -a args
  case_dir=$(make_case headroom-exit "$id")
  STATE="$case_dir/home/state"
  FM_HOME="$case_dir/home"
  . "$ROOT/bin/fm-wake-lib.sh"
  lock=$(fm_task_set_lock_path "$STATE") || fail "could not resolve the task-set lock"
  fm_lock_try_acquire "$lock" || fail "could not hold the task set for the headroom fixture"
  fm_lock_set_role "$lock" task-spawn-reading || fail "could not mark the headroom reading"
  for kind in ship scout batch-ship batch-scout; do
    args=("$id" "$case_dir/project")
    case "$kind" in batch-*) args=("$id=$case_dir/project") ;; esac
    case "$kind" in
      *scout) args+=(--scout) ;;
      *) args+=(--mode no-mistakes --yolo off) ;;
    esac
    rc=0
    out=$(run_spawn "$case_dir" "$case_dir/unused" 0 '' "${args[@]}") || rc=$?
    expect_code "$DEFER_EXIT" "$rc" "a $kind contending with a headroom reading did not defer: $out"
    assert_contains "$out" 'headroom reading' "the $kind deferral omitted its cause"
    assert_absent "$STATE/$id.meta" "a headroom-reading deferral published a task record"
  done
  fm_lock_release "$lock"
  pass "headroom-reading contention exits 75 for ships, scouts, and batch entries"
}

test_late_refusal_closes_new_endpoints_and_allows_retry() {
  local case_dir id kind code wt out rc line
  local -a args
  for kind in ship scout; do
    for code in 75 2; do
      id="owned-$$-$kind-$code"
      case_dir=$(make_case "$id" "$id")
      wt=$(new_worktree "$case_dir" "$case_dir/project" "$id")
      printf 'unrelated-worker\n' > "$case_dir/windows"
      if [ "$code" = 75 ]; then
        line='live signal=person source=desktop'
      else
        line='unknown signal=calendar source=calendar reason=unavailable'
      fi
      out=$(FM_FAKE_DETECTOR_AFTER_ENDPOINT="$code" FM_FAKE_WINDOWS="$case_dir/windows" \
        FM_FAKE_TASK_ID="$id" FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" \
        python3 "$case_dir/detector.py" project) || fail "the detector was not clear before allocation"
      assert_equals '' "$out" "a clear pre-allocation check printed a verdict"
      : > "$case_dir/detector.log"
      args=("$id" "$case_dir/project")
      if [ "$kind" = ship ]; then
        args+=(--mode no-mistakes --yolo off)
      else
        args+=(--scout)
      fi
      rc=0
      out=$(FM_FAKE_DETECTOR_AFTER_ENDPOINT="$code" run_spawn "$case_dir" "$wt" 0 "$line" \
        "${args[@]}") || rc=$?
      expect_code "$DEFER_EXIT" "$rc" "the late $kind refusal did not defer: $out"
      assert_contains "$out" "$line" "the late $kind refusal omitted the detector verdict"
      assert_equals project "$(cat "$case_dir/detector.log")" "the $kind was not checked at the launch boundary"
      assert_equals unrelated-worker "$(cat "$case_dir/windows")" "the refused $kind left its endpoint or closed another worker"
      assert_equals '' "$(cat "$case_dir/actions.log")" "the refused $kind launched a worker"
      assert_absent "$case_dir/home/state/$id.meta" "the refused $kind left a provisional task record"
      rc=0
      out=$(run_spawn "$case_dir" "$wt" 0 '' "${args[@]}") || rc=$?
      expect_code 0 "$rc" "the $kind could not retry after the live signal cleared: $out"
      assert_equals $'unrelated-worker\n'"fm-$id" "$(cat "$case_dir/windows")" "the $kind retry lost an endpoint"
      assert_equals launch "$(cat "$case_dir/actions.log")" "the $kind retry did not launch exactly one worker"
    done
  done
  pass "late live and unknown refusals close only newly created endpoints and permit retry"
}

test_already_stopped_control_refusal_restores_instructions() {
  local case_dir id kind wt out rc code attempt line
  local -a args
  for kind in ship scout; do
    id="stopped-$$-$kind"
    case_dir=$(make_case "$id" "$id")
    wt=$(new_worktree "$case_dir" "$case_dir/project" "$id")
    args=("$id" "$case_dir/project")
    if [ "$kind" = ship ]; then
      args+=(--mode no-mistakes --yolo off)
    else
      args+=(--scout)
    fi
    rc=0
    out=$(run_spawn "$case_dir" "$wt" 0 '' "${args[@]}") || rc=$?
    expect_code 0 "$rc" "could not prepare the stopped $kind: $out"
    printf 'zsh\n' > "$case_dir/command"
    cp "$case_dir/home/data/$id/brief.md" "$case_dir/prior-brief"
    cp "$case_dir/home/state/$id.meta" "$case_dir/prior-meta"
    : > "$case_dir/actions.log"
    for code in 75 2; do
      if [ "$code" = 75 ]; then
        line='live signal=person source=desktop'
      else
        line='unknown signal=calendar source=calendar reason=unavailable'
      fi
      for attempt in 1 2; do
        rc=0
        out=$(run_control "$case_dir" "$code" "$line" "$id" relaunch --note 'continue only after relaunch') || rc=$?
        expect_code "$DEFER_EXIT" "$rc" "the stopped $kind was not deferred: $out"
        cmp "$case_dir/prior-brief" "$case_dir/home/data/$id/brief.md" || fail "a refused stopped $kind accumulated a relaunch note"
        cmp "$case_dir/prior-meta" "$case_dir/home/state/$id.meta" || fail "a refused stopped $kind changed its task record"
        assert_equals 'failed:noted' "$(sed -n 's/^phase=//p' "$case_dir/home/state/$id.control-relaunch")" \
          "the stopped $kind refusal used the stop rollback"
        assert_equals "fm-$id" "$(cat "$case_dir/windows")" "a refused relaunch closed its previous endpoint"
        assert_equals '' "$(cat "$case_dir/actions.log")" "the stopped $kind was launched or stopped during refusal"
      done
    done
  done
  pass "repeated refusals restore an already-stopped ship or scout's original instructions"
}

test_refusal_regressions() {
  local test failed=
  for test in test_headroom_reading_defers_with_the_shared_exit_status \
    test_late_refusal_closes_new_endpoints_and_allows_retry \
    test_already_stopped_control_refusal_restores_instructions; do
    ("$test") || failed="$failed $test"
  done
  [ -z "$failed" ] || fail "refusal regressions failed:$failed"
}

test_live_signal_appearing_during_preparation_defers() {
  local kind action failed='' case_dir id wt out rc real_git line
  local -a args
  real_git=$(command -v git)
  line='live signal=herdr-keyboard source=herdr:person'
  for kind in ship scout; do
    for action in spawn relaunch control; do
      (
        id="late-$$-$kind-$action"
        case_dir=$(make_case "$id" "$id")
        wt=$(new_worktree "$case_dir" "$case_dir/project" "$id")
        args=("$id" "$case_dir/project")
        if [ "$kind" = ship ]; then
          args+=(--mode no-mistakes --yolo off)
        else
          args+=(--scout)
        fi
        if [ "$action" != spawn ]; then
          rc=0
          out=$(run_spawn "$case_dir" "$wt" 0 '' "${args[@]}") || rc=$?
          expect_code 0 "$rc" "could not prepare $kind $action: $out"
          cp "$case_dir/home/state/$id.meta" "$case_dir/prior-meta"
          cp "$case_dir/home/data/$id/brief.md" "$case_dir/prior-brief"
          args=("$id" --relaunch)
          [ "$action" = control ] || printf 'zsh\n' > "$case_dir/command"
        fi
        printf '0\n' > "$case_dir/detector-state"
        export FM_FAKE_DETECTOR_STATE="$case_dir/detector-state"
        out=$(FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" \
          FM_FAKE_DETECTOR_LINE="$line" python3 "$case_dir/detector.py" project) \
          || fail "the detector was not clear at entry to $kind $action"
        assert_equals '' "$out" "the initial clear detector read emitted a verdict"
        : > "$case_dir/detector.log"
        : > "$case_dir/actions.log"
        : > "$case_dir/calls.log"
        rc=0
        if [ "$action" = control ]; then
          cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *' status --porcelain') printf '75\n' > "$FM_FAKE_DETECTOR_STATE" ;;
esac
exec "$FM_FAKE_REAL_GIT" "$@"
SH
          chmod +x "$case_dir/fakebin/git"
          out=$(FM_FAKE_REAL_GIT="$real_git" run_control "$case_dir" 0 "$line" \
            "$id" relaunch --note 'continue the existing work') || rc=$?
        else
          out=$(FM_FAKE_LIVE_BOUNDARY=launch run_spawn "$case_dir" "$wt" 0 "$line" \
            "${args[@]}") || rc=$?
        fi
        assert_equals 75 "$(cat "$case_dir/detector-state")" "the $kind $action preparation did not make the detector live"
        expect_code "$DEFER_EXIT" "$rc" "$kind $action used a stale clear verdict: $out"
        assert_contains "$out" "$line" "the $kind $action refusal omitted the late live signal"
        assert_equals project "$(cat "$case_dir/detector.log")" "the $kind $action did not check the project once at the boundary"
        assert_equals '' "$(cat "$case_dir/actions.log")" "the refused $kind $action launched or stopped an agent"
        if [ "$action" != spawn ]; then
          cmp "$case_dir/prior-meta" "$case_dir/home/state/$id.meta" || fail "a refused $kind $action changed the prior task record"
          cmp "$case_dir/prior-brief" "$case_dir/home/data/$id/brief.md" || fail "a refused $kind $action changed its instructions"
        fi
      ) || failed="$failed $kind/$action"
    done
  done
  [ -z "$failed" ] || fail "late live signals were not respected:$failed"
  pass "ship and scout starts and relaunches refuse a live signal appearing during preparation"
}

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

test_relaunch_checks_admission_and_preserves_prior_work() {
  local case_dir id kind wt out rc code line worktrees calls first_trace
  local -a args
  for kind in ship scout; do
    id="task-r-$$-$kind"
    case_dir=$(make_case "relaunch-$kind" "$id")
    wt=$(new_worktree "$case_dir" "$case_dir/project" "$id")
    if [ "$kind" = ship ]; then
      printf '%s\n' "$$" > "$case_dir/home/state/.lock"
      printf '%s on\n' "$$" > "$case_dir/home/state/.trace-context-effective"
    fi
    args=("$id" "$case_dir/project")
    if [ "$kind" = ship ]; then
      args+=(--mode no-mistakes --yolo off)
    else
      args+=(--scout)
    fi
    rc=0
    out=$(run_spawn "$case_dir" "$wt" 0 '' "${args[@]}") || rc=$?
    expect_code 0 "$rc" "could not dispatch the $kind before relaunch: $out"
    first_trace=$(sed -n 's/^traceparent=//p' "$case_dir/home/state/$id.meta")
    if [ "$kind" = ship ]; then
      [ -n "$first_trace" ] || fail "the trace-enabled ship did not record its carrier"
    fi
    printf '%s\n' 'uncommitted work to preserve' > "$wt/in-progress.txt"
    cp -R "$wt" "$case_dir/worktree-before"
    cp "$case_dir/home/state/$id.meta" "$case_dir/meta-before"
    cp -R "$case_dir/home/data" "$case_dir/data-before"
    worktrees=$(git -C "$case_dir/project" worktree list --porcelain)
    for code in 75 2; do
      if [ "$code" -eq 75 ]; then
        line='live signal=machine-line-reservation source=machine-line/reserve:ep-project'
      else
        line='unknown signal=calendar source=calendar reason=source read failed'
      fi
      : > "$case_dir/calls.log"
      : > "$case_dir/detector.log"
      : > "$case_dir/actions.log"
      printf 'zsh\n' > "$case_dir/command"
      rc=0
      out=$(run_spawn "$case_dir" "$wt" "$code" "$line" "$id" --relaunch) || rc=$?
      expect_code "$DEFER_EXIT" "$rc" "a $kind relaunch bypassed a non-clear detector: $out"
      assert_equals project "$(cat "$case_dir/detector.log")" "the $kind relaunch did not consult the detector once"
      assert_contains "$out" "$line" "the $kind relaunch refusal omitted the detector's verdict"
      assert_contains "$out" "task $id was not relaunched and its prior task record and worktree are unchanged" \
        "the $kind relaunch refusal did not describe its preserved task"
      assert_not_contains "$out" queued "the $kind relaunch refusal claimed its in-flight task was queued"
      cmp "$case_dir/meta-before" "$case_dir/home/state/$id.meta" || fail "a refused $kind relaunch changed its prior task record"
      diff -r "$case_dir/data-before" "$case_dir/home/data" || fail "a refused $kind relaunch changed its instructions or backlog"
      diff -r "$case_dir/worktree-before" "$wt" || fail "a refused $kind relaunch changed prior work"
      assert_equals "$worktrees" "$(git -C "$case_dir/project" worktree list --porcelain)" \
        "a refused $kind relaunch allocated a worktree"
      calls=$(cat "$case_dir/calls.log")
      assert_equals '' "$(cat "$case_dir/actions.log")" "a refused $kind relaunch launched a worker"
      assert_not_contains "$calls" new-window "a refused $kind relaunch allocated an endpoint"
      assert_not_contains "$calls" treehouse "a refused $kind relaunch touched the worktree pool"
      assert_equals "fm-$id" "$(cat "$case_dir/windows")" "a refused $kind relaunch closed its reused endpoint"
    done
    : > "$case_dir/detector.log"
    rc=0
    out=$(run_spawn "$case_dir" "$wt" 0 '' "$id" --relaunch) || rc=$?
    expect_code 0 "$rc" "a clear detector refused the $kind relaunch: $out"
    assert_contains "$out" "spawned $id" "a clear detector did not launch the replacement $kind"
    assert_equals project "$(cat "$case_dir/detector.log")" "the clear $kind relaunch did not consult the detector once"
    assert_equals "$first_trace" "$(sed -n 's/^traceparent=//p' "$case_dir/home/state/$id.meta")" \
      "the clear $kind relaunch did not preserve its trace setting and carrier"
    if [ -n "$first_trace" ]; then
      assert_contains "$(cat "$case_dir/calls.log")" "export TRACEPARENT=$first_trace" \
        "the trace-enabled relaunch did not deliver its recorded carrier"
    fi
    assert_equals "$worktrees" "$(git -C "$case_dir/project" worktree list --porcelain)" \
      "an admitted $kind relaunch allocated another worktree"
    assert_equals 'uncommitted work to preserve' "$(cat "$wt/in-progress.txt")" \
      "an admitted $kind relaunch lost prior work"
  done
  pass "ship and scout relaunches preserve prior state and work on non-clear reads and launch on clear"
}

test_control_relaunch_checks_before_stopping_the_worker() {
  local case_dir id kind wt out rc code line replacement calls worktrees
  local -a args
  for kind in ship scout; do
    id="task-control-$$-$kind"
    case_dir=$(make_case "control-$kind" "$id" .agent-config)
    ln -s "$case_dir/.agent-config" "$case_dir/agent-config"
    wt=$(new_worktree "$case_dir" "$case_dir/.agent-config" "$id")
    args=("$id" "$case_dir/agent-config")
    if [ "$kind" = ship ]; then
      args+=(--mode no-mistakes --yolo off)
    else
      args+=(--scout)
    fi
    rc=0
    out=$(run_spawn "$case_dir" "$wt" 0 '' "${args[@]}") || rc=$?
    expect_code 0 "$rc" "could not dispatch the $kind before control relaunch: $out"
    printf '%s\n' codex > "$case_dir/command"
    printf '%s\n' 'uncommitted work to preserve' > "$wt/in-progress.txt"
    cp -R "$wt" "$case_dir/worktree-before"
    cp "$case_dir/home/state/$id.meta" "$case_dir/meta-before"
    cp -R "$case_dir/home/data" "$case_dir/data-before"
    worktrees=$(git -C "$case_dir/.agent-config" worktree list --porcelain)
    for replacement in same claude; do
      args=("$id" relaunch --note 'continue the existing work')
      [ "$replacement" = same ] || args+=(--harness "$replacement")
      for code in 75 2; do
        if [ "$code" -eq 75 ]; then
          line='live signal=machine-line-reservation source=machine-line/reserve:ep-project'
        else
          line='unknown signal=calendar source=calendar reason=source read failed'
        fi
        : > "$case_dir/calls.log"
        : > "$case_dir/detector.log"
        rc=0
        out=$(run_control "$case_dir" "$code" "$line" "${args[@]}") || rc=$?
        expect_code "$DEFER_EXIT" "$rc" "a $kind control relaunch must defer before stopping: $out"
        assert_equals .agent-config "$(cat "$case_dir/detector.log")" "the $kind pre-stop check did not use the resolved project folder once"
        assert_contains "$out" "$line" "the $kind pre-stop refusal omitted the detector's verdict"
        assert_contains "$out" "agent, instructions, and task record are unchanged" "the $kind refusal omitted its preserved running agent"
        assert_equals codex "$(cat "$case_dir/command")" "a refused $kind control relaunch stopped the running agent"
        calls=$(cat "$case_dir/calls.log")
        assert_not_contains "$calls" send-keys "a refused $kind control relaunch sent a stop or interrupt"
        cmp "$case_dir/meta-before" "$case_dir/home/state/$id.meta" || fail "a refused $kind control relaunch changed its task record"
        diff -r "$case_dir/data-before" "$case_dir/home/data" || fail "a refused $kind control relaunch changed instructions or backlog"
        diff -r "$case_dir/worktree-before" "$wt" || fail "a refused $kind control relaunch changed prior work"
      done
    done
    : > "$case_dir/detector.log"
    : > "$case_dir/calls.log"
    rc=0
    out=$(run_control "$case_dir" 0 '' "$id" relaunch --note 'continue the existing work') || rc=$?
    expect_code 0 "$rc" "a clear detector refused the $kind control relaunch: $out"
    assert_contains "$out" "relaunched $id" "a clear read did not replace the $kind agent"
    assert_equals $'.agent-config\n.agent-config' "$(cat "$case_dir/detector.log")" "the $kind control relaunch did not check both before stopping and before spawning"
    assert_contains "$(cat "$case_dir/calls.log")" /quit "an admitted $kind control relaunch did not stop the prior agent"
    assert_equals codex "$(cat "$case_dir/command")" "an admitted $kind control relaunch did not start the replacement"
    assert_equals "$worktrees" "$(git -C "$case_dir/.agent-config" worktree list --porcelain)" "the $kind control relaunch allocated another worktree"
    assert_equals 'uncommitted work to preserve' "$(cat "$wt/in-progress.txt")" "the $kind control relaunch lost prior work"
  done
  pass "control relaunches check live-session admission before stopping ships or scouts and still replace on clear"
}

test_live_read_defers_before_launch() {
  local case_dir out rc=0 worktrees wt
  case_dir=$(make_case live task-c)
  wt=$(new_worktree "$case_dir" "$case_dir/project" task-c)
  worktrees=$(git -C "$case_dir/project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$wt" 75 \
    'live signal=machine-line-reservation source=machine-line/reserve:ep-project' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a live read did not defer the spawn: $out"
  assert_contains "$out" "deferred: a person is live on project project (live-session check of folder project: live signal=machine-line-reservation source=machine-line/reserve:ep-project), and a live session is run by the project's own agent, never by Firstmate; task task-c was not launched and its backlog item stays queued" \
    "the deferral did not name the live signal and say the task stays queued"
  assert_not_launched "$case_dir" "$case_dir/project" task-c "$worktrees"
  pass "a live read defers the spawn before launch or a backlog move"
}

test_unknown_read_defers() {
  local case_dir out rc=0 worktrees wt
  case_dir=$(make_case unknown task-c)
  wt=$(new_worktree "$case_dir" "$case_dir/project" task-c)
  worktrees=$(git -C "$case_dir/project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$wt" 2 \
    'unknown signal=calendar source=calendar reason=source read failed' \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unknown read did not defer the spawn: $out"
  assert_contains "$out" "deferred: the live-session check cannot tell whether a person is live on project project (folder project: unknown signal=calendar source=calendar reason=source read failed), and an undecided check never counts as clear" \
    "the deferral did not name the detector's reason"
  assert_not_launched "$case_dir" "$case_dir/project" task-c "$worktrees"
  pass "an unknown read defers the spawn and names the detector's reason"
}

# The detector's contract only knows 0, 75, and 2; a crash or any other status
# is undecided, never clear.
test_out_of_contract_status_defers_as_unknown() {
  local case_dir out rc=0
  case_dir=$(make_case crash task-c)
  out=$(run_spawn "$case_dir" "$(new_worktree "$case_dir" "$case_dir/project" task-c)" 1 '' \
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
  out=$(run_spawn "$case_dir" "$(new_worktree "$case_dir" "$case_dir/.agent-config" task-c)" 75 \
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
  local case_dir out rc=0 home_dir wt
  case_dir=$(make_case default task-c)
  wt=$(new_worktree "$case_dir" "$case_dir/project" task-c)
  home_dir="$case_dir/operator-home"
  mkdir -p "$home_dir/.agent-config/scripts"
  cp "$case_dir/detector.py" "$home_dir/.agent-config/scripts/live-session.py"
  out=$(FM_FAKE_DETECTOR_LOG="$case_dir/detector.log" FM_FAKE_DETECTOR_EXIT=75 \
    FM_FAKE_DETECTOR_LINE='live signal=calendar source=outlook:e1' HOME="$home_dir" \
    env -u FM_LIVE_SESSION_CHECK FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_TASK_ID=task-c FM_FAKE_WINDOWS="$case_dir/windows" \
    FM_FAKE_COMMAND_FILE="$case_dir/command" FM_FAKE_ACTION_LOG="$case_dir/actions.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" task-c "$case_dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the default detector location was not consulted: $out"
  assert_equals "project" "$(cat "$case_dir/detector.log")" "the default detector was not asked about the project"
  pass "with no override, the detector under ~/.agent-config/scripts is consulted"
}

test_batch_reports_a_live_deferral() {
  local case_dir out rc=0
  case_dir=$(make_case batch task-c)
  out=$(run_spawn "$case_dir" "$(new_worktree "$case_dir" "$case_dir/project" task-c)" 75 'live signal=gj-device source=devicectl:d1+pid:7' \
    "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair met a live session did not exit with the deferral status: $out"
  assert_contains "$out" "deferred: a person is live on project project" "the batch did not show the pair's live deferral"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its deferred: line above says why, and it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a live deferral as a failure"
  pass "a batch reports a live-session deferral as deferred, not failed"
}

test_refusal_regressions
test_live_signal_appearing_during_preparation_defers
test_clear_read_launches_the_worker
test_relaunch_checks_admission_and_preserves_prior_work
test_control_relaunch_checks_before_stopping_the_worker
test_live_read_defers_before_launch
test_unknown_read_defers
test_out_of_contract_status_defers_as_unknown
test_symlinked_project_is_asked_about_its_checkout_folder
test_absent_detector_keeps_dispatch_unchanged
test_default_detector_location_is_used
test_batch_reports_a_live_deferral
