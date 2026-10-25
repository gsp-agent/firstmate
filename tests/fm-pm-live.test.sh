#!/usr/bin/env bash
# Tests for the live-PM registration: fm_pm_live_task's proof reading and
# the merged-outcome handoff to that PM's existing task status stream.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-merge-outcome-lib.sh"

# Stub only the recovery classifier; task identity, locks, and publication are real.
fm_backend_agent_state() { cat "$2.agent-state"; }

TMP_ROOT=$(fm_test_tmproot fm-pm-live)

make_state() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  printf '%s\n' "$dir"
}

write_pm_task() {  # <state> <url> [spawn-generation]
  local state=$1 url=$2 generation=${3:-first}
  printf 'project=example\nwindow=%s/demo\nspawn_gen=%s\npr=%s\n' "$state" "$generation" "$url" > "$state/demo.meta"
  printf 'alive\n' > "$state/demo.agent-state"
  printf 'bead=example-acceptance\npid=%s\ntask=demo\n' "$$" > "$state/.pm-live-demo"
  [ -e "$state/demo.status" ] || printf 'done: PR ready for merge\n' > "$state/demo.status"
}

assert_pm_handoff() {  # <state> <url> [spawn-generation]
  local state=$1 url=$2 generation=${3:-first} line
  line=$(tail -n 1 "$state/demo.status")
  [ "$(status_line_verb "$line")" = note ] || fail "merge handoff falsely declared task completion: $line"
  case "$line" in
    *"merged demo $url spawn_gen=$generation; activation and live verification pending"*) ;;
    *) fail "PM did not receive the current task/PR/incarnation handoff: $line" ;;
  esac
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
  write_pm_task "$state" "$url"

  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "the live-PM merge outcome was not recorded"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a live PM's merged outcome queued a wake row for main: $(cat "$state/.wake-queue")"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] \
    || fail "the first live-PM merge outcome read as already recorded"
  assert_pm_handoff "$state" "$url"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "the repeated live-PM merge outcome was not recorded"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] \
    || fail "the repeated live-PM merge outcome was not deduplicated by its notified marker"
  [ "$(wc -l < "$state/demo.status" | tr -d ' ')" = 2 ] \
    || fail "a duplicate merge delivered a second PM handoff"
  pass "a live PM receives one pending-verification status handoff without a main queue row"
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

test_failed_handoff_remains_retryable() {
  local dir state url
  dir=$(make_state failed-handoff)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/73
  write_pm_task "$state" "$url"
  mv "$state/demo.status" "$state/original.status"
  mkdir "$state/demo.status"
  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" self; then
    fail "an unwritable PM stream was acknowledged as delivered"
  fi
  [ ! -e "$state/demo.pr-poll-merge-notified" ] || fail "failed delivery committed its notification marker"
  [ ! -s "$state/.wake-queue" ] || fail "failed PM delivery created a second owner on main"
  mv "$state/demo.status" "$state/failed-destination"
  mv "$state/original.status" "$state/demo.status"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "a repaired PM destination did not retry on the same task"
  assert_pm_handoff "$state" "$url"
  pass "a failed PM handoff stays unacknowledged and retries on the same task"
}

test_failed_marker_does_not_duplicate_handoff() {
  local dir state url
  dir=$(make_state failed-marker)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/74
  write_pm_task "$state" "$url"
  mkdir "$state/demo.pr-poll-merge-notified"
  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" self; then
    fail "failed notification acknowledgement returned success"
  fi
  assert_pm_handoff "$state" "$url"
  mv "$state/demo.pr-poll-merge-notified" "$state/failed-marker"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "notification acknowledgement did not retry"
  [ "$(wc -l < "$state/demo.status" | tr -d ' ')" = 2 ] \
    || fail "retry after failed acknowledgement duplicated the owner handoff"
  pass "a failed acknowledgement preserves the delivered event and retry deduplicates it"
}

test_existing_marker_repairs_missing_pm_event() {
  local dir state url
  dir=$(make_state old-marker)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/75
  write_pm_task "$state" "$url"
  fm_pr_poll_merge_mark_notified "$state" demo github github.com example/repo 75 \
    || fail "could not seed a legacy suppressed notification"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
    || fail "an existing marker hid the missing PM handoff"
  assert_pm_handoff "$state" "$url"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] || fail "the repaired notification lost its existing marker identity"
  pass "replay repairs the PM event even when a legacy notification marker already exists"
}

test_stale_pr_and_reused_task_identity() {
  local dir state old_url new_url snapshot
  dir=$(make_state reused-task)
  state="$dir/home/state"
  old_url=https://github.com/example/repo/pull/76
  new_url=https://github.com/example/other/pull/77
  write_pm_task "$state" "$old_url" old
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$old_url" self \
    || fail "first incarnation did not receive its handoff"
  write_pm_task "$state" "$new_url" replacement
  snapshot=$(cat "$state/demo.status")
  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$old_url" poll; then
    fail "an older PR was delivered against a replacement task"
  fi
  [ "$(cat "$state/demo.status")" = "$snapshot" ] || fail "stale PR wrote an event for the wrong incarnation"
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$new_url" poll \
    || fail "replacement task did not receive its own PR"
  assert_pm_handoff "$state" "$new_url" replacement
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] || fail "an older task marker swallowed a different PR"
  write_pm_task "$state" "$new_url" next
  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$new_url" poll \
    || fail "new incarnation could not receive its own identity-bound handoff"
  assert_pm_handoff "$state" "$new_url" next
  [ "$(wc -l < "$state/demo.status" | tr -d ' ')" = 4 ] \
    || fail "reused identities either duplicated or suppressed an incarnation"
  mv "$state/demo.meta" "$state/retired.meta"
  snapshot=$(cat "$state/demo.status")
  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$old_url" poll; then
    fail "absent metadata widened handoff identity to an older PR"
  fi
  [ "$(cat "$state/demo.status")" = "$snapshot" ] || fail "absent metadata created a wrong-task event"
  pass "stale PRs and missing records are refused; reused tasks receive explicit current incarnation/PR identity"
}

test_restart_and_concurrent_delivery() {
  local dir state url runner
  dir=$(make_state restart)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/78
  write_pm_task "$state" "$url"
  runner="$dir/report.sh"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
set -eu
. "$1/bin/fm-merge-outcome-lib.sh"
fm_backend_agent_state() { cat "$2.agent-state"; }
fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" demo "$2" self
SH
  # Independent processes stand in for redelivery after a crash, with no
  # watcher, periodic sweep, updater or second verification worker running.
  if ! FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" python3 - "$runner" "$ROOT" "$url" <<'PY'
import subprocess
import sys
children = [subprocess.Popen(["bash", *sys.argv[1:]]) for _ in range(3)]
codes = [child.wait() for child in children]
if any(codes):
    raise SystemExit("redelivery failed: " + repr(codes))
PY
  then
    fail "concurrent merge delivery failed"
  fi
  assert_pm_handoff "$state" "$url"
  [ "$(wc -l < "$state/demo.status" | tr -d ' ')" = 2 ] || fail "restart or concurrent delivery duplicated the event"
  # Verification failure belongs to the same owner and must not be replaced
  # with another merge notification or inferred success on replay.
  printf 'blocked: activation failed; same owner must retry\n' >> "$state/demo.status"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash "$runner" "$ROOT" "$url" \
    || fail "restart could not read the persisted handoff"
  [ "$(tail -n 1 "$state/demo.status")" = 'blocked: activation failed; same owner must retry' ] \
    || fail "merge replay replaced an activation failure with completion"
  [ ! -s "$state/.wake-queue" ] || fail "redelivery created a second main owner"
  pass "restart and concurrent delivery keep one event and leave activation failures with the existing owner"
}

# Teardown archives a task record at data/<id>/record/closed-task.meta, then
# removes the record and its status stream. A merge that reaches such a task
# afterwards must not hand activation and live verification to an owner that
# no longer exists: the live PM is told on the stream its waiter watches, the
# outcome stays unacknowledged, and nothing binds a merge the archive does not
# name.
test_merge_after_close_tells_the_pm_instead_of_handing_off_into_nothing() {
  local dir state url archive line
  dir=$(make_state closed-before-merge)
  state="$dir/home/state"
  url=https://github.com/example/repo/pull/4509
  write_pm_task "$state" "$url" s1792792609
  mkdir -p "$dir/home/data/demo/record"
  archive="$dir/home/data/demo/record/closed-task.meta"
  { printf 'archived_at=1792800110\n'; cat "$state/demo.meta"; } > "$archive"
  rm -f "$state/demo.meta" "$state/demo.status"

  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" self 2>"$dir/err"; then
    fail "a merge for a closed task was acknowledged as handed off"
  fi
  [ -f "$state/demo.status" ] || fail "the live PM of a closed task was told nothing; stderr: $(cat "$dir/err")"
  line=$(tail -n 1 "$state/demo.status")
  [ "$(status_line_verb "$line")" = blocked ] || fail "the live PM's notice is not a blocked line: $line"
  assert_contains "$line" "merged demo $url, but task demo was closed before this merge reached it" \
    "the notice did not name the merge and the closed task"
  assert_contains "$line" "bin/fm-control.sh demo relaunch --restore" "the notice did not name the way back"
  assert_contains "$line" "$archive" "the notice did not name the archived record"
  grep -F 'pending with the existing owner' "$state/demo.status" >/dev/null \
    && fail "a handoff was written into a task that no longer exists"
  assert_absent "$state/demo.meta" "the notice recreated a task record"
  [ ! -e "$state/demo.pr-poll-merge-notified" ] || fail "an undelivered handoff committed its notification marker"
  [ ! -s "$state/.wake-queue" ] || fail "the refused handoff created a second owner on main"
  assert_contains "$(cat "$dir/err")" "closed before its merge" "the caller was not told the handoff was refused"

  FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll 2>/dev/null \
    && fail "a replayed merge for a closed task was acknowledged"
  [ "$(wc -l < "$state/demo.status" | tr -d ' ')" = 1 ] || fail "a replayed merge repeated the PM notice"

  rm -f "$state/demo.status"
  if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo \
    https://github.com/example/repo/pull/4510 poll 2>/dev/null; then
    fail "a merge the archive does not name was acknowledged"
  fi
  assert_absent "$state/demo.status" "a merge the archive does not name wrote an event for the closed task"
  pass "a merge that reaches a closed task tells its live PM, never hands off into nothing, and binds only the archived PR"
}

test_merge_without_live_owner_blocks_the_pm() {
  local dir state url verdict line snapshot
  url=https://github.com/example/repo/pull/79
  for verdict in dead missing unreadable ambiguous unverified; do
    dir=$(make_state "owner-$verdict")
    state="$dir/home/state"
    write_pm_task "$state" "$url"
    printf '%s\n' "$verdict" > "$state/demo.agent-state"
    if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll 2>"$dir/err"; then
      fail "a $verdict worker was acknowledged as owning live verification"
    fi
    line=$(tail -n 1 "$state/demo.status")
    [ "$(status_line_verb "$line")" = blocked ] || fail "PM did not receive an actionable block: $line; $(cat "$dir/err")"
    assert_contains "$line" "$url spawn_gen=first" "blocked handoff lost PR or generation"
    assert_contains "$line" "bin/fm-control.sh demo relaunch --note" "blocked handoff omitted recovery command"
    assert_contains "$line" "activation and live verification" "blocked handoff omitted remaining work"
    [ ! -e "$state/demo.pr-poll-merge-notified" ] || fail "unowned handoff committed its marker"
    [ ! -s "$state/.wake-queue" ] || fail "unowned handoff created a second owner on main"
    snapshot=$(cat "$state/demo.status")
    FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll 2>/dev/null \
      && fail "replayed unowned handoff was acknowledged"
    [ "$(cat "$state/demo.status")" = "$snapshot" ] || fail "replay duplicated the blocked handoff"
    write_pm_task "$state" "$url" replacement
    FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll \
      || fail "replacement owner could not receive the handoff"
    assert_pm_handoff "$state" "$url" replacement
    printf '%s\n' "$verdict" > "$state/demo.agent-state"
    if FM_STATE_OVERRIDE="$state" fm_merge_outcome_report "$dir/home" "$state" demo "$url" poll 2>/dev/null; then
      fail "an existing marker hid the replacement owner's lost liveness"
    fi
    line=$(tail -n 1 "$state/demo.status")
    [ "$(status_line_verb "$line")" = blocked ] || fail "existing marker suppressed the owner block"
    assert_contains "$line" "spawn_gen=replacement" "owner block used a stale generation"
  done
  pass "a gone or unproven worker blocks its live PM with a recovery command and remains retryable"
}

test_merge_without_live_owner_blocks_the_pm
test_pm_live_proof_reading
test_merged_outcome_skips_main_queue_for_live_pm
test_merged_outcome_still_queues_for_plain_task
test_failed_handoff_remains_retryable
test_failed_marker_does_not_duplicate_handoff
test_existing_marker_repairs_missing_pm_event
test_stale_pr_and_reused_task_identity
test_restart_and_concurrent_delivery
test_merge_after_close_tells_the_pm_instead_of_handing_off_into_nothing
