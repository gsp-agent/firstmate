#!/usr/bin/env bash
set -eu
ROOT=$PWD
FIXTURE="$ROOT/.test-remote-counterfactual"
mkdir -m 700 "$FIXTURE"
ACCOUNT="$FIXTURE/account"
CODE="$FIXTURE/code"
REMOTE_HOME="$FIXTURE/home"
mkdir -p "$ACCOUNT" "$CODE/bin" "$REMOTE_HOME"
export FM_REMOTE_JOB_STATE_ROOT="$FIXTURE/queue"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$CODE/bin/"
printf 'fixture\n' > "$CODE/AGENTS.md"
cat > "$CODE/bin/fm-proof-job.sh" <<'SH'
#!/bin/bash
printf 'replacement executed a queued command\n'
SH
chmod +x "$CODE/bin/fm-proof-job.sh"
git -C "$CODE" init -q -b main
git -C "$CODE" add AGENTS.md bin
OTHER=
cleanup() {
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" || true
  fi
  if [ -n "$OTHER" ]; then kill "$OTHER" 2>/dev/null || true; wait "$OTHER" 2>/dev/null || true; fi
}
trap cleanup EXIT
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_ensure_worker "$CODE" "$ACCOUNT"
OLD=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
SUPERVISOR=$(fm_remote_job_worker_process_group "$OLD")
printf 'Verified initial serving worker=%s supervisor=%s\n' "$OLD" "$SUPERVISOR"
kill -KILL "$SUPERVISOR"
kill -KILL "$OLD"
sleep 90 &
OTHER=$!
printf '%s\n' "$OTHER" > "$FM_REMOTE_JOB_STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER" > "$FM_REMOTE_JOB_STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$FM_REMOTE_JOB_STATE_ROOT/worker.lock"
touch -c "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
printf 'Crashed worker; ownership records now name unrelated live sleep pid=%s; heartbeat refreshed\n' "$OTHER"
git show 20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-remote-job-lib.sh > "$FIXTURE/base-library.sh"
. "$FIXTURE/base-library.sh"
if fm_remote_job_wait_for_probe "$CODE" "$ACCOUNT"; then
  printf 'BASELINE: readiness incorrectly accepted unrelated owner\n'
else
  printf 'BASELINE did not reproduce\n'; exit 1
fi
. "$ROOT/bin/fm-remote-job-lib.sh"
if fm_remote_job_wait_for_probe "$CODE" "$ACCOUNT"; then
  printf 'TARGET incorrectly accepted unrelated owner\n'; exit 1
else
  printf 'TARGET: readiness rejected unrelated owner despite matching identity and prior fresh heartbeat\n'
fi
fm_remote_job_ensure_worker "$CODE" "$ACCOUNT"
NEW=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
[ "$NEW" != "$OTHER" ]
kill -0 "$OTHER"
printf 'TARGET: replacement worker=%s; unrelated pid=%s still alive\n' "$NEW" "$OTHER"
fm_remote_job_stage "$ACCOUNT" "$CODE" "$REMOTE_HOME" fm-proof-job.sh < /dev/null > /dev/null
fm_remote_job_wait "$ACCOUNT" "$FM_REMOTE_JOB_ID"
cat "$FM_REMOTE_JOB_STDOUT"
printf 'Queued command exit=%s\n' "$FM_REMOTE_JOB_EXIT"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
fm_remote_job_reap "$ACCOUNT" "$FM_REMOTE_JOB_ID"
printf 'Completed job reaped\n'
