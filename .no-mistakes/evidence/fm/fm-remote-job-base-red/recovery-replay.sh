#!/usr/bin/env bash
set -u
ROOT=$PWD
FIXTURE=$1
REMOTE_ROOT=$FIXTURE/code
ACCOUNT_HOME=$FIXTURE/account
REMOTE_HOME=$FIXTURE/home
STATE_ROOT=$FIXTURE/state
OTHER_PID=
export HOME="$ACCOUNT_HOME" FM_HOME="$REMOTE_HOME"
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_REMOTE_JOB_ACTIVE
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME"; then
    fm_remote_job_stop_worker_tree "$FM_REMOTE_JOB_OWNER_PID" || true
  fi
  local supervisor
  for supervisor in $(jobs -pr); do
    [ "$supervisor" = "$OTHER_PID" ] && continue
    kill -TERM "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
  done
  if [ -n "$OTHER_PID" ]; then
    kill "$OTHER_PID" 2>/dev/null || true
    wait "$OTHER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
snapshot() {
  local pid lock_pid ready
  pid=$(cat "$STATE_ROOT/worker.pid")
  lock_pid=$(cat "$STATE_ROOT/worker.lock/pid")
  ready=$(fm_remote_job_path_mtime "$STATE_ROOT/worker.ready")
  printf 'worker.pid=%s lock.pid=%s readiness_age=%ss\n' "$pid" "$lock_pid" "$(( $(date +%s) - ready ))"
  ps -p "$pid" -o pid= -o ppid= -o command=
  if fm_remote_job_worker_owned_alive "$REMOTE_ROOT" "$ACCOUNT_HOME"; then
    printf 'verified_live_owner=yes\n'
  else
    printf 'verified_live_owner=no\n'
  fi
}
probe() {
  local label=$1
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh "$label" "$FIXTURE/$label.executed" </dev/null >/dev/null || fail "$FM_REMOTE_JOB_ERROR"
  local id=$FM_REMOTE_JOB_ID
  fm_remote_job_wait "$ACCOUNT_HOME" "$id" || fail "$FM_REMOTE_JOB_ERROR"
  printf 'job=%s state=%s exit=%s\n' "$id" "$(fm_remote_job_read_state "$STATE_ROOT/jobs/$id")" "$FM_REMOTE_JOB_EXIT"
  cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
  [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "$label command failed"
  [ -f "$FIXTURE/$label.executed" ] || fail "$label command had no side effect"
  fm_remote_job_reap "$ACCOUNT_HOME" "$id" || fail 'reap failed'
}
printf '=== %s initial launch ===\n' "$2"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
snapshot
probe initial
before=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$before" ] || fail 'healthy worker was replaced'
printf 'healthy worker reused: %s\n' "$before"
for condition in stale fresh; do
  printf '\n=== crash with %s readiness ===\n' "$condition"
  crashed=$(cat "$STATE_ROOT/worker.pid")
  supervisor=$(fm_remote_job_worker_process_group "$crashed") || fail 'cannot identify supervisor'
  printf 'crashed_worker=%s supervisor=%s\n' "$crashed" "$supervisor"
  kill -KILL "$supervisor"
  wait "$supervisor" 2>/dev/null || true
  kill -KILL "$crashed"
  wait "$crashed" 2>/dev/null || true
  sleep 300 &
  OTHER_PID=$!
  printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
  printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
  touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
  [ "$condition" != fresh ] || touch -c "$STATE_ROOT/worker.ready"
  printf 'unrelated_pid=%s\n' "$OTHER_PID"
  snapshot
  began=$SECONDS
  fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
  printf 'ensure returned in %ss\n' "$((SECONDS - began))"
  snapshot
  kill -0 "$OTHER_PID" 2>/dev/null || fail 'unrelated process was signaled'
  printf 'unrelated process still alive=yes\n'
  new=$(cat "$STATE_ROOT/worker.pid")
  [ "$new" != "$OTHER_PID" ] || fail 'ensure adopted unrelated persisted PID'
  fm_remote_job_worker_owned_alive "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail 'returned without live ownership'
  fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail 'wrong code identity'
  probe "$condition-recovery"
  kill "$OTHER_PID"
  wait "$OTHER_PID" 2>/dev/null || true
  OTHER_PID=
done
printf '\nAll recovery replay assertions passed.\n'
