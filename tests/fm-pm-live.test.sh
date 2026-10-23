#!/usr/bin/env bash
# Tests for the live-PM registration: fm_pm_live_task's proof reading and
# the merged-outcome suppression that keeps a live PM's task off main's
# wake queue (its PM reports the merge itself).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-merge-outcome-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pm-live)

make_state() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  printf '%s\n' "$dir"
}

test_pm_live_proof_reading() {
  local dir state
  dir=$(make_state proof)
  state="$dir/home/state"

  fm_pm_live_task "$state" demo && fail "an absent registration read as a live PM"
  printf 'bead=b1\npid=%s\ntask=demo\n' "$$" > "$state/.pm-live-demo"
  fm_pm_live_task "$state" demo || fail "a fresh registration with a live pid did not read as a live PM"

  printf 'bead=b1\npid=999999\ntask=demo\n' > "$state/.pm-live-demo"
  fm_pm_live_task "$state" demo || fail "a fresh registration inside the re-arm grace did not read as a live PM"
  touch -t 202001010000 "$state/.pm-live-demo"
  fm_pm_live_task "$state" demo && fail "a stale registration with a dead pid read as a live PM"
  printf 'bead=b1\npid=%s\ntask=demo\n' "$$" > "$state/.pm-live-demo"
  touch -t 202001010000 "$state/.pm-live-demo"
  fm_pm_live_task "$state" demo && fail "a stale registration with a live pid (hung writer or reused pid) read as a live PM"

  printf 'bead=b1\npid=not-a-pid\ntask=demo\n' > "$state/.pm-live-demo"
  fm_pm_live_task "$state" demo && fail "a malformed registration read as a live PM"

  ln -s "$state/.pm-live-demo" "$state/.pm-live-linked"
  printf 'bead=b1\npid=%s\ntask=linked\n' "$$" > "$state/.pm-live-real"
  rm "$state/.pm-live-linked"
  ln -s "$state/.pm-live-real" "$state/.pm-live-linked"
  fm_pm_live_task "$state" linked && fail "a symlinked registration read as a live PM"
  pass "the live-PM proof reads live, grace, stale, malformed, and symlinked registrations exactly"
}

test_merged_outcome_skips_main_queue_for_live_pm() {
  local dir state url
  dir=$(make_state merged-pm)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/71
  printf 'bead=b1\npid=%s\ntask=demo\n' "$$" > "$state/.pm-live-demo"

  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "the live-PM merge outcome was not recorded"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a live PM's merged outcome queued a wake row for main: $(cat "$state/.wake-queue")"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] \
    || fail "the first live-PM merge outcome read as already recorded"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "the repeated live-PM merge outcome was not recorded"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] \
    || fail "the repeated live-PM merge outcome was not deduplicated by its notified marker"
  pass "a live PM's merged outcome is recorded and deduplicated without a main queue row"
}

test_merged_outcome_still_queues_for_plain_task() {
  local dir state url
  dir=$(make_state merged-plain)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/72

  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "the plain merge outcome was not recorded"
  grep -F 'check: merge landed: demo' "$state/.wake-queue" >/dev/null \
    || fail "a plain task's merged outcome did not queue its main wake row"
  pass "a plain task's merged outcome still queues the merge-landed wake for main"
}

test_pm_live_proof_reading
test_merged_outcome_skips_main_queue_for_live_pm
test_merged_outcome_still_queues_for_plain_task
