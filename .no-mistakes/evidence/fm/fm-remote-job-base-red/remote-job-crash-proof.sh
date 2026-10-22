#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
FIXTURE="$ROOT/.gate-test-tmp/crash-proof"
REMOTE_ROOT="$FIXTURE/code"
ACCOUNT_HOME="$FIXTURE/account"
REMOTE_HOME="$FIXTURE/home"
export FM_REMOTE_JOB_STATE_ROOT="$FIXTURE/queue"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
OTHER_PID=
cleanup() {
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" || true
  fi
  if [ -n "$OTHER_PID" ]; then kill "$OTHER_PID" 2>/dev/null || true; wait "$OTHER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$REMOTE_HOME"
cp bin/fm-remote-job-lib.sh bin/fm-remote-job-worker.sh "$REMOTE_ROOT/bin/"
printf 'Disposable remote-job proof fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-proof-job.sh" <<'SH'
#!/bin/bash
printf 'replacement executed: %s\n' "$1"
printf '%s\n' "$1" > "$FM_HOME/result"
SH
chmod +x "$REMOTE_ROOT/bin/fm-proof-job.sh"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" -c user.name=Test -c user.email=test@example.com commit -qm fixture
git show 87c7524b^:bin/fm-remote-job-lib.sh > "$FIXTURE/pre-fix-lib.sh"
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME"
printf 'initial ready owner=%s\n' "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")"
for MODE in stale-heartbeat refreshed-heartbeat; do
  printf '\nscenario=%s\n' "$MODE"
  CRASHED=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  SUPERVISOR=$(fm_remote_job_worker_process_group "$CRASHED")
  kill -KILL "$SUPERVISOR"
  wait "$SUPERVISOR" 2>/dev/null || true
  kill -KILL "$CRASHED"
  wait "$CRASHED" 2>/dev/null || true
  sleep 120 &
  OTHER_PID=$!
  printf '%s\n' "$OTHER_PID" > "$FM_REMOTE_JOB_STATE_ROOT/worker.pid"
  printf '%s\n' "$OTHER_PID" > "$FM_REMOTE_JOB_STATE_ROOT/worker.lock/pid"
  touch -t 200001010000 "$FM_REMOTE_JOB_STATE_ROOT/worker.ready" "$FM_REMOTE_JOB_STATE_ROOT/worker.lock"
  if [ "$MODE" = refreshed-heartbeat ]; then
    touch -c "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
    (
      . "$FIXTURE/pre-fix-lib.sh"
      fm_remote_job_wait_for_probe "$REMOTE_ROOT" "$ACCOUNT_HOME"
      printf 'pre-fix readiness accepted unrelated pid=%s while no replacement was serving\n' "$OTHER_PID"
    )
  fi
  if fm_remote_job_worker_owned_alive "$REMOTE_ROOT" "$ACCOUNT_HOME"; then
    printf 'ERROR: current ownership predicate accepted unrelated process\n'
    exit 1
  fi
  printf 'current ownership check rejects crashed records with unrelated pid=%s\n' "$OTHER_PID"
  fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME"
  NEW_PID=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  [ "$NEW_PID" != "$OTHER_PID" ]
  kill -0 "$OTHER_PID"
  fm_remote_job_worker_owned_alive "$REMOTE_ROOT" "$ACCOUNT_HOME"
  fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME"
  printf 'ensure returned with verified current-code owner=%s; unrelated pid=%s remains alive\n' "$NEW_PID" "$OTHER_PID"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-proof-job.sh "$MODE" </dev/null >/dev/null
  JOB_ID=$FM_REMOTE_JOB_ID
  fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID"
  printf 'job=%s state=%s exit=%s\n' "$JOB_ID" "$(fm_remote_job_read_state "$FM_REMOTE_JOB_STATE_ROOT/jobs/$JOB_ID")" "$FM_REMOTE_JOB_EXIT"
  cat "$FM_REMOTE_JOB_STDOUT"
  [ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
  [ "$(cat "$REMOTE_HOME/result")" = "$MODE" ]
  fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID"
  [ ! -e "$FM_REMOTE_JOB_STATE_ROOT/jobs/$JOB_ID" ]
  printf 'completed job reaped; persisted result=%s\n' "$(cat "$REMOTE_HOME/result")"
  kill "$OTHER_PID"
  wait "$OTHER_PID" 2>/dev/null || true
  OTHER_PID=
done
