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
printf '%s\n' "\$*" >> "$1/treehouse.log"
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

# The fake pane follows a typed `cd -- '<dir>'` line, as a shell would,
# unless the case has said it will not (fake/nofollow).
make_cd_following_tmux() {  # <case-dir>
  mv "$1/fakebin/tmux" "$1/fakebin/tmux.stub"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ] && [ ! -e "$FM_FAKE_DIR/nofollow" ]; then
  for a in "$@"; do
    case "$a" in
      "cd -- '"*"'") p=${a#"cd -- '"}; printf '%s' "${p%"'"}" > "$FM_FAKE_DIR/cwd" ;;
    esac
  done
fi
exec "$(dirname "$0")/tmux.stub" "$@"
SH
  chmod +x "$1/fakebin/tmux"
}

# A case: an origin, a retired clone (old/proj) whose old-pool slot
# (oldpool/7/proj, claimed by the task) holds the ship branch with one commit,
# the home's live clone (projects/proj), the task record naming the retired
# clone, and the pane standing in the old slot, as it does when a real
# relaunch begins (oldpool/7/proj is the OLDWT each case names).
make_case() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2 home OLDWT
  home="$dir/home"
  OLDWT="$dir/oldpool/7/proj"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/old"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  make_cd_following_tmux "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir/seed" push -q origin HEAD:main 2>/dev/null
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/old/proj"
  git clone -q "$dir/origin.git" "$home/projects/proj"
  mkdir -p "$dir/oldpool/7"
  git -C "$dir/old/proj" worktree add -q -b "fm/$id" "$OLDWT" >/dev/null 2>&1
  printf '{"worktrees":[{"name":"7","path":"%s"}]}\n' "$OLDWT" > "$dir/oldpool/treehouse-state.json"
  (. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$OLDWT" "$id" "$home") || { echo "not ok - fixture: could not claim the old slot" >&2; exit 1; }
  printf 'work\n' > "$OLDWT/work.txt"
  git -C "$OLDWT" add work.txt
  git -C "$OLDWT" -c user.email=t@t -c user.name=t commit -q -m "the task's work"
  make_treehouse_fake "$dir" "$home/projects/proj"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$OLDWT" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$OLDWT"
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
  OLDWT="$dir/oldpool/7/proj"
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "move: the relaunch failed: $out"
  meta="$dir/home/state/$id.meta"
  assert_grep "project=$(cd "$dir/home/projects/proj" && pwd -P)" "$meta" "move: the record still names the old clone"
  assert_grep "worktree=$dir/livepool/1/proj" "$meta" "move: the record does not name the live pool's slot"
  assert_equals "$head_old" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "move: the live slot does not carry the branch head"
  assert_equals "fm/$id" "$(git -C "$dir/livepool/1/proj" rev-parse --abbrev-ref HEAD)" "move: the live slot is not on the ship branch"
  assert_contains "$out" "moving task $id from" "move: the relaunch did not say it moved the task"
  assert_grep "cd -- '$dir/livepool/1/proj'" "$dir/fake/keys" "move: the pane was not told to go to the live slot"
  assert_equals "$dir/livepool/1/proj" "$(cat "$dir/fake/cwd")" "move: the pane is not in the live slot"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] || fail "move: the live slot is not claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "move: the old slot's claim was not released"
  pass "a relaunch moves an old-clone ship onto a live-pool slot carrying the same branch head"
}

test_relaunch_saves_and_refuses_a_dirty_old_copy() {
  local dir id=dirty-a1 out rc=0 before
  dir=$(make_case dirty "$id")
  OLDWT="$dir/oldpool/7/proj"
  printf 'unsaved\n' > "$OLDWT/scratch.txt"
  printf 'changed\n' >> "$OLDWT/work.txt"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "dirty: a copy with uncommitted changes was relaunched: $out"
  assert_contains "$out" "Saved the branch bundle and the uncommitted diff" "dirty: the refusal did not say what it saved"
  ls "$dir/home/data/$id"/relaunch-move-*/branch.bundle >/dev/null 2>&1 || fail "dirty: no branch bundle was saved"
  grep -q 'changed' "$dir/home/data/$id"/relaunch-move-*/uncommitted.patch || fail "dirty: the uncommitted diff was not saved"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "dirty: the record changed though nothing moved"
  [ -e "$dir/livepool/1/proj" ] && fail "dirty: a live slot was leased for a copy that was not moved"
  assert_grep 'unsaved' "$OLDWT/scratch.txt" "dirty: the old copy's changes were touched"
  pass "a relaunch saves a dirty old copy's bundle and diff first and moves nothing"
}

# One repository spelled two ways (ssh in the retired clone, https in the live
# one) is one origin: the move still happens. The branch is carried from the
# old copy, never fetched from origin, so the URLs need not resolve.
test_relaunch_matches_origins_by_identity_not_spelling() {
  local dir id=ident-a1 out rc=0 head_old
  dir=$(make_case ident "$id")
  OLDWT="$dir/oldpool/7/proj"
  git -C "$dir/old/proj" remote set-url origin git@github.com:Example-Org/Proj.git
  git -C "$dir/home/projects/proj" remote set-url origin https://github.com/example-org/proj
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "ident: the relaunch failed: $out"
  assert_grep "worktree=$dir/livepool/1/proj" "$dir/home/state/$id.meta" "ident: an ssh and an https URL of one repository were read as two origins"
  assert_equals "$head_old" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "ident: the live slot does not carry the branch head"
  pass "a relaunch reads an ssh and an https URL of one repository as one origin"
}

# A home clone of another repository is not this task's live clone: nothing
# moves and the relaunch stays on the recorded clone.
test_relaunch_leaves_a_ship_whose_home_clone_is_another_origin() {
  local dir id=other-a1 out rc=0
  dir=$(make_case other "$id")
  OLDWT="$dir/oldpool/7/proj"
  git -C "$dir/old/proj" remote set-url origin https://github.com/example-org/proj
  git -C "$dir/home/projects/proj" remote set-url origin https://github.com/example-org/another
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "other: the relaunch failed: $out"
  assert_grep "worktree=$OLDWT" "$dir/home/state/$id.meta" "other: a ship was moved onto a clone of another repository"
  [ -e "$dir/livepool/1/proj" ] && fail "other: a live slot was leased for a clone of another repository"
  pass "a relaunch leaves a ship alone when the home clone has another origin"
}

# A relaunch that moved the task but then refuses (here the pane will not go
# to the new slot) rolls the move back: the record and the old slot's claim
# stand as before, the live slot is unclaimed, carries no copy of the branch,
# and is returned to its pool.
test_relaunch_rolls_back_a_move_when_the_relaunch_refuses() {
  local dir id=roll-a1 out rc=0 before
  dir=$(make_case roll "$id")
  OLDWT="$dir/oldpool/7/proj"
  : > "$dir/fake/nofollow"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "roll: a relaunch whose pane stayed in the old copy succeeded: $out"
  assert_contains "$out" "rolled back task $id's move" "roll: the refusal did not roll the move back"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "roll: the record changed though the relaunch refused"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "roll: the old slot's claim was not restored"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "roll: the live slot is still claimed by a task whose record names the old copy"
  git -C "$dir/home/projects/proj" rev-parse --verify -q "refs/heads/fm/$id" >/dev/null && fail "roll: the live clone kept a copy of the branch"
  grep -q "^return .*/roll/livepool/1/proj\$" "$dir/treehouse.log" || fail "roll: the live slot was not returned to its pool"
  pass "a relaunch that refuses after a move rolls the move back"
}

# A live clone that already has the ship branch at another commit is never
# overwritten: the move refuses before it leases anything.
test_relaunch_refuses_to_move_over_a_different_live_branch() {
  local dir id=clash-a1 out rc=0 other
  dir=$(make_case clash "$id")
  OLDWT="$dir/oldpool/7/proj"
  git -C "$dir/home/projects/proj" branch "fm/$id" main
  other=$(git -C "$dir/home/projects/proj" rev-parse "fm/$id")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "clash: the relaunch moved over a different live branch: $out"
  assert_contains "$out" "already has a branch fm/$id" "clash: the refusal did not name the branch"
  assert_equals "$other" "$(git -C "$dir/home/projects/proj" rev-parse "fm/$id")" "clash: the live clone's branch was changed"
  [ -e "$dir/livepool/1/proj" ] && fail "clash: a live slot was leased"
  pass "a relaunch refuses to move over a live branch at another commit"
}

test_relaunch_moves_an_old_clone_ship_onto_the_live_clone
test_relaunch_saves_and_refuses_a_dirty_old_copy
test_relaunch_rolls_back_a_move_when_the_relaunch_refuses
test_relaunch_refuses_to_move_over_a_different_live_branch
test_relaunch_matches_origins_by_identity_not_spelling
test_relaunch_leaves_a_ship_whose_home_clone_is_another_origin
