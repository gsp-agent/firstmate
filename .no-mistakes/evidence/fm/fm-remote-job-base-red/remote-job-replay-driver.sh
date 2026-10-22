#!/bin/bash
set -u
ROOT=$1
ACCOUNT=$2
HOME_DIR=$3
export FM_REMOTE_JOB_STATE_ROOT=$4
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
. "$ROOT/bin/fm-remote-job-lib.sh"
OTHER=
cleanup() {
  [ -z "$OTHER" ] || kill "$OTHER" 2>/dev/null || true
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    local pid
    pid=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
    if [ "$pid" != "$OTHER" ]; then fm_remote_job_stop_worker_tree "$pid" || true; fi
  fi
  [ -z "$OTHER" ] || wait "$OTHER" 2>/dev/null || true
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
probe_job() {
  fm_remote_job_stage "$ACCOUNT" "$ROOT" "$HOME_DIR" fm-probe-job.sh < /dev/null > /dev/null || fail "$FM_REMOTE_JOB_ERROR"
  fm_remote_job_wait "$ACCOUNT" "$FM_REMOTE_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
  printf 'job=%s state=%s exit=%s stdout=' "$FM_REMOTE_JOB_ID" "$(fm_remote_job_read_state "$FM_REMOTE_JOB_STATE_ROOT/jobs/$FM_REMOTE_JOB_ID")" "$FM_REMOTE_JOB_EXIT"
  cat "$FM_REMOTE_JOB_STDOUT"
  cat "$FM_REMOTE_JOB_STDERR"
  [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail 'replacement job did not succeed'
  fm_remote_job_reap "$ACCOUNT" "$FM_REMOTE_JOB_ID" || fail 'cannot reap probe'
}
fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || fail "$FM_REMOTE_JOB_ERROR"
pid=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
printf 'INITIAL worker=%s\n' "$pid"
probe_job
fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || fail "$FM_REMOTE_JOB_ERROR"
[ "$pid" = "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" ] || fail 'healthy worker was replaced'
printf 'HEALTHY worker retained=%s\n' "$pid"
for freshness in stale fresh; do
  crashed=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  supervisor=$(fm_remote_job_worker_process_group "$crashed") || fail 'no isolated worker supervisor'
  kill -KILL "$supervisor"
  kill -KILL "$crashed"
  sleep 300 &
  OTHER=$!
  printf '%s\n' "$OTHER" > "$FM_REMOTE_JOB_STATE_ROOT/worker.pid"
  printf '%s\n' "$OTHER" > "$FM_REMOTE_JOB_STATE_ROOT/worker.lock/pid"
  touch -t 200001010000 "$FM_REMOTE_JOB_STATE_ROOT/worker.lock" "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
  if [ "$freshness" = fresh ]; then touch -c "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"; fi
  printf 'CRASH freshness=%s crashed=%s supervisor=%s unrelated=%s\n' "$freshness" "$crashed" "$supervisor" "$OTHER"
  began=$SECONDS
  fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || fail "$FM_REMOTE_JOB_ERROR"
  replacement=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  printf 'ENSURE elapsed=%ss published_pid=%s unrelated=%s\n' "$((SECONDS-began))" "$replacement" "$OTHER"
  kill -0 "$OTHER" || fail 'unrelated process was signaled'
  [ "$replacement" != "$OTHER" ] || fail 'replacement adopted unrelated persisted pid'
  fm_remote_job_worker_owned_alive "$ROOT" "$ACCOUNT" || fail 'replacement lacks verified process ownership'
  fm_remote_job_worker_identity_matches "$ROOT" "$ACCOUNT" || fail 'replacement has wrong code identity'
  probe_job
  printf 'RECOVERED freshness=%s unrelated_alive=yes replacement_owned=yes\n' "$freshness"
  kill "$OTHER"
  wait "$OTHER" 2>/dev/null || true
  OTHER=
done
