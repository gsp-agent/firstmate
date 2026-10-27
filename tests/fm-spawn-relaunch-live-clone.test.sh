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

# A fake treehouse with Treehouse's <pool>/<slot>/<repo> layout. Each
# `get --lease` follows the case's lease plan (<case>/lease-plan, one line per
# lease) or, with no plan, adds a new slot of the live clone:
#   live      add a new slot of the live clone (submodules initialised)
#   foreign   add a new slot of the retired clone (one pool, two clones)
#   path <p>  hand out an existing slot <p>
# A plan that has run out fails the lease, as an allocator with nothing to
# give does. Every call is logged to <case>/treehouse.log.
make_treehouse_fake() {  # <case-dir> <live-clone>
  {
    printf '#!/usr/bin/env bash\nCASE=%q\nLIVE=%q\n' "$1" "$2"
    cat <<'SH'
printf '%s\n' "$*" >> "$CASE/treehouse.log"
case "$*" in
  "get --lease --lease-holder "*" --no-fetch")
    pool="$CASE/livepool"
    n=$(( $(cat "$CASE/lease-count" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$CASE/lease-count"
    if [ -f "$CASE/lease-plan" ]; then
      step=$(sed -n "${n}p" "$CASE/lease-plan")
      [ -n "$step" ] || exit 1
    else
      step=live
    fi
    case "$step" in
      "path "*) slot=${step#path } ;;
      live|foreign)
        src=$LIVE
        [ "$step" = live ] || src="$CASE/old/proj"
        mkdir -p "$pool/$n"
        slot="$pool/$n/proj"
        git -C "$src" worktree add -q --detach "$slot" >/dev/null 2>&1 || exit 1
        [ ! -f "$slot/.gitmodules" ] || git -C "$slot" submodule update --init -q >/dev/null 2>&1 || exit 1
        ;;
      *) exit 1 ;;
    esac
    # Every slot in the pool is listed, as Treehouse's state file lists them.
    {
      printf '{"worktrees":['
      sep=
      for d in "$pool"/*/proj; do
        [ -d "$d" ] || continue
        printf '%s{"name":"%s","path":"%s"}' "$sep" "$(basename "$(dirname "$d")")" "$d"
        sep=,
      done
      printf ']}\n'
    } > "$pool/treehouse-state.json"
    printf '%s\n' "$slot"
    ;;
esac
exit 0
SH
  } > "$1/fakebin/treehouse"
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

# A relaunch deferred after its pane already went to the new slot (here the
# live-session check reads a person live) rolls the move back with the pane:
# the pane is sent back to the old copy before the live slot is returned.
test_relaunch_rollback_after_the_pane_moved_brings_the_pane_back() {
  local dir id=back-a1 out rc=0 before
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
  before=$(cat "$dir/home/state/$id.meta")
  out=$(FM_LIVE_SESSION_CHECK="$dir/live-session.py" run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "back: a deferred relaunch reported success: $out"
  assert_grep "cd -- '$dir/livepool/1/proj'" "$dir/fake/keys" "back: the pane was never sent to the live slot, so this case proves nothing"
  assert_contains "$out" "rolled back task $id's move" "back: the deferral did not roll the move back"
  assert_grep "cd -- '$OLDWT'" "$dir/fake/keys" "back: the pane was not sent back to the old copy"
  assert_equals "$OLDWT" "$(cat "$dir/fake/cwd")" "back: the pane was left in the live slot"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "back: the record changed though the relaunch was deferred"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "back: the old slot's claim was not restored"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "back: the live slot is still claimed"
  grep -q "^return .*/back/livepool/1/proj\$" "$dir/treehouse.log" || fail "back: the live slot was not returned once the pane left it"
  pass "a relaunch rolled back after its pane moved sends the pane back before returning the slot"
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
  [ -e "$dir/livepool/1/proj" ] && fail "det: a live slot was leased"
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
make_submodule_case() {  # <name> <id> pushed|unpushed
  local dir="$TMP_ROOT/$1" id=$2 old sub2
  git init -q --bare "$dir.sub.git"
  git clone -q "$dir.sub.git" "$dir.subseed" 2>/dev/null
  git -C "$dir.subseed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s1
  git -C "$dir.subseed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s2
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
  git -C "$dir/old/proj" fetch -q origin
  git -C "$old" -c user.email=t@t -c user.name=t rebase -q origin/main >/dev/null 2>&1
  git -C "$old" submodule update --init -q >/dev/null 2>&1
  if [ "$3" = pushed ]; then
    git -C "$old/sub" checkout -q "$sub2"
  else
    git -C "$old/sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "only here"
  fi
  git -C "$old" add sub
  git -C "$old" -c user.email=t@t -c user.name=t commit -q -m "move the sub pin"
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

# One pool can hand out a slot of another clone first: that foreign slot is
# skipped and returned, and the move lands on the next slot of the live clone.
test_relaunch_skips_and_returns_a_foreign_slot() {
  local dir id=forn-a1 out rc=0
  dir=$(make_case forn "$id")
  OLDWT="$dir/oldpool/7/proj"
  printf 'foreign\nlive\n' > "$dir/lease-plan"
  out=$(run_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "forn: the relaunch failed: $out"
  assert_grep "worktree=$dir/livepool/2/proj" "$dir/home/state/$id.meta" "forn: the move did not land on the live clone's slot"
  grep -q "^return .*/forn/livepool/1/proj\$" "$dir/treehouse.log" || fail "forn: the foreign slot leased on the way was not returned"
  grep -q "^return .*/forn/livepool/2/proj\$" "$dir/treehouse.log" && fail "forn: the target slot was returned"
  pass "a relaunch's move skips and returns a foreign-clone slot and lands on the live clone"
}

# A pool with only a foreign slot to give: the relaunch refuses, and that
# foreign lease is returned rather than orphaned.
test_relaunch_returns_a_foreign_lease_when_no_live_slot_comes() {
  local dir id=only-a1 out rc=0 before
  dir=$(make_case only "$id")
  OLDWT="$dir/oldpool/7/proj"
  printf 'foreign\n' > "$dir/lease-plan"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "only: a relaunch with no live slot succeeded: $out"
  assert_contains "$out" "no free unclaimed slot of the live clone" "only: the refusal did not say no live slot came"
  grep -q "^return .*/only/livepool/1/proj\$" "$dir/treehouse.log" || fail "only: the foreign lease was orphaned"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "only: the record changed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "only: the old slot's claim was released"
  pass "a relaunch with no live slot returns the foreign lease it took"
}

# A live-clone slot whose lease lapsed but which another task still claims is
# never taken, overwritten or returned: the relaunch refuses.
test_relaunch_never_takes_a_slot_another_task_claims() {
  local dir id=clm-a1 out rc=0 before claim
  dir=$(make_case clm "$id")
  OLDWT="$dir/oldpool/7/proj"
  mkdir -p "$dir/livepool/1"
  git -C "$dir/home/projects/proj" worktree add -q --detach "$dir/livepool/1/proj" >/dev/null 2>&1
  (. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$dir/livepool/1/proj" other-a1 "$dir/home") || fail "clm: fixture: could not claim the slot for other-a1"
  claim=$(cat "$dir/livepool/1/.fm-slot-owner")
  printf 'path %s\n' "$dir/livepool/1/proj" > "$dir/lease-plan"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "clm: a relaunch moved into another task's slot: $out"
  assert_contains "$out" "which another task has claimed" "clm: the refusal did not name the claimed slot"
  assert_equals "$claim" "$(cat "$dir/livepool/1/.fm-slot-owner" 2>/dev/null)" "clm: other-a1's claim was changed or removed"
  grep -q "^return .*/clm/livepool/1/proj\$" "$dir/treehouse.log" && fail "clm: another task's slot was returned"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "clm: the record changed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "clm: the old slot's claim was released"
  pass "a relaunch never takes, overwrites or returns a slot another task claims"
}

test_relaunch_moves_an_old_clone_ship_onto_the_live_clone
test_relaunch_saves_and_refuses_a_dirty_old_copy
test_relaunch_skips_and_returns_a_foreign_slot
test_relaunch_returns_a_foreign_lease_when_no_live_slot_comes
test_relaunch_never_takes_a_slot_another_task_claims
test_relaunch_moves_submodules_to_the_recorded_commits
test_relaunch_refuses_an_unpushed_submodule_commit
test_relaunch_rollback_after_the_pane_moved_brings_the_pane_back
test_relaunch_refuses_a_copy_not_on_its_branch
test_relaunch_rolls_back_a_move_when_the_relaunch_refuses
test_relaunch_refuses_to_move_over_a_different_live_branch
test_relaunch_matches_origins_by_identity_not_spelling
test_relaunch_leaves_a_ship_whose_home_clone_is_another_origin
