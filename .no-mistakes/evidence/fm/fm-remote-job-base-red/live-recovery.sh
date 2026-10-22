#!/usr/bin/env bash
set -eu
ROOT=$PWD
. "$ROOT/tests/lib.sh"
LIVE_ROOT=$(fm_test_tmproot fm-recovery-live)
REMOTE_ROOT="$LIVE_ROOT/code"
ACCOUNT_HOME="$LIVE_ROOT/account"
REMOTE_HOME="$LIVE_ROOT/home"
STATE_ROOT="$LIVE_ROOT/jobs"
OTHER_PID=
cleanup_live() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  [ -z "$OTHER_PID" ] || { kill "$OTHER_PID" 2>/dev/null || true; wait "$OTHER_PID" 2>/dev/null || true; }
  rm -rf -- "${LIVE_ROOT:?}"
}
trap cleanup_live EXIT
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$REMOTE_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
if [ -n "${BASELINE_ID:-}" ]; then
  git show "$BASELINE_ID:bin/fm-remote-job-lib.sh" > "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
  printf 'baseline library commit=%s; worker unchanged\n' "$BASELINE_ID"
fi
printf 'Disposable remote worker lab\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-live-proof.sh" <<'PAYLOAD'
#!/usr/bin/env bash
printf 'replacement executed command; active=%s\n' "${FM_REMOTE_JOB_ACTIVE:-missing}"
printf 'delivered\n' > "$1"
PAYLOAD
chmod +x "$REMOTE_ROOT/bin/fm-live-proof.sh"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" -c user.name=Test -c user.email=test@example.com commit -qm 'disposable live worker lab'
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
INITIAL=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
REUSED=$(cat "$STATE_ROOT/worker.pid")
printf 'healthy worker: initial=%s repeated_ensure=%s\n' "$INITIAL" "$REUSED"
[ "$INITIAL" = "$REUSED" ] || fail 'healthy worker was replaced'
for MODE in stale-readiness late-heartbeat; do
  OLD=$(cat "$STATE_ROOT/worker.pid")
  SUPERVISOR=$(fm_remote_job_worker_process_group "$OLD")
  kill -KILL "$SUPERVISOR"
  wait "$SUPERVISOR" 2>/dev/null || true
  kill -KILL "$OLD"
  wait "$OLD" 2>/dev/null || true
  sleep 300 &
  OTHER_PID=$!
  printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
  printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
  touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
  [ "$MODE" != late-heartbeat ] || touch -c "$STATE_ROOT/worker.ready"
  printf '\nscenario=%s crashed=%s unrelated=%s\n' "$MODE" "$OLD" "$OTHER_PID"
  fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
  NEW=$(cat "$STATE_ROOT/worker.pid")
  LOCK_OWNER=$(cat "$STATE_ROOT/worker.lock/pid")
  kill -0 "$OTHER_PID" || fail 'unrelated process was signaled'
  [ "$NEW" != "$OTHER_PID" ] || fail 'adopted unrelated PID'
  fm_remote_job_worker_owned_alive "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail 'replacement lacks a live verified owner'
  fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail 'replacement code identity mismatch'
  printf 'ensure returned: worker=%s lock_owner=%s unrelated_alive=yes identity=current\n' "$NEW" "$LOCK_OWNER"
  MARKER="$LIVE_ROOT/$MODE-delivered"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-live-proof.sh "$MARKER" </dev/null >/dev/null || fail "$FM_REMOTE_JOB_ERROR"
  JOB_ID=$FM_REMOTE_JOB_ID
  fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
  printf 'queued command: exit=%s state=%s queue_timeout=5 execution_timeout=5\n' "$FM_REMOTE_JOB_EXIT" "$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB_ID")"
  cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
  [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail 'replacement command failed'
  cat "$MARKER"
  fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail 'job reap failed'
  kill "$OTHER_PID"
  wait "$OTHER_PID" 2>/dev/null || true
  OTHER_PID=
done
