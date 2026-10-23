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
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
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
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) [ -z "${FM_FAKE_PANE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_PANE_LOG"; exit 0 ;;
  capture-pane) printf '%s\n' '• Working (1s • esc to interrupt)'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
Decision owner: ep-sample

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
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  # A codex spawn records folder trust under HOME (bin/fm-codex-trust.sh), so
  # HOME is a throwaway and CODEX_HOME is cleared, never the developer's store.
  mkdir -p "$HOME_DIR/user-home"
  HOME="$HOME_DIR/user-home" CODEX_HOME='' \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
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
  assert_grep 'decision_owner=ep-sample' "$HOME_DIR/state/$id.meta" 'dispatch lost the declared decision owner'
  assert_grep 'Decision owner for this dispatch: ep-sample' "$HOME_DIR/data/$id/launch-brief.md" 'worker did not receive its decision owner'
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

# A pane that settles in a worktree of a DIFFERENT clone of the project -
# the mixed Treehouse pool shape, where one pool holds slots from two clones
# of one origin - must never be adopted: its git common dir is the other
# clone's, so a Claude worker there is refused by trust and a worker that
# skips trust works in the wrong clone. The spawn fails at the deadline
# naming the mismatch, and records nothing.
make_foreign_clone_case() {
  local name=$1 id=$2 case_dir home proj wt foreign_clone foreign_wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  foreign_clone="$case_dir/foreign-clone"
  foreign_wt="$case_dir/foreign-slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git clone --quiet "$proj" "$foreign_clone"
  git -C "$foreign_clone" worktree add --quiet -b "slot-$name" "$foreign_wt"
  fm_test_spawn_brief "$home" "$id" "Exercise foreign-clone slot rejection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$foreign_wt|$foreign_wt|$fakebin|$countfile|0"
}

test_foreign_clone_slot_is_never_accepted() {
  local rec id out status
  id=settle-foreign-clone-z5
  rec=$(make_foreign_clone_case settle-foreign-clone "$id")
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree of a different clone"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "different clone" \
    "the refusal did not name the foreign-clone mismatch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "foreign-clone spawn published task metadata"
  pass "a pane settled in a different clone's worktree is never accepted as the worktree"
}

# make_pool_case <name> <id> builds the mixed-pool shape: one Treehouse pool
# holds slot 1 as a worktree of a foreign clone of the project and slot 2 as
# a worktree of the project itself, both free in Treehouse's state. The pane
# is told whichever path the case's record carries.
make_pool_case() {
  local name=$1 id=$2 case_dir home proj wt pool foreign fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  pool="$case_dir/pool"
  foreign="$case_dir/foreign-clone"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$pool/1" "$pool/2"
  git -C "$proj" worktree add --quiet -b "ownslot-$name" "$pool/2/repo"
  git clone --quiet "$proj" "$foreign"
  git -C "$foreign" worktree add --quiet -b "foreignslot-$name" "$pool/1/repo"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}' \
    "$pool/1/repo" "$pool/2/repo" > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise mixed-pool slot steering for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$wt|$fakebin|$countfile|0"
}

# With a free slot of the project's own clone already in a mixed pool, the
# spawn enters that exact slot by name instead of taking the pool's first
# free slot from `treehouse get`, which belongs to the foreign clone.
test_mixed_pool_enters_free_own_slot() {
  local rec id out status pool own_slot pane_log
  id=settle-pool-own-slot-z6
  rec=$(make_pool_case settle-pool-own "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-own/pool"
  own_slot="$pool/2/repo"
  pane_log="$TMP_ROOT/settle-pool-own/pane.log"
  WT_DIR="$own_slot"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed in the pool's own-clone slot"$'\n'"$out"
  assert_grep "worktree=$own_slot" "$HOME_DIR/state/$id.meta" \
    "meta did not record the pool's own-clone slot"
  assert_grep 'treehouse enter' "$pane_log" \
    "spawn did not enter the free own-clone slot by name"
  assert_no_grep 'treehouse get' "$pane_log" \
    "spawn used treehouse get despite a free own-clone slot"
  pass "a mixed pool with a free own-clone slot is entered by exact slot name"
}

# When the pool's own-clone slot is already claimed by another task, the
# spawn keeps the plain `treehouse get` path and lands where the pane settles.
test_mixed_pool_claimed_own_slot_uses_treehouse_get() {
  local rec id out status pool pane_log
  id=settle-pool-claimed-z7
  rec=$(make_pool_case settle-pool-claimed "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-claimed/pool"
  pane_log="$TMP_ROOT/settle-pool-claimed/pane.log"
  printf 'task=some-other-task\nhome=%s\n' "$HOME_DIR" > "$pool/2/.fm-slot-owner"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is claimed"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was claimed"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered a slot another task has claimed"
  pass "a claimed own-clone slot is left alone and treehouse get is used instead"
}

# make_pool_grow_case <name> <id>: the pool's only own-clone slot (2) is
# claimed by another task and slot 1 is a free foreign slot. The fake
# Treehouse allocator hands out slot 1 on the first `get --lease`, then
# creates a new own-clone slot 3 on the second (a real worktree add, the
# same thing Treehouse's own create does), and logs every call.
make_pool_grow_case() {
  local name=$1 id=$2 case_dir home proj wt pool foreign fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  pool="$case_dir/pool"
  foreign="$case_dir/foreign-clone"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
case "$*" in
  *"get --lease"*)
    if [ ! -e "$FM_TREEHOUSE_GROW_MARKER" ]; then
      : > "$FM_TREEHOUSE_GROW_MARKER"
      printf '%s\n' "$FM_TREEHOUSE_FOREIGN_SLOT"
    else
      git -C "$FM_TREEHOUSE_PROJ" worktree add --quiet -b "grown-$FM_TREEHOUSE_ID" "$FM_TREEHOUSE_GROWN_SLOT" 2>/dev/null || true
      printf '%s\n' "$FM_TREEHOUSE_GROWN_SLOT"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$pool/1" "$pool/2"
  git -C "$proj" worktree add --quiet -b "ownslot-$name" "$pool/2/repo"
  git clone --quiet "$proj" "$foreign"
  git -C "$foreign" worktree add --quiet -b "foreignslot-$name" "$pool/1/repo"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}' \
    "$pool/1/repo" "$pool/2/repo" > "$pool/treehouse-state.json"
  printf 'task=some-other-task\nhome=%s\n' "$home" > "$pool/2/.fm-slot-owner"
  fm_test_spawn_brief "$home" "$id" "Exercise mixed-pool slot creation for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$wt|$fakebin|$countfile|0"
}

# With no free own-clone slot, the spawn leases the free foreign slot to
# advance Treehouse's allocator until it creates a new own-clone slot,
# enters that slot, and releases the foreign lease.
test_mixed_pool_makes_new_own_slot_when_none_free() {
  local rec id out status pool grown_slot pane_log th_log
  id=settle-pool-grow-z8
  rec=$(make_pool_grow_case settle-pool-grow "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-grow/pool"
  grown_slot="$pool/3/repo"
  pane_log="$TMP_ROOT/settle-pool-grow/pane.log"
  th_log="$TMP_ROOT/settle-pool-grow/treehouse.log"
  WT_DIR="$grown_slot"

  out=$(FM_FAKE_PANE_LOG="$pane_log" \
    FM_TREEHOUSE_LOG="$th_log" \
    FM_TREEHOUSE_GROW_MARKER="$TMP_ROOT/settle-pool-grow/.grown-marker" \
    FM_TREEHOUSE_FOREIGN_SLOT="$pool/1/repo" \
    FM_TREEHOUSE_GROWN_SLOT="$grown_slot" \
    FM_TREEHOUSE_PROJ="$PROJ_DIR" \
    FM_TREEHOUSE_ID="$id" \
    run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed in a newly made own-clone slot"$'\n'"$out"
  assert_grep "worktree=$grown_slot" "$HOME_DIR/state/$id.meta" \
    "meta did not record the newly made own-clone slot"
  assert_grep 'get --lease' "$th_log" \
    "spawn did not lease through the allocator to make an own-clone slot"
  assert_grep "return $pool/1/repo" "$th_log" \
    "spawn did not release the foreign slot it leased while steering"
  assert_grep 'treehouse enter' "$pane_log" \
    "spawn did not enter the newly made own-clone slot by name"
  pass "no free own-clone slot: the allocator is leased forward until Treehouse makes one"
}

# When the allocator hands the spawn a slot another task has claimed,
# the spawn must never hand it back: `treehouse return` terminates the
# processes inside its worktree, and the claiming task's worker may be
# starting there. The lease is left for that task's own teardown return.
test_allocator_claimed_slot_is_never_returned() {
  local rec id out status pool pane_log th_log
  id=settle-pool-claimed-lease-z9
  rec=$(make_pool_case settle-pool-claimed-lease "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-claimed-lease/pool"
  pane_log="$TMP_ROOT/settle-pool-claimed-lease/pane.log"
  th_log="$TMP_ROOT/settle-pool-claimed-lease/treehouse.log"
  printf 'task=some-other-task\nhome=%s\n' "$HOME_DIR" > "$pool/2/.fm-slot-owner"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
case "$*" in
  *"get --lease"*) printf '%s\n' "$FM_TREEHOUSE_CLAIMED_SLOT"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(FM_FAKE_PANE_LOG="$pane_log" \
    FM_TREEHOUSE_LOG="$th_log" \
    FM_TREEHOUSE_CLAIMED_SLOT="$pool/2/repo" \
    run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should still succeed through treehouse get"$'\n'"$out"
  assert_grep 'get --lease' "$th_log" \
    "spawn did not consult the allocator before falling back"
  assert_no_grep 'return ' "$th_log" \
    "spawn returned a slot another task has claimed (treehouse return kills its processes)"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get after the claimed slot"
  pass "a claimed slot handed over by the allocator is never returned"
}

# A free own-clone slot with residue is not entered: Treehouse's allocator
# would refuse to reuse it, and the spawn's base freshen would refuse to
# discard the work. The spawn keeps the plain `treehouse get` path, which
# can hand out or create a clean slot instead.
test_dirty_own_slot_is_not_entered() {
  local rec id out status pool pane_log
  id=settle-pool-dirty-z10
  rec=$(make_pool_case settle-pool-dirty "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-dirty/pool"
  pane_log="$TMP_ROOT/settle-pool-dirty/pane.log"
  printf 'residue\n' > "$pool/2/repo/untracked-residue"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is dirty"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled clean worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was dirty"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered a dirty own-clone slot the allocator would refuse"
  pass "a dirty own-clone slot is not entered"
}

# A clean own-clone slot whose HEAD carries commits outside the reset
# target is not entered either: entering it would let the base freshen
# reset those commits away. Again the plain `treehouse get` path owns it.
test_unmerged_own_slot_is_not_entered() {
  local rec id out status pool pane_log
  id=settle-pool-unmerged-z11
  rec=$(make_pool_case settle-pool-unmerged "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-unmerged/pool"
  pane_log="$TMP_ROOT/settle-pool-unmerged/pane.log"
  printf 'unmerged work\n' >> "$pool/2/repo/README.md"
  git -C "$pool/2/repo" add README.md
  git -C "$pool/2/repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'unmerged slot work'

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is unmerged"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled clean worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was unmerged"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered an unmerged own-clone slot the allocator would refuse"
  pass "an unmerged own-clone slot is not entered"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_foreign_clone_slot_is_never_accepted
test_mixed_pool_enters_free_own_slot
test_mixed_pool_claimed_own_slot_uses_treehouse_get
test_mixed_pool_makes_new_own_slot_when_none_free
test_allocator_claimed_slot_is_never_returned
test_dirty_own_slot_is_not_entered
test_unmerged_own_slot_is_not_entered

echo "# all fm-spawn-worktree-settle tests passed"
