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

# A fake treehouse. `status --json` lists the slots under <case>/livepool as
# Treehouse reads them: in-use when a .busy file sits beside the slot (a
# process inside), with a lease id when <case>/leased names it; a
# <case>/status-fails file makes the read fail. Every call is logged to
# <case>/treehouse.log, and the move needs no other subcommand: it never asks
# the allocator for a slot.
make_treehouse_fake() {  # <case-dir>
  {
    printf '#!/usr/bin/env bash\nCASE=%q\n' "$1"
    cat <<'SH'
printf '%s\n' "$*" >> "$CASE/treehouse.log"
case "$*" in
  "status --json")
    [ ! -e "$CASE/status-fails" ] || exit 1
    printf '['
    sep=
    for d in "$CASE"/livepool/*/proj; do
      [ -d "$d" ] || continue
      st=available
      [ ! -e "$(dirname "$d")/.busy" ] || st=in-use
      lid=
      ! grep -Fxq -- "$d" "$CASE/leased" 2>/dev/null || lid=lease-1
      printf '%s{"name":"%s","path":"%s","status":"%s","lease_id":"%s"}' "$sep" "$(basename "$(dirname "$d")")" "$d" "$st" "$lid"
      sep=,
    done
    printf ']\n'
    ;;
esac
exit 0
SH
  } > "$1/fakebin/treehouse"
  chmod +x "$1/fakebin/treehouse"
}

# Add slot <n> to the case's live pool: a detached worktree at main of the
# live clone (or, with "foreign", of the retired clone: one pool, two clones),
# listed in the pool's Treehouse state file as Treehouse records it.
add_slot() {  # <case-dir> <n> [foreign]
  local dir=$1 n=$2 src="$1/home/projects/proj" d sep=
  [ "${3:-}" != foreign ] || src="$1/old/proj"
  mkdir -p "$dir/livepool/$n"
  git -C "$src" worktree add -q --detach "$dir/livepool/$n/proj" main >/dev/null 2>&1 || return 1
  {
    printf '{"worktrees":['
    for d in "$dir"/livepool/*/proj; do
      [ -d "$d" ] || continue
      printf '%s{"name":"%s","path":"%s"}' "$sep" "$(basename "$(dirname "$d")")" "$(cd "$d" && pwd -P)"
      sep=,
    done
    printf ']}\n'
  } > "$dir/livepool/treehouse-state.json"
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
make_case() {  # <name> <id> [noslot]
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
  make_treehouse_fake "$dir"
  [ "${3:-}" = noslot ] || add_slot "$dir" 1 || { echo "not ok - fixture: could not add the live slot" >&2; exit 1; }
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
  grep -q '^get' "$dir/treehouse.log" && fail "move: the move asked Treehouse's allocator for a slot, which resets the slot it hands out"
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
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "dirty: a live slot was claimed for a copy that was not moved"
  assert_grep 'unsaved' "$OLDWT/scratch.txt" "dirty: the old copy's changes were touched"
  pass "a relaunch saves a dirty old copy's bundle and diff first and moves nothing"
}

# One repository spelled two ways (a file:// URL in the retired clone, a plain
# path in the live one) is one origin: the move still happens.
test_relaunch_matches_origins_by_identity_not_spelling() {
  local dir id=ident-a1 out rc=0 head_old
  dir=$(make_case ident "$id")
  OLDWT="$dir/oldpool/7/proj"
  git -C "$dir/old/proj" remote set-url origin "file://$dir/origin.git"
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "ident: the relaunch failed: $out"
  assert_grep "worktree=$dir/livepool/1/proj" "$dir/home/state/$id.meta" "ident: two spellings of one repository were read as two origins"
  assert_equals "$head_old" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "ident: the live slot does not carry the branch head"
  pass "a relaunch reads two spellings of one repository as one origin"
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
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "other: a live slot was claimed for a clone of another repository"
  pass "a relaunch leaves a ship alone when the home clone has another origin"
}

# The move is made when the task's record is rewritten, before any endpoint
# is touched, so a relaunch that refuses afterwards (here the pane will not
# go to the new slot) leaves the task living on the live clone, consistent:
# the record names the live slot, which stays claimed and on the branch, and
# the old copy keeps its claim because the pane still stands in it.
test_relaunch_that_refuses_after_the_move_leaves_the_task_on_the_live_clone() {
  local dir id=roll-a1 out rc=0
  dir=$(make_case roll "$id")
  OLDWT="$dir/oldpool/7/proj"
  : > "$dir/fake/nofollow"
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "roll: a relaunch whose pane stayed in the old copy succeeded: $out"
  assert_grep "worktree=$dir/livepool/1/proj" "$dir/home/state/$id.meta" "roll: the record does not name the live slot after the move"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] || fail "roll: the live slot the record names is not claimed"
  assert_equals "fm/$id" "$(git -C "$dir/livepool/1/proj" rev-parse --abbrev-ref HEAD)" "roll: the live slot is not on the ship branch"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "roll: the old copy's claim was released while the pane still stands in it"
  assert_contains "$out" "keeps the task's claim" "roll: the warning did not say the old copy keeps its claim"
  pass "a relaunch that refuses after the move leaves the task consistent on the live clone"
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
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "clash: a live slot was claimed"
  pass "a relaunch refuses to move over a live branch at another commit"
}

# A relaunch deferred after its pane went to the new slot (here the
# live-session check reads a person live) leaves the task on the live clone:
# the record names the live slot, the pane stands there, and the old copy's
# claim is let go now that the pane has left it.
test_relaunch_deferred_after_the_move_keeps_the_task_on_the_live_clone() {
  local dir id=back-a1 out rc=0
  dir=$(make_case back "$id")
  OLDWT="$dir/oldpool/7/proj"
  # fm-control's own check runs first and is admitted; fm-spawn's, after the
  # move and the pane's cd, reads a person live.
  cat > "$dir/live-session.py" <<PY
import os, sys
n = "$dir/live-session.calls"
calls = (int(open(n).read()) if os.path.exists(n) else 0) + 1
open(n, "w").write(str(calls))
if calls == 1:
    sys.exit(0)
print("a person is live")
sys.exit(75)
PY
  out=$(FM_LIVE_SESSION_CHECK="$dir/live-session.py" run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "back: a deferred relaunch reported success: $out"
  assert_grep "cd -- '$dir/livepool/1/proj'" "$dir/fake/keys" "back: the pane was never sent to the live slot, so this case proves nothing"
  assert_not_contains "$out" "rolled back" "back: a move already recorded was rolled back"
  assert_grep "worktree=$dir/livepool/1/proj" "$dir/home/state/$id.meta" "back: the record does not name the live slot"
  assert_equals "$dir/livepool/1/proj" "$(cat "$dir/fake/cwd")" "back: the pane is not in the live slot"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] || fail "back: the live slot the record names is not claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "back: the old copy kept its claim after the pane left it"
  pass "a relaunch deferred after the move keeps the task on the live clone"
}

# A clean copy not on the ship branch (here detached at another commit) is
# never moved: the branch ref would move while the actual checkout stayed in
# a released slot.
test_relaunch_refuses_a_copy_not_on_its_branch() {
  local dir id=det-a1 out rc=0 before
  dir=$(make_case det "$id")
  OLDWT="$dir/oldpool/7/proj"
  git -C "$OLDWT" checkout -q --detach HEAD~1
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "det: a copy detached off its branch was relaunched: $out"
  assert_contains "$out" "does not have its branch fm/$id checked out" "det: the refusal did not say the branch is not checked out"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "det: the record changed though nothing moved"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "det: a live slot was claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "det: the old slot's claim was released"
  pass "a relaunch refuses to move a copy that does not have its branch checked out"
}

# Local file submodules need protocol.file.allow (git 2.38.1+); test-only.
submodule_env() {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
}

# A case whose project has a submodule (sub) pinned at its first commit on
# main, and whose task branch moves the pin to <sub-rev> in the old copy:
# "pushed" is the submodule's second commit, in its remote; "unpushed" is a
# commit only the old copy's submodule has. Prints the case dir.
make_submodule_case() {  # <name> <id> pushed|unpushed|ignored-edit|dest-ignored
  local dir="$TMP_ROOT/$1" id=$2 old sub2
  git init -q --bare "$dir.sub.git"
  git clone -q "$dir.sub.git" "$dir.subseed" 2>/dev/null
  printf 's1\n' > "$dir.subseed/s.txt"
  git -C "$dir.subseed" add s.txt
  git -C "$dir.subseed" -c user.email=t@t -c user.name=t commit -q -m s1
  printf 's2\n' > "$dir.subseed/s.txt"
  git -C "$dir.subseed" -c user.email=t@t -c user.name=t commit -q -am s2
  git -C "$dir.subseed" push -q origin HEAD:main 2>/dev/null
  git -C "$dir.sub.git" symbolic-ref HEAD refs/heads/main
  sub2=$(git -C "$dir.subseed" rev-parse HEAD)
  make_case "$1" "$id" >/dev/null
  old="$dir/oldpool/7/proj"
  # Pin the submodule on main at s1 and refresh both clones.
  git clone -q "$dir/origin.git" "$dir/seed2" 2>/dev/null
  git -C "$dir/seed2" submodule add -q "$dir.sub.git" sub >/dev/null 2>&1
  git -C "$dir/seed2/sub" checkout -q "$sub2~1"
  git -C "$dir/seed2" add sub
  git -C "$dir/seed2" -c user.email=t@t -c user.name=t commit -q -m "add sub"
  git -C "$dir/seed2" push -q origin HEAD:main 2>/dev/null
  git -C "$dir/home/projects/proj" pull -q --ff-only 2>/dev/null
  # The free live slot stands on the new main with its submodule checked out.
  git -C "$dir/livepool/1/proj" checkout -q --detach main
  git -C "$dir/livepool/1/proj" submodule update --init -q >/dev/null 2>&1
  git -C "$dir/old/proj" fetch -q origin
  git -C "$old" -c user.email=t@t -c user.name=t rebase -q origin/main >/dev/null 2>&1
  git -C "$old" submodule update --init -q >/dev/null 2>&1
  if [ "$3" = pushed ] || [ "$3" = ignored-edit ] || [ "$3" = dest-ignored ]; then
    git -C "$old/sub" checkout -q "$sub2"
  else
    git -C "$old/sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "only here"
  fi
  git -C "$old" add sub
  git -C "$old" -c user.email=t@t -c user.name=t commit -q -m "move the sub pin"
  # The free live slot holds someone's uncommitted edit inside a submodule the
  # live clone tells git status to ignore.
  if [ "$3" = dest-ignored ]; then
    git -C "$dir/home/projects/proj" config submodule.sub.ignore all
    printf 'local-only-edit\n' >> "$dir/livepool/1/proj/sub/s.txt"
  fi
  if [ "$3" = ignored-edit ]; then
    # The project tells git status to ignore the submodule, and the task has
    # an uncommitted edit inside it.
    git -C "$old" config -f .gitmodules submodule.sub.ignore all
    git -C "$old" -c user.email=t@t -c user.name=t commit -q -am "ignore sub in status"
    printf 'edit\n' >> "$old/sub/s.txt"
  fi
  printf '%s\n' "$dir"
}

# A case whose task branch adds a submodule main never had, pinned at a
# commit only the old copy's submodule holds (unpushed). Prints the case dir.
make_added_submodule_case() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2 old
  git init -q --bare "$dir.sub.git"
  git clone -q "$dir.sub.git" "$dir.subseed" 2>/dev/null
  printf 's1\n' > "$dir.subseed/s.txt"
  git -C "$dir.subseed" add s.txt
  git -C "$dir.subseed" -c user.email=t@t -c user.name=t commit -q -m s1
  git -C "$dir.subseed" push -q origin HEAD:main 2>/dev/null
  git -C "$dir.sub.git" symbolic-ref HEAD refs/heads/main
  make_case "$1" "$id" >/dev/null
  old="$dir/oldpool/7/proj"
  git -C "$old" submodule add -q "$dir.sub.git" sub >/dev/null 2>&1
  git -C "$old/sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "only here"
  git -C "$old" add .gitmodules sub
  git -C "$old" -c user.email=t@t -c user.name=t commit -q -m "add sub at an unpushed commit"
  printf '%s\n' "$dir"
}

# The move carries the submodule too: the live slot ends exactly clean with
# the submodule on the commit the branch records.
test_relaunch_moves_submodules_to_the_recorded_commits() {
  local dir id=sub-a1 out rc=0 want
  submodule_env
  dir=$(make_submodule_case sub "$id" pushed)
  OLDWT="$dir/oldpool/7/proj"
  [ -z "$(git -C "$OLDWT" status --porcelain)" ] || fail "sub: fixture: the old copy is not clean"
  want=$(git -C "$OLDWT" rev-parse HEAD:sub)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "sub: the relaunch failed: $out"
  assert_equals "" "$(git -C "$dir/livepool/1/proj" status --porcelain)" "sub: the live slot is not clean after the move"
  assert_equals "$want" "$(git -C "$dir/livepool/1/proj/sub" rev-parse HEAD)" "sub: the live slot's submodule is not on the recorded commit"
  pass "a relaunch's move puts submodules on the commits the branch records"
}

# A pin to a submodule commit no remote has cannot be carried: the relaunch
# refuses and the move is rolled back.
test_relaunch_refuses_an_unpushed_submodule_commit() {
  local dir id=unp-a1 out rc=0 before
  submodule_env
  dir=$(make_submodule_case unp "$id" unpushed)
  OLDWT="$dir/oldpool/7/proj"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "unp: a move with an unpushed submodule commit relaunched: $out"
  assert_contains "$out" "submodules could not be put on the commits" "unp: the refusal did not name the submodules: $out"
  assert_contains "$out" "rolled back task $id's move" "unp: the move was not rolled back"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "unp: the record changed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "unp: the old slot's claim was not restored"
  pass "a relaunch refuses and rolls back a move whose submodule commit is unpushed"
}

# One pool can hold same-origin slots of several clones: a slot of the retired
# clone is never chosen or touched, and the move lands on the live clone's.
test_relaunch_takes_only_a_live_clone_slot() {
  local dir id=forn-a1 out rc=0 foreign_head
  dir=$(make_case forn "$id" noslot)
  OLDWT="$dir/oldpool/7/proj"
  add_slot "$dir" 1 foreign || fail "forn: fixture: could not add the foreign slot"
  add_slot "$dir" 2 || fail "forn: fixture: could not add the live slot"
  foreign_head=$(git -C "$dir/livepool/1/proj" rev-parse HEAD)
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "forn: the relaunch failed: $out"
  assert_grep "worktree=$dir/livepool/2/proj" "$dir/home/state/$id.meta" "forn: the move did not land on the live clone's slot"
  assert_equals "$foreign_head" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "forn: the retired clone's slot was changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "forn: the retired clone's slot was claimed"
  pass "a relaunch's move takes only a slot of the live clone"
}

# A pool holding only another clone's slot has nothing for the move: the
# relaunch refuses and touches nothing.
test_relaunch_refuses_when_only_a_foreign_slot_is_free() {
  local dir id=only-a1 out rc=0 before
  dir=$(make_case only "$id" noslot)
  OLDWT="$dir/oldpool/7/proj"
  add_slot "$dir" 1 foreign || fail "only: fixture: could not add the slot"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "only: a relaunch with no live slot succeeded: $out"
  assert_contains "$out" "has no free slot for it" "only: the refusal did not say no live slot is free"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "only: the record changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "only: the foreign slot was claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "only: the old slot's claim was released"
  pass "a relaunch refuses when only another clone's slot is free"
}

# A live-clone slot another task claims is never chosen, changed or released,
# whether or not anything runs in it: with no other slot the relaunch refuses.
test_relaunch_never_takes_a_slot_another_task_claims() {
  local dir id=clm-a1 out rc=0 before claim slot_head
  dir=$(make_case clm "$id")
  OLDWT="$dir/oldpool/7/proj"
  (. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$dir/livepool/1/proj" other-a1 "$dir/home") || fail "clm: fixture: could not claim the slot for other-a1"
  claim=$(cat "$dir/livepool/1/.fm-slot-owner")
  slot_head=$(git -C "$dir/livepool/1/proj" rev-parse HEAD)
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "clm: a relaunch moved into another task's slot: $out"
  assert_contains "$out" "has no free slot for it" "clm: the refusal did not say no slot is free"
  assert_equals "$slot_head" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "clm: the claimed slot's checkout was changed"
  assert_equals "$claim" "$(cat "$dir/livepool/1/.fm-slot-owner" 2>/dev/null)" "clm: other-a1's claim was changed or removed"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "clm: the record changed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "clm: the old slot's claim was released"
  pass "a relaunch never takes, changes or releases a slot another task claims"
}

# A claimed slot is passed over for the next free slot of the live clone, and
# keeps its claim and its checkout.
test_relaunch_passes_over_a_claimed_slot_for_a_free_one() {
  local dir id=clf-a1 out rc=0 claim
  dir=$(make_case clf "$id")
  OLDWT="$dir/oldpool/7/proj"
  add_slot "$dir" 2 || fail "clf: fixture: could not add the second slot"
  (. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$dir/livepool/1/proj" other-a1 "$dir/home") || fail "clf: fixture: could not claim the slot for other-a1"
  claim=$(cat "$dir/livepool/1/.fm-slot-owner")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "clf: the relaunch failed with a free slot beside the claimed one: $out"
  assert_grep "worktree=$dir/livepool/2/proj" "$dir/home/state/$id.meta" "clf: the move did not land on the free slot"
  assert_equals "$claim" "$(cat "$dir/livepool/1/.fm-slot-owner" 2>/dev/null)" "clf: other-a1's claim was changed or removed"
  pass "a relaunch passes over a claimed slot for a free one"
}

# A slot Treehouse reads in use (a process inside it) is never chosen, even
# unclaimed: with no other slot the relaunch refuses.
test_relaunch_never_takes_a_slot_in_use() {
  local dir id=busy-a1 out rc=0
  dir=$(make_case busy "$id")
  OLDWT="$dir/oldpool/7/proj"
  : > "$dir/livepool/1/.busy"
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "busy: a relaunch moved into a slot in use: $out"
  assert_contains "$out" "has no free slot for it" "busy: the refusal did not say no slot is free"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "busy: the slot in use was claimed"
  pass "a relaunch never takes a slot Treehouse reads in use"
}

# The move is recorded before any endpoint is touched: read from inside
# fm-spawn's own live-session check (after the pane went to the new slot,
# before the replacement record is published), the task's record already
# names the live slot, that slot is claimed, and the project lock the move
# held is released; the old copy keeps its claim until publication, then lets
# it go.
test_relaunch_records_the_move_before_touching_the_endpoint() {
  local dir id=hold-a1 out rc=0 lock
  dir=$(make_case hold "$id")
  OLDWT="$dir/oldpool/7/proj"
  lock=$(FM_HOME="$dir/home"; . "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_project_lock_path "$dir/home/projects/proj") || fail "hold: fixture: no lock path"
  cat > "$dir/live-session.py" <<PY
import os, sys
n = "$dir/live-session.calls"
calls = (int(open(n).read()) if os.path.exists(n) else 0) + 1
open(n, "w").write(str(calls))
if calls == 2:
    meta = open("$dir/home/state/$id.meta").read()
    with open("$dir/window.txt", "w") as f:
        f.write("record=%d new-claim=%d lock=%d old-claim=%d\n" % (
            "worktree=$dir/livepool/1/proj\n" in meta,
            os.path.exists("$dir/livepool/1/.fm-slot-owner"),
            os.path.isdir("$lock"),
            os.path.exists("$dir/oldpool/7/.fm-slot-owner")))
sys.exit(0)
PY
  out=$(FM_LIVE_SESSION_CHECK="$dir/live-session.py" run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "hold: the relaunch failed: $out"
  assert_grep "record=1 new-claim=1 lock=0 old-claim=1" "$dir/window.txt" "hold: the move was not recorded, claimed and unlocked before the endpoint work, with the old claim kept"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "hold: the old claim outlived the published relaunch"
  [ -d "$lock" ] && fail "hold: the project lock outlived the relaunch"
  pass "a relaunch records the move before touching the endpoint and lets the old copy go at publication"
}

# The move chooses and claims its slot under the shared Treehouse project
# lock a fresh spawn holds over its own choice: while another holder has it,
# the relaunch refuses before asking for any slot.
test_relaunch_refuses_while_the_project_lock_is_held() {
  local dir id=lck-a1 out rc=0 lock holder before
  dir=$(make_case lck "$id")
  OLDWT="$dir/oldpool/7/proj"
  lock=$(FM_HOME="$dir/home"; . "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_project_lock_path "$dir/home/projects/proj") || fail "lck: fixture: no lock path"
  /bin/sleep 120 &
  holder=$!
  mkdir -p "$lock" && printf '%s\n' "$holder" > "$lock/pid"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "lck: a relaunch moved while another holder had the project lock: $out"
  assert_contains "$out" "another Treehouse slot allocation or return is in progress" "lck: the refusal did not name the lock"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "lck: a slot was claimed without the project lock"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "lck: the record changed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "lck: the old slot's claim was released"
  pass "a relaunch refuses to move while another holder has the project lock"
}

# A pool whose status cannot be read decides nothing: the relaunch refuses
# before asking for any slot.
test_relaunch_refuses_when_the_live_pool_cannot_be_read() {
  local dir id=unr-a1 out rc=0
  dir=$(make_case unr "$id")
  OLDWT="$dir/oldpool/7/proj"
  : > "$dir/status-fails"
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "unr: a relaunch moved though the live pool could not be read: $out"
  assert_contains "$out" "the pool could not be read" "unr: the refusal did not say the pool could not be read"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "unr: a slot was claimed from an unread pool"
  pass "a relaunch refuses when the live pool's status cannot be read"
}

# A move whose branch adds a submodule the slot's commit never had, pinned at
# an unpushed commit, fails at the submodule step; the rollback leaves the slot
# exactly clean (the half-made submodule directory removed) and unclaimed.
test_relaunch_rollback_cleans_a_submodule_the_branch_added() {
  local dir id=add-a1 out rc=0 before
  submodule_env
  dir=$(make_added_submodule_case add "$id")
  OLDWT="$dir/oldpool/7/proj"
  [ -z "$(git -C "$OLDWT" status --porcelain)" ] || fail "add: fixture: the old copy is not clean"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "add: a move with an unpushed added submodule relaunched: $out"
  assert_contains "$out" "rolled back task $id's move" "add: the move was not rolled back"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "add: the record changed"
  assert_equals "" "$(git -C "$dir/livepool/1/proj" status --porcelain --untracked-files=all --ignore-submodules=none)" "add: the rolled-back slot was left dirty"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "add: the clean rolled-back slot is still claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "add: the old slot's claim was released"
  pass "a rolled-back move removes a submodule the branch added and leaves the slot clean"
}

# An uncommitted edit inside a submodule the project tells git status to
# ignore is still uncommitted work: the copy is saved and refused, not moved.
test_relaunch_refuses_an_ignored_submodule_edit() {
  local dir id=ign-a1 out rc=0 before
  submodule_env
  dir=$(make_submodule_case ign "$id" ignored-edit)
  OLDWT="$dir/oldpool/7/proj"
  [ -z "$(git -C "$OLDWT" status --porcelain)" ] || fail "ign: fixture: plain git status should not see the ignored edit"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "ign: a copy with an ignored submodule edit was moved: $out"
  assert_contains "$out" "has uncommitted or untracked changes" "ign: the refusal did not name the uncommitted work"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "ign: the record changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "ign: a live slot was claimed"
  assert_grep 'edit' "$OLDWT/sub/s.txt" "ign: the edit was touched"
  pass "a relaunch refuses a copy with an uncommitted edit in an ignored submodule"
}

# A free live slot whose only difference is an uncommitted edit inside an
# ignored submodule reads clean to a plain git status, but the move would
# rewrite that submodule: the slot is not taken and the edit stays.
test_relaunch_never_takes_a_slot_with_an_ignored_submodule_edit() {
  local dir id=dig-a1 out rc=0 before
  submodule_env
  dir=$(make_submodule_case dig "$id" dest-ignored)
  OLDWT="$dir/oldpool/7/proj"
  [ -z "$(git -C "$dir/livepool/1/proj" status --porcelain)" ] || fail "dig: fixture: plain git status should not see the slot's ignored edit"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "dig: a relaunch moved into a slot with an ignored submodule edit: $out"
  assert_contains "$out" "has no free slot for it" "dig: the refusal did not say no slot is free"
  assert_grep 'local-only-edit' "$dir/livepool/1/proj/sub/s.txt" "dig: the slot's submodule edit was lost"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "dig: the record changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "dig: the slot was claimed"
  pass "a relaunch never takes a slot whose ignored submodule holds an edit"
}

# A move whose pane would not follow leaves the task recorded on the live slot
# with its pane in the old copy, which it still claims; the next relaunch
# finishes the move: the pane is sent on and the old claim let go.
test_relaunch_finishes_a_move_whose_pane_did_not_follow() {
  local dir id=again-a1 out rc=0
  dir=$(make_case again "$id")
  OLDWT="$dir/oldpool/7/proj"
  : > "$dir/fake/nofollow"
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "again: the first relaunch should have refused: $out"
  assert_grep "worktree=$dir/livepool/1/proj" "$dir/home/state/$id.meta" "again: the first relaunch did not record the move"
  rm -f "$dir/fake/nofollow"
  rc=0
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "again: the second relaunch did not finish the move: $out"
  assert_equals "$dir/livepool/1/proj" "$(cat "$dir/fake/cwd")" "again: the pane is not in the live slot"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "again: the old copy kept its claim after the pane left it"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] || fail "again: the live slot is not claimed"
  pass "a relaunch finishes a move whose pane did not follow the first time"
}

test_relaunch_moves_an_old_clone_ship_onto_the_live_clone
test_relaunch_saves_and_refuses_a_dirty_old_copy
test_relaunch_never_takes_a_slot_with_an_ignored_submodule_edit
test_relaunch_finishes_a_move_whose_pane_did_not_follow
test_relaunch_rollback_cleans_a_submodule_the_branch_added
test_relaunch_refuses_an_ignored_submodule_edit
test_relaunch_records_the_move_before_touching_the_endpoint
test_relaunch_refuses_when_the_live_pool_cannot_be_read
test_relaunch_refuses_while_the_project_lock_is_held
test_relaunch_passes_over_a_claimed_slot_for_a_free_one
test_relaunch_never_takes_a_slot_in_use
test_relaunch_takes_only_a_live_clone_slot
test_relaunch_refuses_when_only_a_foreign_slot_is_free
test_relaunch_never_takes_a_slot_another_task_claims
test_relaunch_moves_submodules_to_the_recorded_commits
test_relaunch_refuses_an_unpushed_submodule_commit
test_relaunch_deferred_after_the_move_keeps_the_task_on_the_live_clone
test_relaunch_refuses_a_copy_not_on_its_branch
test_relaunch_that_refuses_after_the_move_leaves_the_task_on_the_live_clone
test_relaunch_refuses_to_move_over_a_different_live_branch
test_relaunch_matches_origins_by_identity_not_spelling
test_relaunch_leaves_a_ship_whose_home_clone_is_another_origin
