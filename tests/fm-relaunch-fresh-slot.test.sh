#!/usr/bin/env bash
# A relaunch of an old-clone ship starts in a fresh slot of this home's own
# clone (<projects>/<name>) through the ordinary spawn path: a new slot, its
# claim and a new pane. The task's branch comes along at the old copy's HEAD,
# from origin when origin already holds it and otherwise fetched from the old
# copy, so unpushed commits are kept without being published. Nothing else
# crosses clones. Uncommitted work refuses in fm-control before any agent
# stops, and the old copy is returned once the new record names the new slot.
# (.agent-config-8wnyx.1: two paused GSP tasks hold 72 and 1 unpushed commits
# in copies of a clone this home no longer uses.)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-fresh-slot)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT

command -v jq >/dev/null 2>&1 || {
  echo "skip - the herdr adapter and the Treehouse pool reads need jq"
  exit 0
}

# The relaunch suite's herdr fake (its server, panes, agent registration and
# the one `tab create` that mints pane %9) and its tmux fake.
eval "$(awk '/^make_herdr_stub\(\) \{/,/^}/' "$ROOT/tests/fm-control-relaunch.test.sh")"
eval "$(awk '/^make_tmux_stub\(\) \{/,/^}/' "$ROOT/tests/fm-control-relaunch.test.sh")"
if ! command -v make_herdr_stub >/dev/null 2>&1 || ! command -v make_tmux_stub >/dev/null 2>&1; then
  echo "not ok - fixture: the relaunch suite's backend fakes were not found" >&2
  exit 1
fi

# Wrap the herdr fake so the pane follows a typed `treehouse enter <name>` into
# <case>/livepool/<name>/proj, as Treehouse's subshell would, opens a new tab
# in its --cwd, logs `pane close`, and has an agent come up when a launch file
# is run in the pane.
wrap_herdr_enter() {  # <case-dir>
  mv "$1/fakebin/herdr" "$1/fakebin/herdr.stub"
  {
    printf '#!/usr/bin/env bash\nCASE=%q\n' "$1"
    cat <<'SH'
if [ "${1:-} ${2:-}" = 'tab create' ]; then
  prev=
  for a in "$@"; do
    [ "$prev" != --cwd ] || printf '%s' "$a" > "$FM_FAKE_DIR/cwd"
    prev=$a
  done
fi
if [ "${1:-} ${2:-}" = 'pane send-text' ] || [ "${1:-} ${2:-}" = 'pane run' ]; then
  case "${4:-}" in
    'treehouse enter '*)
      name=${4#treehouse enter }
      name=${name//\'/}
      printf '%s' "$CASE/livepool/$name/proj" > "$FM_FAKE_DIR/cwd"
      ;;
    ". '"*) : > "$FM_FAKE_DIR/herdr-agent-live" ;;
  esac
fi
if [ "${1:-} ${2:-}" = 'pane close' ]; then
  printf '%s\n' "${3:-}" >> "$FM_FAKE_DIR/herdr-closed"
fi
exec "$(dirname "$0")/herdr.stub" "$@"
SH
  } > "$1/fakebin/herdr"
  chmod +x "$1/fakebin/herdr"
}

# A fake treehouse. `status --json` lists the slots under <case>/livepool
# (in-use when a .busy file sits beside the slot); `return --force` detaches
# the tree it returns. Every call goes to <case>/treehouse.log.
make_treehouse_fake() {  # <case-dir>
  {
    printf '#!/usr/bin/env bash\nCASE=%q\n' "$1"
    cat <<'SH'
printf '%s\n' "$*" >> "$CASE/treehouse.log"
case "$*" in
  "status --json")
    printf '['
    sep=
    for d in "$CASE"/livepool/*/proj; do
      [ -d "$d" ] || continue
      st=available
      [ ! -e "$(dirname "$d")/.busy" ] || st=in-use
      printf '%s{"name":"%s","path":"%s","status":"%s"}' "$sep" "$(basename "$(dirname "$d")")" "$d" "$st"
      sep=,
    done
    printf ']\n'
    ;;
  "return --force "*)
    # A returned tree is reset off its branch, as Treehouse's return does.
    git -C "${3:-}" checkout -q --detach 2>/dev/null || true
    ;;
esac
exit 0
SH
  } > "$1/fakebin/treehouse"
  chmod +x "$1/fakebin/treehouse"
}

# Add slot <n> to the live pool: a detached worktree at main of the live
# clone, listed in the pool's Treehouse state file.
add_slot() {  # <case-dir> <n>
  local dir=$1 n=$2 d sep=
  mkdir -p "$dir/livepool/$n"
  git -C "$dir/home/projects/proj" worktree add -q --detach "$dir/livepool/$n/proj" main >/dev/null 2>&1 || return 1
  {
    printf '{"worktrees":['
    for d in "$dir"/livepool/*/proj; do
      [ -d "$d" ] || continue
      printf '%s{"name":"%s","path":"%s"}' "$sep" "$(basename "$(dirname "$d")")" "$d"
      sep=,
    done
    printf ']}\n'
  } > "$dir/livepool/treehouse-state.json"
}

# A case: an origin, an old clone (old/proj) whose copy oldpool/7/proj is
# claimed by the task and holds its branch with one commit origin lacks, the
# home's live clone (home/projects/proj) with one free slot, and a herdr task
# record naming the old clone, its endpoint a pane (%7) with no agent in it.
# Sets CASE_DIR and OLDWT.
CASE_DIR=
OLDWT=
make_case() {  # <name> <id> [noslot]
  local dir="$TMP_ROOT/$1" id=$2 home
  home="$dir/home"
  OLDWT="$dir/oldpool/7/proj"
  CASE_DIR=$dir
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/old" "$dir/fakebin"
  touch "$home/state/.last-watcher-beat"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  make_herdr_stub "$dir"
  wrap_herdr_enter "$dir"
  make_treehouse_fake "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir/seed" push -q origin HEAD:main 2>/dev/null
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/old/proj" 2>/dev/null
  git clone -q "$dir/origin.git" "$home/projects/proj" 2>/dev/null
  mkdir -p "$dir/oldpool/7"
  git -C "$dir/old/proj" worktree add -q -b "fm/$id" "$OLDWT" >/dev/null 2>&1
  printf '{"worktrees":[{"name":"7","path":"%s"}]}\n' "$OLDWT" > "$dir/oldpool/treehouse-state.json"
  (. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$OLDWT" "$id" "$home") ||
    { echo "not ok - fixture: could not claim the old copy" >&2; exit 1; }
  printf 'work\n' > "$OLDWT/work.txt"
  git -C "$OLDWT" add work.txt
  git -C "$OLDWT" -c user.email=t@t -c user.name=t commit -q -m "the task's unpushed work"
  [ "${3:-}" = noslot ] || add_slot "$dir" 1 || { echo "not ok - fixture: could not add the live slot" >&2; exit 1; }
  fm_test_spawn_brief "$home" "$id"
  {
    echo "window=fmlab:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$OLDWT"
    echo "project=$dir/old/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "branch=fm/$id"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=fmlab"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$OLDWT" > "$dir/fake/cwd"
  printf '%s' '%7' > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
}

run_env() {  # <case-dir> <program> <args...>
  local dir=$1
  shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_PROJECTS_OVERRIDE='' \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' CODEX_HOME='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$@" 2>&1
}

run_spawn_relaunch() {  # <case-dir> <id>
  run_env "$1" "$SPAWN" "$2" --relaunch --harness claude
}

run_control_relaunch() {  # <case-dir> <id>
  run_env "$1" "$CONTROL" "$2" relaunch --note 'replacement continues the same task'
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

test_relaunch_starts_an_old_clone_ship_in_a_fresh_live_slot() {
  local dir id=fresh-a1 out rc=0 head_old slot live
  make_case fresh "$id"
  dir=$CASE_DIR
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  slot="$dir/livepool/1/proj"
  live=$(cd "$dir/home/projects/proj" && pwd -P)
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "fresh: the relaunch failed: $out"
  assert_equals "$live" "$(meta_field "$dir" "$id" project)" "fresh: the record does not name this home's clone"
  assert_equals "$slot" "$(meta_field "$dir" "$id" worktree)" "fresh: the record does not name the live slot"
  assert_equals "$head_old" "$(git -C "$slot" rev-parse HEAD)" "fresh: the slot is not at the old copy's HEAD"
  assert_equals "fm/$id" "$(git -C "$slot" branch --show-current)" "fresh: the slot is not on the ship branch"
  git -C "$dir/origin.git" rev-parse -q --verify "refs/heads/fm/$id" >/dev/null &&
    fail "fresh: the unpushed branch was pushed to origin"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] || fail "fresh: the live slot is not claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "fresh: the old copy's claim was not released"
  assert_equals 'fmlab:%9' "$(meta_field "$dir" "$id" window)" "fresh: the record does not name the new pane"
  assert_grep 'tab create' "$dir/fake/herdr-log" "fresh: no new pane was created"
  assert_grep "return --force $OLDWT" "$dir/treehouse.log" "fresh: the old copy was not returned"
  grep -q '^get' "$dir/treehouse.log" && fail "fresh: the relaunch asked treehouse get, which resets the tree it hands out"
  grep -Eq "^pane (run|send-text) %9 \\. '" "$dir/fake/herdr-log" || fail "fresh: the replacement was not launched in the new pane"
  pass "a relaunch starts an old-clone ship in a fresh live slot at the old copy's HEAD, unpublished"
}

# When origin's branch already holds the old copy's HEAD (and more), the slot
# starts at origin's tip: nothing is lost and nothing is fetched from the copy.
test_relaunch_takes_the_branch_from_origin_when_origin_has_it() {
  local dir id=origin-a1 out rc=0 tip
  make_case origin "$id"
  dir=$CASE_DIR
  git -C "$OLDWT" push -q origin "fm/$id" 2>/dev/null
  git clone -q "$dir/origin.git" "$dir/ahead" 2>/dev/null
  git -C "$dir/ahead" checkout -q "fm/$id"
  git -C "$dir/ahead" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "pushed from elsewhere"
  git -C "$dir/ahead" push -q origin "fm/$id" 2>/dev/null
  tip=$(git -C "$dir/ahead" rev-parse HEAD)
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "origin: the relaunch failed: $out"
  assert_equals "$tip" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "origin: the slot is not at origin's tip"
  pass "a relaunch takes the branch from origin when origin's branch holds the old copy's HEAD"
}

# The whole transaction, as Firstmate runs it: fm-control stops nothing (the
# agent already exited), launches the replacement in the fresh slot, sees it
# come up, and reports where the task now lives.
test_control_relaunches_an_old_clone_ship_into_a_fresh_slot() {
  local dir id=ctl-a1 out rc=0 head_old
  make_case ctl "$id"
  dir=$CASE_DIR
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  out=$(run_control_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "ctl: the relaunch failed: $out"
  assert_contains "$out" "worktree=$dir/livepool/1/proj" "ctl: fm-control did not report the fresh slot"
  assert_equals "$head_old" "$(git -C "$dir/livepool/1/proj" rev-parse HEAD)" "ctl: the slot is not at the old copy's HEAD"
  assert_grep 'phase=complete' "$dir/home/state/$id.control-relaunch" "ctl: the transaction did not complete"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] && fail "ctl: the old copy's claim was not released"
  pass "fm-control relaunches an old-clone ship into a fresh live slot end to end"
}

# Uncommitted work is never carried, so fm-control refuses before it stops
# the agent: the agent, its pane, its record and its copy are untouched.
test_control_refuses_uncommitted_work_before_stopping_the_agent() {
  local dir id=dirty-a1 out rc=0 before
  make_case dirty "$id"
  dir=$CASE_DIR
  : > "$dir/fake/herdr-agent-live"
  printf 'unsaved\n' > "$OLDWT/scratch.txt"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_control_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "dirty: a copy with uncommitted changes was relaunched: $out"
  assert_contains "$out" "uncommitted or untracked changes" "dirty: the refusal did not name the uncommitted work"
  assert_contains "$out" "Its agent was not stopped" "dirty: the refusal did not say the agent was left running"
  [ -e "$dir/fake/herdr-agent-live" ] || fail "dirty: the agent was stopped"
  grep -q 'pane send-text' "$dir/fake/herdr-log" && fail "dirty: something was typed into the agent's pane"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "dirty: the record changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "dirty: a live slot was claimed"
  assert_grep 'unsaved' "$OLDWT/scratch.txt" "dirty: the old copy's changes were touched"
  pass "fm-control refuses an old-clone relaunch with uncommitted work before stopping the agent"
}

# A submodule edit hidden by the submodule's ignore setting is still
# uncommitted work: the check reads with --ignore-submodules=none.
test_control_refuses_an_ignored_submodule_edit() {
  local dir id=subdirty-a1 out rc=0
  make_case subdirty "$id"
  dir=$CASE_DIR
  : > "$dir/fake/herdr-agent-live"
  git init -q "$dir/sub"
  git -C "$dir/sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m s1
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    git -C "$OLDWT" submodule add -q "$dir/sub" sub >/dev/null 2>&1
  git -C "$OLDWT" config -f .gitmodules submodule.sub.ignore all
  git -C "$OLDWT" add .gitmodules
  git -C "$OLDWT" -c user.email=t@t -c user.name=t commit -q -m "add sub"
  printf 'edit\n' > "$OLDWT/sub/edit.txt"
  [ -z "$(git -C "$OLDWT" status --porcelain)" ] || fail "subdirty: fixture: plain status already sees the edit, so this case proves nothing"
  out=$(run_control_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "subdirty: a copy with an ignored submodule edit was relaunched: $out"
  assert_contains "$out" "uncommitted or untracked changes" "subdirty: the refusal did not name the submodule edit"
  [ -e "$dir/fake/herdr-agent-live" ] || fail "subdirty: the agent was stopped"
  pass "fm-control refuses an old-clone relaunch whose submodule edit plain status ignores"
}

# A full live pool defers before the agent is stopped.
test_control_defers_on_a_full_live_pool_before_stopping_the_agent() {
  local dir id=full-a1 out rc=0
  make_case full "$id"
  dir=$CASE_DIR
  : > "$dir/fake/herdr-agent-live"
  printf 'max_trees = 1\n' > "$dir/home/projects/proj/treehouse.toml"
  printf 'treehouse.toml\n' >> "$dir/home/projects/proj/.git/info/exclude"
  : > "$dir/livepool/1/.busy"
  out=$(run_control_relaunch "$dir" "$id") || rc=$?
  expect_code 75 "$rc" "full: a full live pool did not defer: $out"
  assert_contains "$out" "worktree pool is full" "full: the deferral did not name the full pool"
  [ -e "$dir/fake/herdr-agent-live" ] || fail "full: the agent was stopped"
  assert_equals "$OLDWT" "$(meta_field "$dir" "$id" worktree)" "full: the record changed"
  pass "fm-control defers an old-clone relaunch on a full live pool before stopping the agent"
}

# A record whose worktree is a clean copy of another repository (on a branch
# of the right name) is refused before any agent stops, and that history is
# never imported: the old copy must belong to the recorded project.
test_control_refuses_a_worktree_of_another_repository() {
  local dir id=lineage-a1 out rc=0 before
  make_case lineage "$id"
  dir=$CASE_DIR
  : > "$dir/fake/herdr-agent-live"
  git init -q "$dir/unrelated"
  git -C "$dir/unrelated" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unrelated
  git -C "$dir/unrelated" checkout -q -b "fm/$id"
  sed -i.bak "s|^worktree=.*|worktree=$dir/unrelated|" "$dir/home/state/$id.meta" && rm -f "$dir/home/state/$id.meta.bak"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_control_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "lineage: a worktree of another repository was relaunched: $out"
  assert_contains "$out" "is not a worktree of its recorded project" "lineage: the refusal did not name the foreign worktree"
  [ -e "$dir/fake/herdr-agent-live" ] || fail "lineage: the agent was stopped"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "lineage: the record changed"
  rm -f "$dir/fake/herdr-agent-live"
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "lineage: fm-spawn relaunched a worktree of another repository: $out"
  assert_contains "$out" "is not a worktree of its recorded project" "lineage: fm-spawn's refusal did not name the foreign worktree"
  git -C "$dir/home/projects/proj" rev-parse -q --verify "refs/heads/fm/$id" >/dev/null &&
    fail "lineage: the other repository's branch was imported into this home's clone"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "lineage: a live slot was claimed"
  pass "an old-clone relaunch refuses a recorded worktree that belongs to another repository"
}

# A copy not on its ship branch is refused: the slot would start on a branch
# ref the copy's checkout does not match.
test_relaunch_refuses_a_copy_not_on_its_branch() {
  local dir id=det-a1 out rc=0 before
  make_case det "$id"
  dir=$CASE_DIR
  git -C "$OLDWT" checkout -q --detach HEAD~1
  before=$(cat "$dir/home/state/$id.meta")
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "det: a copy off its branch was relaunched: $out"
  assert_contains "$out" "does not have its branch fm/$id checked out" "det: the refusal did not name the branch"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "det: the record changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "det: a live slot was claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "det: the old copy's claim was released"
  pass "a relaunch refuses an old copy that does not have its branch checked out"
}

# A live-clone branch the old copy's history lacks is never moved over.
test_relaunch_refuses_a_live_branch_outside_the_copys_history() {
  local dir id=clash-a1 out rc=0 other
  make_case clash "$id"
  dir=$CASE_DIR
  git -C "$dir/home/projects/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m other
  git -C "$dir/home/projects/proj" branch "fm/$id" HEAD
  git -C "$dir/home/projects/proj" reset -q --hard HEAD~1
  other=$(git -C "$dir/home/projects/proj" rev-parse "fm/$id")
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "clash: the relaunch moved over a different live branch: $out"
  assert_contains "$out" "already has a branch fm/$id" "clash: the refusal did not name the branch"
  assert_equals "$other" "$(git -C "$dir/home/projects/proj" rev-parse "fm/$id")" "clash: the live clone's branch was changed"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "clash: a live slot was claimed"
  pass "a relaunch refuses a live-clone branch that is not in the old copy's history"
}

# A live-clone branch already in the old copy's history moves forward to it.
test_relaunch_moves_an_older_live_branch_forward() {
  local dir id=behind-a1 out rc=0 head_old
  make_case behind "$id"
  dir=$CASE_DIR
  git -C "$dir/home/projects/proj" branch "fm/$id" main
  head_old=$(git -C "$OLDWT" rev-parse HEAD)
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "behind: the relaunch failed: $out"
  assert_equals "$head_old" "$(git -C "$dir/home/projects/proj" rev-parse "fm/$id")" "behind: the live branch did not move forward to the copy's HEAD"
  pass "a relaunch moves a live-clone branch already in the copy's history forward"
}

# A failure after the slot is claimed and the branch checked out, before the
# new record (here fm-spawn's live-session check reads a person live), returns
# the slot and leaves the task exactly where it was: its record, its old copy
# and that copy's claim.
test_relaunch_deferred_before_the_record_returns_the_slot() {
  local dir id=back-a1 out rc=0 before
  make_case back "$id"
  dir=$CASE_DIR
  cat > "$dir/live-session.py" <<'PY'
print("a person is live")
raise SystemExit(75)
PY
  before=$(cat "$dir/home/state/$id.meta")
  out=$(FM_LIVE_SESSION_CHECK="$dir/live-session.py" run_spawn_relaunch "$dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "back: a deferred relaunch reported success: $out"
  assert_grep 'treehouse enter' "$dir/fake/herdr-log" "back: the pane never entered the live slot, so this case proves nothing"
  assert_equals "$before" "$(cat "$dir/home/state/$id.meta")" "back: the record changed"
  assert_grep "return --force $dir/livepool/1/proj" "$dir/treehouse.log" "back: the live slot was not returned"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "back: the live slot stays claimed"
  [ -e "$dir/oldpool/7/.fm-slot-owner" ] || fail "back: the old copy's claim was released"
  grep -q "return --force $OLDWT" "$dir/treehouse.log" && fail "back: the old copy was returned"
  pass "a relaunch deferred before its record is published returns the live slot and keeps the old copy"
}

# A ship whose home clone has another origin, and a tmux ship, relaunch where
# they are recorded, as before.
test_relaunch_leaves_other_origins_alone() {
  local dir id=other-a1 out rc=0
  make_case other "$id"
  dir=$CASE_DIR
  git -C "$dir/old/proj" remote set-url origin https://github.com/example-org/proj
  git -C "$dir/home/projects/proj" remote set-url origin https://github.com/example-org/another
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "other: the relaunch failed: $out"
  assert_equals "$OLDWT" "$(meta_field "$dir" "$id" worktree)" "other: a ship moved onto a clone of another repository"
  [ -e "$dir/livepool/1/.fm-slot-owner" ] && fail "other: a live slot was claimed"
  pass "a relaunch leaves a ship whose home clone has another origin where it is"
}

# One repository spelled two ways is one origin.
test_relaunch_matches_origins_by_identity() {
  local dir id=ident-a1 out rc=0
  make_case ident "$id"
  dir=$CASE_DIR
  git -C "$dir/old/proj" remote set-url origin "file://$dir/origin.git"
  out=$(run_spawn_relaunch "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "ident: the relaunch failed: $out"
  assert_equals "$dir/livepool/1/proj" "$(meta_field "$dir" "$id" worktree)" "ident: two spellings of one origin read as two"
  pass "a relaunch reads two spellings of one repository as one origin"
}

test_relaunch_starts_an_old_clone_ship_in_a_fresh_live_slot
test_relaunch_takes_the_branch_from_origin_when_origin_has_it
test_control_refuses_uncommitted_work_before_stopping_the_agent
test_control_refuses_an_ignored_submodule_edit
test_control_defers_on_a_full_live_pool_before_stopping_the_agent
test_relaunch_refuses_a_copy_not_on_its_branch
test_control_refuses_a_worktree_of_another_repository
test_relaunch_refuses_a_live_branch_outside_the_copys_history
test_relaunch_moves_an_older_live_branch_forward
test_relaunch_deferred_before_the_record_returns_the_slot
test_relaunch_leaves_other_origins_alone
test_relaunch_matches_origins_by_identity
test_control_relaunches_an_old_clone_ship_into_a_fresh_slot
