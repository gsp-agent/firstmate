#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The matching relaunch-side carve-out at the `[ "$RELAUNCH" -eq 1 ] &&
# [ "$BACKEND" = orca ]` branch is guarded by an earlier, unconditional gate:
# fm_control_backend_state_verified (bin/fm-control-lib.sh) only recognizes
# tmux and herdr as having a recovery-grade agent-state classifier, so any
# `--relaunch` on backend=orca is refused before that branch can ever run.
# The second test below pins that refusal so a future change that starts
# routing orca through the classifier does not silently reach the untested
# branch without also covering it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
printf '%s\n' "$*" >> "$DIR/calls.log"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    printf 'term-1\n' > "$DIR/live-terminal"
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal close")
    [ "${4:-}" = term-1 ] || exit 1
    : > "$DIR/live-terminal"
    printf '{"ok":true}\n'
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
  "terminal read")
    printf '{"ok":true,"result":{"terminal":{"tail":["• Working (1s • esc to interrupt)"]}}}\n'
    exit 0
    ;;
  "worktree rm")
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  mkdir -p "$case_dir/user-home"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" CODEX_HOME='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" \
    "the refusal should name the missing classifier, proving relaunch never reaches the worktree carve-out"
  pass "a relaunch against an Orca-backed task is refused before the RELAUNCH+orca worktree carve-out could run"
}

test_orca_late_live_refusal_closes_the_new_terminal() {
  local case_dir home id=orca-deferred-a3 fb out status=0
  case_dir="$TMP_ROOT/deferred"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Defer the Orca launch when a person becomes live during preparation.

## Firstmate spec
Close this attempt's terminal before returning the queued refusal.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  cat > "$case_dir/detector.py" <<'PY'
import os
import sys

terminal = os.path.join(os.environ["FM_TEST_ORCA_DIR"], "live-terminal")
if os.path.isfile(terminal):
    with open(terminal) as source:
        if source.read().strip():
            print("live signal=person source=desktop")
            sys.exit(75)
PY
  FM_TEST_ORCA_DIR="$case_dir" python3 "$case_dir/detector.py" project \
    || fail "the Orca detector was not clear before the endpoint existed"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    FM_LIVE_SESSION_CHECK="$case_dir/detector.py" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1) || status=$?
  expect_code 75 "$status" "the late Orca live signal did not defer: $out"
  assert_contains "$out" 'live signal=person source=desktop' "the Orca refusal omitted its live signal"
  [ ! -s "$case_dir/live-terminal" ] || fail "the refused Orca attempt left its new terminal open"
  assert_contains "$(cat "$case_dir/calls.log")" 'terminal close --terminal term-1' "the refused Orca attempt did not close its terminal"
  assert_contains "$(cat "$case_dir/calls.log")" "worktree rm --worktree id:wt-fm-$id" "the refused Orca attempt did not unwind its new worktree allocation"
  assert_absent "$home/state/$id.meta" "the refused Orca attempt left a provisional task record"
  pass "an Orca live refusal closes only its newly allocated terminal and worktree"
}

test_orca_late_live_refusal_closes_the_new_terminal
test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run

echo "# all fm-spawn-orca-worktree tests passed"
