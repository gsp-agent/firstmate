#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
#
# The loop also has to notice a `treehouse get` that returns without entering a
# worktree, such as a full pool: the pane never moves, so only treehouse's own
# exit says the wait is over. The fake pane below runs the line fm-spawn sends
# it in a real shell, so a fake treehouse that prints the pool-full line and
# exits is seen exactly as a pane would show it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
# Its pane runs the `treehouse get` line it is sent in a real shell from
# FM_FAKE_PANE_PROJECT, appending what that prints to FM_FAKE_PANE_LOG for
# capture-pane, and its session keeps a window list in FM_FAKE_WINDOWS so a
# closed window is really gone. The fake treehouse follows FM_FAKE_TREEHOUSE:
# `pool-full` prints Treehouse's pool-full line and exits, and anything else
# opens a worktree subshell that, like the real one, holds the foreground for
# the worker's whole life, so the line that ran it never resumes.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
windows=${FM_FAKE_WINDOWS:?FM_FAKE_WINDOWS unset}
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) cat "$windows" 2>/dev/null ;;
  new-window)
    while [ "$#" -gt 0 ]; do
      [ "$1" != -n ] || printf '%s\n' "$2" >>"$windows"
      shift
    done
    printf '@1\n'
    ;;
  kill-window)
    grep -vxF -- "${3##*:=}" "$windows" >"$windows.next"
    mv "$windows.next" "$windows"
    ;;
  capture-pane) cat "${FM_FAKE_PANE_LOG:?}" 2>/dev/null ;;
  send-keys)
    case "${4:-}" in
      *"treehouse get"*)
        (cd "${FM_FAKE_PANE_PROJECT:?}" &&
          bash -c 'export FM_FAKE_PANE_SHELL=$$; eval "$1"' fake-pane "$4") >>"${FM_FAKE_PANE_LOG:?}" 2>&1
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '🌳 Setting up worktree...' >&2
if [ "${FM_FAKE_TREEHOUSE:-}" = pool-full ]; then
  printf '%s\n' "all 16 worktrees are in use or dirty (max_trees = 16). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
  exit 1
fi
kill -KILL "${FM_FAKE_PANE_SHELL:?}"
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_PROJECT="$PROJ_DIR" FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" \
    FM_FAKE_WINDOWS="$CASE_DIR/windows" FM_FAKE_TREEHOUSE="${FM_FAKE_TREEHOUSE:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# The 10-19 incident: `treehouse get` finds the pool full, says so, and exits at
# once, so the pane never leaves the project. The spawn must refuse on the first
# read after treehouse returned, quote treehouse's own line, and close the window
# it opened, so a retry is refused for the full pool again rather than for a
# leftover window.
test_pool_full_treehouse_get_refuses_at_once() {
  local rec id out status reads
  id=settle-pool-full-z5
  rec=$(make_settle_case settle-pool-full "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although treehouse get found the pool full"$'\n'"$out"
  assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" \
    "the refusal did not quote treehouse's own reason"
  assert_contains "$out" "$PROJ_DIR" "the refusal did not name the project whose pool is full"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 1 ] || fail "spawn read the pane $reads times after treehouse get had already exited - expected to refuse on the first read"$'\n'"$out"
  assert_no_grep "fm-$id" "$CASE_DIR/windows" "the refused spawn left its window behind"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"

  out=$(FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
  assert_not_contains "$out" "already exists" "a retry was refused for the first attempt's leftover window"
  assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" \
    "a retry did not reach treehouse get again"
  pass "a treehouse get that exits on a full pool refuses at once with treehouse's reason and leaves no window"
}

# A slow but working `treehouse get` prints while it fetches and sets up the
# slot, and the pane stays on the project the whole time. Treehouse output is not
# an exit, so the spawn keeps waiting and launches once the pane reaches the
# worktree.
test_slow_treehouse_get_still_launches() {
  local rec id out status
  id=settle-slow-z6
  rec=$(make_settle_case settle-slow "$id" 40)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should launch once a slow treehouse get reaches the worktree"$'\n'"$out"
  assert_grep "Setting up worktree" "$CASE_DIR/pane.log" "the fake pane never ran treehouse get"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the slow treehouse get entered"
  grep -qxF -- "fm-$id" "$CASE_DIR/windows" || fail "the launched worker's window is missing"
  pass "a slow but working treehouse get still launches"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_pool_full_treehouse_get_refuses_at_once
test_slow_treehouse_get_still_launches

echo "# all fm-spawn-worktree-settle tests passed"
