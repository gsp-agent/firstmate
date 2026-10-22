#!/bin/bash
set -u
. "$PWD/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-job-idle-live)
REMOTE_ROOT="$TMP_ROOT/root"
REMOTE_HOME="$TMP_ROOT/home"
QUIET_WORKER_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'disposable live worker validation\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'JOB'
#!/bin/bash
printf 'ran\n' > "$1"
JOB
chmod +x "$REMOTE_ROOT/bin/fm-touch-job.sh"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" -c user.name=Test -c user.email=test@example.com add AGENTS.md bin
git -C "$REMOTE_ROOT" -c user.name=Test -c user.email=test@example.com commit -qm fixture
. "$ROOT/bin/fm-remote-job-lib.sh"
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
cleanup_idle_live() {
  if [ -n "$QUIET_WORKER_PID" ]; then
    kill -TERM "$QUIET_WORKER_PID" 2>/dev/null || true
    for ((cleanup_attempt=0; cleanup_attempt<100; cleanup_attempt++)); do
      kill -0 "$QUIET_WORKER_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$QUIET_WORKER_PID" 2>/dev/null || true
    wait "$QUIET_WORKER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_idle_live EXIT
# An idle worker must not busy-poll its queue: between passes it sleeps one
# second, so its only steady cost is that sleep and the once-a-second heartbeat
# (including its lock-owner validation and state preparation) plus the periodic
# sweep, which the 2-second stage reap age pulls in to every 2 seconds.
# Every external command the worker runs by name goes through a
# counting shim, which makes the exec rate observable without privileges.
QUIET_HOME="$TMP_ROOT/quiet-account"
QUIET_STATE="$TMP_ROOT/quiet-state"
QUIET_SHIM="$TMP_ROOT/quiet-shim"
QUIET_EXEC_LOG="$TMP_ROOT/quiet-execs"
QUIET_TOUCHED="$TMP_ROOT/quiet-touched"
mkdir -p "$QUIET_HOME" "$QUIET_SHIM"
for QUIET_TOOL in sleep chmod mktemp mv rm date stat uname dirname basename wc tr tail head ps sort cat mkdir rmdir; do
  QUIET_REAL=$(PATH=/usr/bin:/bin command -v "$QUIET_TOOL") || continue
  cat > "$QUIET_SHIM/$QUIET_TOOL" <<SH
#!/bin/sh
printf '%s\n' $QUIET_TOOL >> "\$FM_TEST_EXEC_LOG"
if [ "$QUIET_TOOL" = sleep ] && [ "\${1:-}" = 1 ]; then
  : > "\$FM_TEST_EXEC_LOG.idle"
fi
exec $QUIET_REAL "\$@"
SH
  chmod +x "$QUIET_SHIM/$QUIET_TOOL"
done
HOME="$QUIET_HOME" PATH="$QUIET_SHIM:/usr/bin:/bin:/usr/sbin:/sbin" FM_TEST_EXEC_LOG="$QUIET_EXEC_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$QUIET_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STAGE_REAP_SECONDS=2 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve > "$TMP_ROOT/quiet-worker.out" 2> "$TMP_ROOT/quiet-worker.err" &
QUIET_WORKER_PID=$!
quiet_wait_ready() { # <state> <label>
  for _ in $(seq 1 200); do
    [ -f "$1/worker.ready" ] && break
    sleep 0.05
  done
  assert_present "$1/worker.ready" "the $2 worker did not become ready"
}
# Observe the one-second sleep itself: a slow startup can leave an empty log
# while the worker has not yet finished its fast-poll burst.
quiet_settle() {
  local attempt
  for ((attempt = 0; attempt < 600; attempt++)); do
    [ -f "$QUIET_EXEC_LOG.idle" ] && break
    sleep 0.05
  done
  assert_present "$QUIET_EXEC_LOG.idle" "the worker did not reach its idle wait"
  : > "$QUIET_EXEC_LOG"
}
quiet_measure() { # <label> <max-sleeps>
  local sample line execs=0 sleeps=0
  sleep 4
  # Freeze the sample before counting; the worker keeps appending while the
  # observer runs, especially when external counting commands are delayed.
  sample=$(< "$QUIET_EXEC_LOG")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    execs=$((execs + 1))
    [ "$line" != sleep ] || sleeps=$((sleeps + 1))
  done <<< "$sample"
  printf "idle_sample: label=%s sleeps=%s external_commands=%s\n" "$1" "$sleeps" "$execs"
  [ "$sleeps" -le "$2" ] \
    || fail "$1 kept polling with sleep ($sleeps sleeps in 4s)"
  # Allow the independent heartbeat's bounded ownership checks as well as
  # sweeps at either edge of the window; the sleep limit still rejects fast
  # queue polling independently of this external-command budget.
  [ "$execs" -le 120 ] \
    || fail "$1 ran $execs commands in 4s; expected only heartbeats and sweeps"$'\n'"$(printf '%s\n' "$sample" | sort | uniq -c)"
}
# fm_remote_job_probe must keep reading an idle worker as ready: its heartbeat
# stays far inside the probe's 10-second bound across several idle waits.
quiet_heartbeat_stays_fresh() { # <state> <account-home> <label>
  local deadline=$((SECONDS + 5)) age
  while [ "$SECONDS" -lt "$deadline" ]; do
    ( FM_REMOTE_JOB_STATE_ROOT="$1"; fm_remote_job_probe "$2" ) \
      || fail "the probe read the live $3 worker as unready"
    # Sample the timestamp and clock together so observer scheduling cannot
    # age a saved timestamp after the worker has already refreshed the file.
    age=$(perl -e 'my @s = stat $ARGV[0]; @s or exit 1; print time - $s[9], "\n";' "$1/worker.ready") \
      || fail "the $3 worker heartbeat vanished"
    printf "heartbeat_sample: label=%s age_seconds=%s\n" "$3" "$age"
    [ "$age" -le 3 ] || fail "the $3 worker heartbeat went ${age}s stale"
    sleep 0.5
  done
}
quiet_stage_completes() { # <state> <account-home> <touched> <label>
  local attempt state
  (
    FM_REMOTE_JOB_STATE_ROOT="$1"
    FM_REMOTE_JOB_QUEUE_TIMEOUT=60
    FM_REMOTE_JOB_TIMEOUT=30
    fm_remote_job_stage "$2" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$3" \
      < /dev/null > /dev/null || exit 1
    # Bound pickup after publication, independently of staging, execution and
    # cleanup. Poll attempts allow for the counting shims and host scheduling.
    for ((attempt = 0; attempt < 100; attempt++)); do
      fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID" state || exit 1
      [ "$state" = queued ] || break
      sleep 0.05
    done
    [ "$state" != queued ] || fail "the $4 worker did not claim the staged job"
    fm_remote_job_wait "$2" "$FM_REMOTE_JOB_ID" || exit 1
    printf "staged_job_result: state=%s exit=%s\n" "$(fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID")" "$FM_REMOTE_JOB_EXIT"
    [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || exit 1
    fm_remote_job_reap "$2" "$FM_REMOTE_JOB_ID"
  ) || fail "a job staged to the $4 worker did not complete"
  assert_present "$3" "the job staged to the $4 worker did not run"
  printf "staged_job_side_effect="
  cat "$3"
}
quiet_stop() { # <pid>
  kill -TERM "$1"
  for _ in $(seq 1 100); do
    kill -0 "$1" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$1" 2>/dev/null && fail "TERM did not stop the idle worker"
  wait "$1" 2>/dev/null || true
}
quiet_wait_ready "$QUIET_STATE" idle-rate
quiet_settle
quiet_measure "an idle worker" 6
pass "an idle worker sleeps out a second between passes instead of busy-polling"

quiet_heartbeat_stays_fresh "$QUIET_STATE" "$QUIET_HOME" idle
pass "an idle worker keeps its readiness heartbeat fresh between passes"

# A job published to an idle worker is picked up on a later pass and runs to
# successful result publication, even with the command-counting shims active.
quiet_stage_completes "$QUIET_STATE" "$QUIET_HOME" "$QUIET_TOUCHED" idle
pass "an idle worker claims a staged job and publishes its successful result"

# Hoisting setup out of every pass must not drop the worker's own repair of the
# queue directories' 0700 modes: the periodic sweep still re-applies them with
# no staging to trigger it.
chmod 755 "$QUIET_STATE/jobs" "$QUIET_STATE/.seq-claims" "$QUIET_STATE/logs"
for _ in $(seq 1 100); do
  [ "$(file_mode "$QUIET_STATE/jobs")" = 700 ] && [ "$(file_mode "$QUIET_STATE/.seq-claims")" = 700 ] \
    && [ "$(file_mode "$QUIET_STATE/logs")" = 700 ] && break
  sleep 0.1
done
for QUIET_DIR in jobs .seq-claims logs; do
  [ "$(file_mode "$QUIET_STATE/$QUIET_DIR")" = 700 ] \
    || fail "the idle worker did not restore 0700 on its $QUIET_DIR directory"
done
printf "restored_queue_directory_modes: jobs=%s claims=%s logs=%s\n" "$(file_mode "$QUIET_STATE/jobs")" "$(file_mode "$QUIET_STATE/.seq-claims")" "$(file_mode "$QUIET_STATE/logs")"
quiet_stop "$QUIET_WORKER_PID"
QUIET_WORKER_PID=
pass "an idle worker still repairs queue permissions and stops promptly on TERM"

