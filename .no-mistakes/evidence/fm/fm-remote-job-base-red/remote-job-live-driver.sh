#!/bin/bash
set -eu
project=$1
version=$2
fixture=$project/.test-tmp/live-$version
mkdir -p "$fixture/root/bin" "$fixture/account" "$fixture/home"
cp "$project/bin/fm-remote-job-worker.sh" "$fixture/root/bin/"
cp "$project/AGENTS.md" "$fixture/root/"
if [ "$version" = before ]; then
  git -C "$project" show '87c7524b^:bin/fm-remote-job-lib.sh' > "$fixture/root/bin/fm-remote-job-lib.sh"
else
  cp "$project/bin/fm-remote-job-lib.sh" "$fixture/root/bin/"
fi
cat > "$fixture/root/bin/fm-live-proof.sh" <<'JOB'
#!/bin/bash
sleep "${1:-0}"
printf 'job-complete active=%s home=%s\n' "$FM_REMOTE_JOB_ACTIVE" "$FM_HOME"
JOB
chmod +x "$fixture/root/bin/fm-live-proof.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset FM_REMOTE_JOB_ACTIVE
export HOME=$fixture/account FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_STATE_ROOT=$fixture/state FM_ROOT_OVERRIDE=$fixture/root
export FM_REMOTE_JOB_TIMEOUT=15 FM_REMOTE_JOB_QUEUE_TIMEOUT=30
root=$fixture/root
account=$fixture/account
. "$root/bin/fm-remote-job-lib.sh"
git -C "$root" init -q -b main
git -C "$root" add AGENTS.md bin
all_groups=
other=
cleanup() {
  rc=$?
  trap - EXIT
  if [ -f "$fixture/state/worker.pid" ]; then
    serving=$(cat "$fixture/state/worker.pid")
    if [ "$serving" != "${other:-}" ]; then
      fm_remote_job_stop_worker_tree "$serving" || true
    fi
  fi
  for child in $(jobs -p); do
    command=$(fm_remote_job_process_command "$child" 2>/dev/null || true)
    case "$command" in
      *"$root/bin/fm-remote-job-worker.sh"*) fm_remote_job_stop_worker_tree "$child" || true ;;
    esac
  done
  if [ -n "$other" ]; then kill "$other" 2>/dev/null || true; wait "$other" 2>/dev/null || true; fi
  printf 'cleanup: disposable worker groups stopped; driver exit=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
ensure() {
  fm_remote_job_ensure_worker "$root" "$account" || { printf 'ensure-error: %s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  serving=$(cat "$fixture/state/worker.pid")
  group=$(fm_remote_job_worker_process_group "$serving" 2>/dev/null || true)
  [ -z "$group" ] || all_groups="$all_groups $group"
  printf 'ensure returned: worker.pid=%s lock.pid=%s ready.pid=%s\n' "$serving" "$(cat "$fixture/state/worker.lock/pid")" "$(cat "$fixture/state/worker.ready")"
}
verified() {
  fm_remote_job_worker_owned_alive "$root" "$account" || { printf 'FAIL: ensure returned without verified live ownership\n'; exit 1; }
  fm_remote_job_worker_identity_matches "$root" "$account"
  /bin/ps -p "$serving" -o pid=,pgid=,command=
}
stage() {
  fm_remote_job_stage "$account" "$root" "$fixture/home" fm-live-proof.sh "${1:-0}" < /dev/null > /dev/null
  job=$FM_REMOTE_JOB_ID
}
collect() {
  fm_remote_job_wait "$account" "$job" || { printf 'wait-error: %s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  printf 'job %s: state=%s exit=%s\n' "$job" "$(cat "$fixture/state/jobs/$job/state")" "$FM_REMOTE_JOB_EXIT"
  cat "$FM_REMOTE_JOB_STDOUT"
  [ "$FM_REMOTE_JOB_EXIT" = 0 ]
  fm_remote_job_reap "$account" "$job"
}
printf 'VERSION %s: real portable worker lifecycle, no launchctl or fleet sessions\n' "$version"
printf '\nSCENARIO cold start and immediate job\n'
ensure
verified
stage
collect
printf '\nSCENARIO repeated ensure while a job is active\n'
original=$serving
stage 3
for ((i=0; i<150; i++)); do
  [ "$(fm_remote_job_read_state "$fixture/state/jobs/$job" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$fixture/state/jobs/$job")" = running ]
ensure
[ "$serving" = "$original" ] || { printf 'FAIL: healthy worker replaced\n'; exit 1; }
verified
collect
for heartbeat in stale fresh; do
  printf '\nSCENARIO crashed worker with unrelated persisted PID and %s heartbeat\n' "$heartbeat"
  crashed=$serving
  group=$(fm_remote_job_worker_process_group "$crashed")
  kill -KILL -- "-$group"
  for ((i=0; i<100; i++)); do
    kill -0 "$crashed" 2>/dev/null || break
    sleep 0.05
  done
  sleep 120 &
  other=$!
  printf '%s\n' "$other" > "$fixture/state/worker.pid"
  printf '%s\n' "$other" > "$fixture/state/worker.lock/pid"
  touch -t 200001010000 "$fixture/state/worker.ready" "$fixture/state/worker.lock"
  if [ "$heartbeat" = fresh ]; then touch -c "$fixture/state/worker.ready"; fi
  printf 'before ensure: crashed=%s unrelated=%s ready.pid=%s heartbeat=%s\n' "$crashed" "$other" "$(cat "$fixture/state/worker.ready")" "$heartbeat"
  ensure
  kill -0 "$other"
  printf 'unrelated process remains alive: '
  /bin/ps -p "$other" -o pid=,command=
  [ "$serving" != "$other" ] || { printf 'FAIL: replacement adopted unrelated persisted pid\n'; exit 1; }
  verified
  stage
  collect
  kill "$other"
  wait "$other" 2>/dev/null || true
  other=
done
printf '\nALL LIVE SCENARIOS PASSED\n'
