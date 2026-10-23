#!/usr/bin/env bash
# .agent-config-m4t5e: pre-PR29 captain holds carry no Decision owner, so
# route-due never hands them on. backfill-owners derives the owner from the
# hold's own text or its project's EP and writes the routing fields.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=${FM_TEST_KEEP:-$(fm_test_tmproot fm-captain-hold-backfill)}
export FM_HOLD_DOMAIN_ROUTER="$TMP_ROOT/no-router.py"
TASKS_AXI_BIN=$(command -v tasks-axi || true)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

strip_owner_fields() {  # <home>: make holds read as pre-PR29 rows
  local home=$1
  grep -v -E '^ *(Decision owner|Hold timeout seconds|Hold reason): ' "$home/data/backlog.md" \
    > "$home/data/backlog.md.tmp" && mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
}

test_backfill_derives_owner() {
  local home out body
  home=$(make_home backfill)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-widget --reason "waiting on a go for update-branch" >/dev/null
  strip_owner_fields "$home"
  out=$(run_captain "$home" backfill-owners)
  printf '%s\n' "$out" | grep -q 'sample-widget owner=ep-sample source=project-ep' \
    || fail "backfill did not derive the project EP: $out"
  body=$(tasks_in "$home" show sample-widget --full)
  printf '%s\n' "$body" | grep -q 'Decision owner: ep-sample' \
    || fail "owner field not written: $body"
  printf '%s\n' "$body" | grep -q 'Hold timeout seconds: 300' \
    || fail "timeout field not written: $body"
  out=$(run_captain "$home" backfill-owners)
  printf '%s\n' "$out" | grep -q 'sample-widget kept owner=ep-sample' \
    || fail "second backfill was not a no-op: $out"
  pass "backfill writes the project EP and is idempotent"
}

test_backfill_named_seat_and_dale() {
  local home out body
  home=$(make_home named)
  tasks_in "$home" add named-widget "Ship the named widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold named-widget \
    --reason "asked ep-sample-lead in the pane; waiting on its answer" >/dev/null
  tasks_in "$home" add dale-widget "Ship the dale widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold dale-widget \
    --reason "needs Dale's credential for the client account" >/dev/null
  strip_owner_fields "$home"
  out=$(run_captain "$home" backfill-owners)
  printf '%s\n' "$out" | grep -q 'named-widget owner=ep-sample-lead source=named' \
    || fail "named seat not derived: $out"
  printf '%s\n' "$out" | grep -q 'dale-widget owner=captain source=dale' \
    || fail "Dale-only hold not kept captain-owned: $out"
  body=$(tasks_in "$home" show dale-widget --full)
  printf '%s\n' "$body" | grep -q 'Decision owner: captain' \
    || fail "Dale-only owner not written: $body"
  pass "backfill names a seat from the text and keeps Dale-only holds captain-owned"
}

test_backfill_skips_row_without_stamp() {
  local home out body
  home=$(make_home nostamp)
  tasks_in "$home" add nostamp-widget "Ship the nostamp widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold nostamp-widget --reason "waiting on a go" >/dev/null
  strip_owner_fields "$home"
  grep -v '^  Captain hold set: ' "$home/data/backlog.md" > "$home/data/backlog.md.tmp" \
    && mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  tasks_in "$home" add later-widget "Ship the later widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold later-widget --reason "waiting on a go" >/dev/null
  strip_owner_fields "$home"
  out=$(run_captain "$home" backfill-owners) \
    || fail "backfill exited on a stamp-less row: $out"
  printf '%s\n' "$out" | grep -q 'later-widget owner=ep-sample' \
    || fail "row after the stamp-less one was not backfilled: $out"
  out=$(run_captain "$home" backfill-owners) \
    || fail "backfill re-run exited on a stamp-less row: $out"
  printf '%s\n' "$out" | grep -q 'later-widget kept owner=ep-sample' \
    || fail "re-run did not reach the later row: $out"
  pass "backfill skips a stamp-less row and continues the sweep"
}

test_backfill_fails_on_unreadable_backlog() {
  local home out status=0
  home=$(make_home unreadable)
  rm -rf "$home/data"
  printf 'not a directory\n' > "$home/data"
  out=$(run_captain "$home" backfill-owners 2>&1) || status=$?
  [ "$status" != 0 ] || fail "backfill reported success on an unreadable backlog: $out"
  printf '%s\n' "$out" | grep -q 'could not list captain holds' \
    || fail "backfill did not name the list failure: $out"
  pass "backfill fails when the backlog cannot be listed"
}

test_backfill_row_failure_does_not_strand_later_rows() {
  local home out status=0 body id
  home=$(make_home rowfail)
  for id in first-widget bad-widget last-widget; do
    tasks_in "$home" add "$id" "Ship the $id" --kind ship --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting on a go" >/dev/null
  done
  strip_owner_fields "$home"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = bad-widget ]; then
  echo "simulated backend failure" >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  out=$(run_captain "$home" backfill-owners 2>&1) || status=$?
  [ "$status" != 0 ] || fail "backfill reported success when a row write failed: $out"
  printf '%s\n' "$out" | grep -q 'bad-widget' \
    || fail "failed row was not named: $out"
  for id in first-widget last-widget; do
    body=$(tasks_in "$home" show "$id" --full)
    printf '%s\n' "$body" | grep -q 'Decision owner: ep-sample' \
      || fail "row $id was stranded by the bad row: $out"
  done
  pass "a failed row is reported and later rows still backfill"
}

test_backfill_preserves_long_reason() {
  local home out body long_reason
  home=$(make_home longreason)
  long_reason="waiting on a go for the full end-to-end verification pass over every surface named in the call, including the second and third checks, before anyone touches the branch again, and then a final read of the whole record so the routing reason survives exactly as written here today, word for word, without any shortening at all"
  tasks_in "$home" add long-widget "Ship the long widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold long-widget --reason "$long_reason" >/dev/null
  strip_owner_fields "$home"
  out=$(run_captain "$home" backfill-owners) || fail "backfill failed on a long reason: $out"
  body=$(tasks_in "$home" show long-widget --full)
  printf '%s\n' "$body" | grep -q "Hold reason: $long_reason" \
    || fail "long routing reason was not preserved whole: $body"
  pass "backfill preserves a long routing reason whole"
}

test_backfill_derives_owner
test_backfill_named_seat_and_dale
test_backfill_skips_row_without_stamp
test_backfill_fails_on_unreadable_backlog
test_backfill_row_failure_does_not_strand_later_rows
test_backfill_preserves_long_reason
echo "all fm-captain-hold-backfill tests passed"
