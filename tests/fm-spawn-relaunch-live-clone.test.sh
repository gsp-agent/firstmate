#!/usr/bin/env bash
# A relaunch moves a ship recorded in another clone of its project's origin
# onto this home's own clone (<projects>/<name>): a slot leased in the live
# clone's pool carries the same branch at the same head, and the record names
# the live clone and the new slot, so the replacement pushes through the live
# registration. A copy with uncommitted changes is never moved: its bundle and
# diff are saved first and the relaunch refuses. (kh688.1: an old-clone task
# relaunched on the old clone pushed through the old registration twice.)
set -u

. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-relaunch-live-clone)

# The fake terminal the compact-adviser relaunch suite already drives.
eval "$(awk '/^make_relaunch_stub\(\) \{/,/^}/' "$ROOT/tests/fm-spawn-compact-adviser-disable.test.sh")"
command -v make_relaunch_stub >/dev/null 2>&1 || { echo "not ok - fixture: make_relaunch_stub not found" >&2; exit 1; }

# A fake treehouse whose `get --lease` adds a real worktree of the live clone
# to a pool with Treehouse's <pool>/<slot>/<repo> layout and prints its path.
make_treehouse_fake() {  # <case-dir> <live-clone>
  cat > "$1/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$*" in
  "get --lease --lease-holder "*" --no-fetch")
    pool="$1/livepool"
    mkdir -p "\$pool/1"
    git -C "$2" worktree add -q --detach "\$pool/1/proj" >/dev/null 2>&1 || exit 1
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\\n' "\$pool/1/proj" > "\$pool/treehouse-state.json"
    printf '%s\\n' "\$pool/1/proj"
    ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/treehouse"
}

# A case: an origin, a retired clone (old/proj) whose worktree holds the ship
# branch with one commit, the home's live clone (projects/proj), and the
# task record naming the retired clone.
make_case() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2 home
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/old"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir/seed" push -q origin HEAD:main 2>/dev/null
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/old/proj"
  git clone -q "$dir/origin.git" "$home/projects/proj"
  git -C "$dir/old/proj" worktree add -q -b "fm/$id" "$dir/oldwt" >/dev/null 2>&1
  printf 'work\n' > "$dir/oldwt/work.txt"
  git -C "$dir/oldwt" add work.txt
  git -C "$dir/oldwt" -c user.email=t@t -c user.name=t commit -q -m "the task's work"
  make_treehouse_fake "$dir" "$home/projects/proj"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  # The pane already stands in the slot the move will lease, so the relaunch
  # needs no cd keystroke the fake would have to follow.
  printf '%s' "$dir/livepool/1/proj" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/oldwt"
    echo "project=$dir/old/proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "branch=fm/$id"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "$dir"
}

run_relaunch() {  # <case-dir> <id>
  mkdir -p "$1/user-home"
  env PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_FAKE_DIR="$1/fake" FM_PROJECTS_OVERRIDE='' \
    HOME="$1/user-home" CLAUDE_CONFIG_DIR='' CODEX_HOME='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$2" relaunch --note 'replacement continues the same task' 2>&1
}

test_relaunch_moves_an_old_clone_ship_onto_the_live_clone() {
  local dir id=move-a1 out rc=0 head_old meta
  dir=$(make_case move "$id")
  head_old=$(git -C "$dir/oldwt" rev-parse HEAD)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "move: the relaunch failed: $out"
  meta="$dir/home/state/$id.meta"
  assert_grep "project=$(cd "$dir/home/projects/proj" && pwd -P)" "$meta" "move: the record still names the old clone"
  assert_grep "worktree=$dir/livepool/1/proj" "$meta" "move: the record does not name the live pool's slot"
  assert_equals "$head_old" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "move: the live slot does not carry the branch head"
  assert_equals "fm/$id" "$(git -C "$dir/livepool/1/proj" rev-parse --abbrev-ref HEAD)" "move: the live slot is not on the ship branch"
  assert_contains "$out" "moved task $id from" "move: the relaunch did not say it moved the task"
  pass "a relaunch moves an old-clone ship onto a live-pool slot carrying the same branch head"
}

test_relaunch_saves_and_refuses_a_dirty_old_copy() {
  local dir id=dirty-a1 out rc=0 before
  dir=$(make_case dirty "$id")
  printf 'unsaved\n' > "$dir/oldwt/scratch.txt"
  printf 'changed\n' >> "$dir/oldwt/work.txt"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "dirty: a copy with uncommitted changes was relaunched: $out"
  assert_contains "$out" "Saved the branch bundle and the uncommitted diff" "dirty: the refusal did not say what it saved"
  ls "$dir/home/data/$id"/relaunch-move-*/branch.bundle >/dev/null 2>&1 || fail "dirty: no branch bundle was saved"
  grep -q 'changed' "$dir/home/data/$id"/relaunch-move-*/uncommitted.patch || fail "dirty: the uncommitted diff was not saved"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "dirty: the record changed though nothing moved"
  [ -e "$dir/livepool/1/proj" ] && fail "dirty: a live slot was leased for a copy that was not moved"
  assert_grep 'unsaved' "$dir/oldwt/scratch.txt" "dirty: the old copy's changes were touched"
  pass "a relaunch saves a dirty old copy's bundle and diff first and moves nothing"
}

test_relaunch_moves_an_old_clone_ship_onto_the_live_clone
test_relaunch_saves_and_refuses_a_dirty_old_copy
