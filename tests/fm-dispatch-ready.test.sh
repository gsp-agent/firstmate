#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-ready.sh: the Dispatch line a cleanup or a
# recorded PR handoff prints names the project's free places by
# bin/fm-spawn.sh's own count (bin/fm-project-capacity-lib.sh) and the ready
# backlog rows waiting for one.
#
# The failing-first case is the stall this exists for: the backlog listed more
# in-flight rows than the project's cap (merged rows nobody closed, workers
# whose PR had already freed their place), main counted those rows, called the
# project full, and ready tasks waited hours beside free places. Every case drives
# the real helper against a real markdown backlog through tasks-axi and a real
# project clone with an origin; only the crew-state reader is a stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND TASKS_AXI_FILE || :

HELPER="$ROOT/bin/fm-dispatch-ready.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-ready)

if ! command -v tasks-axi >/dev/null 2>&1; then
  printf 'ok - skipped: tasks-axi is not installed\n'
  exit 0
fi

# --- fixture ----------------------------------------------------------------

# A case: one home with an empty markdown backlog, a project clone with an
# origin, and a crew-state stub that answers from each task's status log.
make_case() {  # <name> -> case dir
  local case_dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/data"
  touch "$case_dir/home/state/.last-watcher-beat"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/fm-crew-state-stub" <<'SH'
#!/usr/bin/env bash
line=$(tail -1 "$FM_STATE_OVERRIDE/$1.status" 2>/dev/null) || line=''
case "$line" in
  working*) echo "state: working - source: status-log - fixture" ;;
  paused*) echo "state: paused - source: status-log - fixture" ;;
  *) echo "state: unknown - source: none - fixture" ;;
esac
SH
  chmod +x "$fakebin/fm-crew-state-stub"
  fm_git_init_commit "$case_dir/proj"
  fm_git_add_origin "$case_dir/proj" "$case_dir/proj.origin.git"
  printf '%s\n' "$case_dir"
}

axi() {  # <case-dir> <tasks-axi args...>
  local case_dir=$1
  shift
  tasks-axi "$@" --file "$case_dir/home/data/backlog.md" >/dev/null ||
    fail "fixture tasks-axi $* failed"
}

# A worker record as bin/fm-spawn.sh publishes it, with its row In flight.
# <status> is the newest status line; extra key=value lines follow.
write_worker() {  # <case-dir> <id> <status> [extra-line...]
  local case_dir=$1 id=$2 status=$3
  shift 3
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$case_dir/proj" \
    "project=$case_dir/proj" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "spawn_gen=s-$id" "$@"
  printf '%s\n' "$status" > "$case_dir/home/state/$id.status"
  axi "$case_dir" add "$id" "worker $id" --kind ship --repo proj --start
}

declare_capacity() {  # <case-dir> <line>...
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/home/config/project-capacity"
}

run_helper() {  # <case-dir> [helper args...] (project defaults to the clone)
  local case_dir=$1
  shift
  [ "$#" -gt 0 ] || set -- "$case_dir/proj"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_ROOT_OVERRIDE='' FM_PROJECT_CAPACITY_CREW_STATE="$case_dir/fakebin/fm-crew-state-stub" \
    PATH="$case_dir/fakebin:$PATH" "$HELPER" "$@" 2>"$case_dir/stderr"
}

in_flight_rows() {  # <case-dir>
  tasks-axi list --file "$1/home/data/backlog.md" 2>/dev/null | grep -c ',in_flight,' || true
}

# --- cases ------------------------------------------------------------------

test_free_places_are_counted_by_spawns_rule_not_backlog_rows() {
  local case_dir out rc
  case_dir=$(make_case stale-rows)
  declare_capacity "$case_dir" "proj 2"
  # One worker still working holds a place. One recorded its PR and one is
  # paused, so neither does, and a merged row nobody closed has no record.
  write_worker "$case_dir" busy-1 'working [at=1790000000]: building'
  write_worker "$case_dir" pr-raised 'working [at=1790000000]: answering review' \
    "pr=https://github.com/example/proj/pull/7"
  write_worker "$case_dir" parked-1 'paused [at=1790000000]: waiting on review'
  axi "$case_dir" add merged-unclosed "merged long ago" --kind ship --repo proj --start
  axi "$case_dir" add ready-a "first ready" --kind ship --repo proj
  axi "$case_dir" add ready-b "second ready" --kind scout --repo proj
  axi "$case_dir" add held-c "held for the captain" --kind ship --repo proj
  axi "$case_dir" hold held-c --reason "captain decision pending" --kind captain
  axi "$case_dir" add blocked-d "waits on ready-a" --kind ship --repo proj --blocked-by ready-a
  axi "$case_dir" add elsewhere-e "another project's work" --kind ship --repo other-proj

  # The stall's premise: counting in-flight rows reads the project as full.
  [ "$(in_flight_rows "$case_dir")" -ge 2 ] || fail "fixture: in-flight rows do not exceed the cap"

  out=$(run_helper "$case_dir")
  rc=$?
  expect_code 0 "$rc" "stale-rows: helper exit"
  assert_contains "$out" "Dispatch: proj has 1 of 2 places free by bin/fm-spawn.sh's own count (holding: busy-1)" \
    "stale-rows: the count is not bin/fm-spawn.sh's rule"
  assert_contains "$out" "Ready for it, in backlog order: ready-a, ready-b." "stale-rows: ready rows or their order"
  assert_contains "$out" "start it now with bin/fm-spawn.sh" "stale-rows: the line does not say to start them"
  assert_contains "$out" "never a count of backlog rows" "stale-rows: the line does not forbid counting rows"
  assert_contains "$out" "Dispatch: 1 more ready row(s) name other projects: elsewhere-e (other-proj)." \
    "stale-rows: other projects' ready rows"
  assert_not_contains "$out" "held-c" "stale-rows: a held row was offered"
  assert_not_contains "$out" "blocked-d" "stale-rows: a blocked row was offered"
  assert_not_contains "$out" "merged-unclosed" "stale-rows: an in-flight row was offered"
  pass "free places come from bin/fm-spawn.sh's count, not the in-flight rows that read the project full"
}

test_full_project_names_its_ready_rows_and_waits() {
  local case_dir out
  case_dir=$(make_case full)
  declare_capacity "$case_dir" "proj 1"
  write_worker "$case_dir" busy-1 'working [at=1790000000]: building'
  axi "$case_dir" add ready-a "first ready" --kind ship --repo proj
  out=$(run_helper "$case_dir") || fail "full: helper failed"
  assert_contains "$out" "proj has 0 of 1 places free" "full: count"
  assert_contains "$out" "Ready for it, in backlog order: ready-a. Nothing starts until a place frees" "full: wait wording"
  assert_not_contains "$out" "start it now" "full: told to start into a full project"
  pass "a full project names its ready rows and says nothing starts until a place frees"
}

test_uncapped_project_starts_everything_and_if_capped_is_silent() {
  local case_dir out
  case_dir=$(make_case uncapped)
  axi "$case_dir" add ready-a "first ready" --kind ship --repo proj
  out=$(run_helper "$case_dir") || fail "uncapped: helper failed"
  assert_contains "$out" "Dispatch: proj declares no place limit. Ready for it, in backlog order: ready-a." "uncapped: line"
  assert_contains "$out" "start it now with bin/fm-spawn.sh" "uncapped: start wording"
  out=$(run_helper "$case_dir" --if-capped "$case_dir/proj") || fail "uncapped: --if-capped failed"
  assert_equals "" "$out" "uncapped: --if-capped printed for an unlimited project"
  pass "an unlimited project is told to start its ready rows, and --if-capped stays silent for it"
}

test_zero_places_hold_ready_work_back() {
  local case_dir out
  case_dir=$(make_case zero)
  declare_capacity "$case_dir" "proj 0"
  axi "$case_dir" add ready-a "first ready" --kind ship --repo proj
  out=$(run_helper "$case_dir") || fail "zero: helper failed"
  assert_contains "$out" "proj declares 0 places, so nothing starts for it. Ready for it, held back by that declaration: ready-a." "zero: line"
  assert_not_contains "$out" "start it now" "zero: told to start under a 0 declaration"
  pass "a project declared at 0 places holds its ready rows back"
}

test_no_ready_rows_says_so() {
  local case_dir out
  case_dir=$(make_case none-ready)
  declare_capacity "$case_dir" "proj 3"
  out=$(run_helper "$case_dir") || fail "none-ready: helper failed"
  assert_equals "Dispatch: proj has 3 of 3 places free by bin/fm-spawn.sh's own count; no ready backlog row names it." \
    "$out" "none-ready: line"
  pass "a project with free places and no ready rows says so in one line"
}

test_firstmate_rows_match_only_a_firstmate_lineage_project() {
  local case_dir out
  case_dir=$(make_case self-repo)
  # A clone sharing this code root's history is firstmate's own repository.
  git clone --quiet --shared --no-checkout "$ROOT" "$case_dir/firstmate-clone" ||
    fail "self-repo: could not clone the code root"
  axi "$case_dir" add fm-ready "a firstmate fix" --kind ship --repo firstmate
  out=$(run_helper "$case_dir" "$case_dir/firstmate-clone") || fail "self-repo: helper failed"
  assert_contains "$out" "Ready for it, in backlog order: fm-ready." "self-repo: firstmate row not matched"
  out=$(run_helper "$case_dir") || fail "self-repo: helper failed on the unrelated project"
  assert_contains "$out" "no ready backlog row names it" "self-repo: firstmate row matched an unrelated project"
  assert_contains "$out" "fm-ready (firstmate)" "self-repo: firstmate row missing from other projects"
  pass "a repo: firstmate row belongs to a project of firstmate's lineage only"
}

test_failed_reads_are_named_and_never_fail_the_caller() {
  local case_dir out rc
  case_dir=$(make_case failed-reads)
  printf '%s\n' "proj two" > "$case_dir/home/config/project-capacity"
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  out=$(run_helper "$case_dir")
  rc=$?
  expect_code 0 "$rc" "failed-reads: helper exit"
  assert_contains "$out" "proj's places could not be counted" "failed-reads: count failure not named"
  assert_contains "$out" "Its ready rows could not be read" "failed-reads: backlog failure not named"
  assert_contains "$out" "until one defers with exit 75" "failed-reads: no instruction left"
  pass "an unreadable declaration and backlog are named in the line and exit 0"
}

test_bad_request_exits_2() {
  local case_dir rc=0
  case_dir=$(make_case bad-request)
  run_helper "$case_dir" "$case_dir/missing" >/dev/null || rc=$?
  expect_code 2 "$rc" "bad-request: missing project"
  rc=0
  run_helper "$case_dir" a b >/dev/null || rc=$?
  expect_code 2 "$rc" "bad-request: two projects"
  pass "a missing project or extra arguments exit 2"
}

# The instruction surfaces carry both halves of the repair: bin/fm-spawn.sh
# alone judges capacity, and a merged task is cleaned up in its merge wake's
# own turn (a merged task stayed in flight for hours after main deferred its
# cleanup to a later turn that never came).
# shellcheck disable=SC2016 # the backquoted names are literal instruction text.
test_instructions_carry_the_dispatch_and_merge_cleanup_rules() {
  local agents skill prompt
  agents=$(cat "$ROOT/AGENTS.md")
  skill=$(cat "$ROOT/.agents/skills/ship-landing/SKILL.md")
  prompt=$(cat "$ROOT/bin/fm-branch-prompt.sh")
  assert_contains "$agents" '`bin/fm-spawn.sh` alone judges project capacity: never decide a project is full by counting backlog rows' \
    "AGENTS.md lost the only-admitter rule"
  assert_contains "$agents" 'until a spawn defers with exit 75' "AGENTS.md lost the start-until-deferred rule"
  assert_contains "$agents" 'a `check: merge landed:` task is cleaned up in that same turn' "AGENTS.md lost the merge cleanup rule"
  assert_contains "$skill" 'run `bin/fm-teardown.sh <id>` with no flags in that same turn' "ship-landing lost the same-turn cleanup"
  assert_contains "$skill" 'is filed as its own task and never kept as a reason to leave the merged one in place' \
    "ship-landing lost the post-merge-check rule"
  assert_contains "$prompt" '`Dispatch:` lines copied verbatim' "branch prompt lost the Dispatch relay"
  pass "AGENTS.md, ship-landing and the branch prompt carry the dispatch and merge-cleanup rules"
}

test_free_places_are_counted_by_spawns_rule_not_backlog_rows
test_full_project_names_its_ready_rows_and_waits
test_uncapped_project_starts_everything_and_if_capped_is_silent
test_zero_places_hold_ready_work_back
test_no_ready_rows_says_so
test_firstmate_rows_match_only_a_firstmate_lineage_project
test_failed_reads_are_named_and_never_fail_the_caller
test_bad_request_exits_2
test_instructions_carry_the_dispatch_and_merge_cleanup_rules
