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

test_backfill_derives_owner
test_backfill_named_seat_and_dale
echo "all fm-captain-hold-backfill tests passed"
