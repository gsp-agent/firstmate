#!/usr/bin/env bash
# Real worker replay, isolated below the gate worktree; no harness or fleet use.
set -u
VERSION=$1
REPO=$PWD
. "$REPO/tests/git-config-helpers.sh"
FIXTURE=$(mktemp -d "$REPO/.phase-test-tmp/crash-$VERSION.XXXXXX")
ROOT="$FIXTURE/root"
ACCOUNT="$FIXTURE/account"
JOB_HOME="$FIXTURE/home"
export FM_REMOTE_JOB_STATE_ROOT="$FIXTURE/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
OTHER_PID=
SUPERVISORS=()
cleanup() {
  local pid
  for pid in "${SUPERVISORS[@]}"; do
    fm_remote_job_stop_worker_tree "$pid" 2>/dev/null || true
  done
  [ -z "$OTHER_PID" ] || { kill "$OTHER_PID" 2>/dev/null || true; wait "$OTHER_PID" 2>/dev/null || true; }
  if [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ]; then
    pid=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
    fm_remote_job_stop_worker_tree "$pid" 2>/dev/null || true
  fi
  rm -rf -- "${FIXTURE:?}"
}
mkdir -p "$ROOT/bin" "$ACCOUNT" "$JOB_HOME"
cp "$REPO/bin/fm-remote-job-worker.sh" "$ROOT/bin/"
if [ "$VERSION" = base ]; then
  git show 20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-remote-job-lib.sh > "$ROOT/bin/fm-remote-job-lib.sh"
else
  cp "$REPO/bin/fm-remote-job-lib.sh" "$ROOT/bin/"
fi
printf 'isolated remote-job fixture\n' > "$ROOT/AGENTS.md"
cat > "$ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'executed:%s\n' "$1" > "$FM_HOME/probe-result"
printf 'worker command executed; home=%s; argument=%s\n' "$FM_HOME" "$1"
SH
chmod +x "$ROOT/bin/"*.sh
git -C "$ROOT" init -q -b main
git -C "$ROOT" -c user.name=Test -c user.email=test@example.com add AGENTS.md bin
git -C "$ROOT" -c user.name=Test -c user.email=test@example.com commit -qm 'isolated real worker fixture'
. "$ROOT/bin/fm-remote-job-lib.sh"
trap cleanup EXIT
fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || { printf 'startup failed:%s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
SUPERVISORS+=("$!")
first=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || exit 1
second=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
printf 'version=%s healthy reuse: first=%s second=%s\n' "$VERSION" "$first" "$second"
[ "$first" = "$second" ] || exit 1
run_probe() {
  local label=$1 job result state
  fm_remote_job_stage "$ACCOUNT" "$ROOT" "$JOB_HOME" fm-probe-job.sh "$label" </dev/null >/dev/null || return 1
  job=$FM_REMOTE_JOB_ID
  fm_remote_job_wait "$ACCOUNT" "$job" || return 1
  result=$FM_REMOTE_JOB_EXIT
  state=$(fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$job")
  printf 'probe=%s job=%s exit=%s state=%s\n' "$label" "$job" "$result" "$state"
  cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
  [ ! -f "$JOB_HOME/probe-result" ] || cat "$JOB_HOME/probe-result"
  [ "$result" -eq 0 ] && grep -qx "executed:$label" "$JOB_HOME/probe-result" || return 1
  fm_remote_job_reap "$ACCOUNT" "$job" || return 1
}
if [ "$VERSION" != base ]; then run_probe healthy || exit 1; fi
cases='stale fresh'
[ "$VERSION" != base ] || cases=fresh
for freshness in $cases; do
  crashed=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  supervisor=$(fm_remote_job_worker_process_group "$crashed") || exit 1
  kill -KILL "$supervisor"
  wait "$supervisor" 2>/dev/null || true
  kill -KILL "$crashed"
  wait "$crashed" 2>/dev/null || true
  sleep 300 &
  OTHER_PID=$!
  printf '%s\n' "$OTHER_PID" > "$FM_REMOTE_JOB_STATE_ROOT/worker.pid"
  printf '%s\n' "$OTHER_PID" > "$FM_REMOTE_JOB_STATE_ROOT/worker.lock/pid"
  touch -t 200001010000 "$FM_REMOTE_JOB_STATE_ROOT/worker.ready" "$FM_REMOTE_JOB_STATE_ROOT/worker.lock"
  [ "$freshness" != fresh ] || touch -c "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
  began=$SECONDS
  fm_remote_job_ensure_worker "$ROOT" "$ACCOUNT" || { printf 'recovery failed:%s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  SUPERVISORS+=("$!")
  published=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
  lockpid=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.lock/pid")
  unrelated_alive=no
  kill -0 "$OTHER_PID" 2>/dev/null && unrelated_alive=yes
  printf 'version=%s freshness=%s elapsed=%s crashed=%s unrelated=%s published=%s lockpid=%s unrelated_alive=%s\n' "$VERSION" "$freshness" "$((SECONDS-began))" "$crashed" "$OTHER_PID" "$published" "$lockpid" "$unrelated_alive"
  if [ "$published" = "$OTHER_PID" ]; then
    printf 'REPRODUCED: ensure returned success with unrelated persisted PID\n'
    exit 10
  fi
  [ "$unrelated_alive" = yes ] || exit 1
  [ "$published" = "$lockpid" ] || exit 1
  fm_remote_job_worker_owned_alive "$ROOT" "$ACCOUNT" || exit 1
  fm_remote_job_worker_identity_matches "$ROOT" "$ACCOUNT" || exit 1
  run_probe "$freshness-recovery" || exit 1
  kill "$OTHER_PID" 2>/dev/null || true
  wait "$OTHER_PID" 2>/dev/null || true
  OTHER_PID=
  printf 'PASS: %s recovery rejected unrelated PID and ran queued command\n' "$freshness"
done
