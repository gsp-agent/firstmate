#!/bin/bash
set -u
variant=$1
repo=$PWD
fixture=$(mktemp -d "$repo/.remote-job-live-tmp/pid-$variant.XXXXXX") || exit 1
remote="$fixture/root"
account="$fixture/account"
home="$fixture/home"
state="$fixture/queue"
unrelated=
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
mkdir -p "$remote/bin" "$account" "$home"
cp "$repo/bin/fm-remote-job-worker.sh" "$repo/bin/fm-remote-job-lib.sh" "$remote/bin/"
if [ "$variant" = before ]; then
  git show '87c7524b^:bin/fm-remote-job-lib.sh' > "$remote/bin/fm-remote-job-lib.sh" || exit 1
fi
printf 'disposable remote-job validation\n' > "$remote/AGENTS.md"
cat > "$remote/bin/fm-recovered-job.sh" <<'JOB'
#!/bin/bash
printf 'replacement executed this queued command\n'
printf 'executed\n' > "$1"
JOB
chmod +x "$remote/bin/fm-recovered-job.sh"
git -C "$remote" init -q -b main
git -C "$remote" -c user.name=Test -c user.email=test@example.com add AGENTS.md bin
git -C "$remote" -c user.name=Test -c user.email=test@example.com commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=30
. "$remote/bin/fm-remote-job-lib.sh"
cleanup() {
  local attempt current
  # Allow the asynchronously launched replacement to publish its actual owner
  # before stopping its whole isolated worker tree.
  for ((attempt=0; attempt<200; attempt++)); do
    current=$(cat "$state/worker.pid" 2>/dev/null || true)
    if [ -n "$current" ] && [ "$current" != "$unrelated" ] && fm_remote_job_worker_owned_alive "$remote" "$account"; then
      fm_remote_job_stop_worker_tree "$current" || true
      break
    fi
    sleep 0.05
  done
  if [ -n "$unrelated" ]; then
    kill "$unrelated" 2>/dev/null || true
    wait "$unrelated" 2>/dev/null || true
  fi
  rm -rf -- "${fixture:?}"
}
trap cleanup EXIT
fm_remote_job_ensure_worker "$remote" "$account" || { printf 'initial startup failed: %s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
crashed=$(cat "$state/worker.pid")
supervisor=$(fm_remote_job_worker_process_group "$crashed") || exit 1
printf 'variant=%s\ninitial_serving_pid=%s\ninitial_supervisor_pid=%s\n' "$variant" "$crashed" "$supervisor"
kill -KILL "$supervisor"
wait "$supervisor" 2>/dev/null || true
kill -KILL "$crashed"
wait "$crashed" 2>/dev/null || true
sleep 120 &
unrelated=$!
printf '%s\n' "$unrelated" > "$state/worker.pid"
printf '%s\n' "$unrelated" > "$state/worker.lock/pid"
touch -t 200001010000 "$state/worker.lock"
# Reproduce the independent heartbeat's last refresh after its owner dies.
touch -c "$state/worker.ready"
printf 'persisted_unrelated_pid=%s\nlate_heartbeat_ready_record=' "$unrelated"
cat "$state/worker.ready"
fm_remote_job_ensure_worker "$remote" "$account" || { printf 'replacement startup failed: %s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
IFS= read -r returned < "$state/worker.pid"
printf 'ensure_returned_pid=%s\n' "$returned"
kill -0 "$unrelated" || { printf 'unrelated process was signaled\n'; exit 1; }
printf 'unrelated_process_survived=yes\n'
if [ "$returned" = "$unrelated" ]; then
  printf 'observed_regression=ensure reported ready with unrelated persisted pid\n'
  [ "$variant" = before ] || exit 1
  exit 0
fi
fm_remote_job_worker_owned_alive "$remote" "$account" || { printf 'published owner did not verify\n'; exit 1; }
printf 'published_owner_verified=yes\n'
fm_remote_job_stage "$account" "$remote" "$home" fm-recovered-job.sh "$fixture/side-effect" < /dev/null > /dev/null || exit 1
job=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$account" "$job" || exit 1
printf 'job_id=%s\njob_state=' "$job"
cat "$state/jobs/$job/state"
printf 'job_exit=%s\njob_stdout=' "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
printf 'job_side_effect='
cat "$fixture/side-effect"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || exit 1
fm_remote_job_reap "$account" "$job" || exit 1
if [ "$variant" = before ]; then
  printf 'regression_not_observed_this_attempt=yes\n'
else
  printf 'recovered_worker_serves_commands=yes\n'
fi
