#!/usr/bin/env bash
# tests/fm-watch-state-wait.test.sh - behavior tests for the watcher's kqueue
# state wait (bin/fm-watch-statewait.py, driven by state_wait_or_sleep in
# bin/fm-watch.sh): a state/ write ends the terminal cycle wait sub-second
# while the FM_POLL backstop is far away, unwatched noise does not, and a
# real watcher surfaces an appended status on that wake. Hosts without the
# kqueue wait skip: their watcher keeps the plain fm_sleep backstop, which
# tests/fm-supervision-events.test.sh pins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-watch-state-wait)
WAITER="$ROOT/bin/fm-watch-statewait.py"
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
printf 'working: step 1\n' > "$STATE_DIR/task1.status"

python3 -I "$WAITER" 0 "$STATE_DIR" >/dev/null 2>&1
probe_rc=$?
case "$probe_rc" in
  0|10) ;;
  *) echo "skip: kqueue state wait unavailable on this host (probe rc=$probe_rc)"; exit 0 ;;
esac

WAITER_PID=
WATCHER_PID=
WAITER_RC=

# Consult this shell's own job table, including stopped jobs. A completed
# child may have been reaped and its PID reused; that PID alone is never
# signal authority (tests/watch-fork-budget-helpers.sh owns the pattern).
pid_live() {  # <pid>
  local candidate
  [ -n "$1" ] || return 1
  { jobs -pr; jobs -ps; } > "$TMP/active-jobs"
  while IFS= read -r candidate; do
    [ "$candidate" = "$1" ] && return 0
  done < "$TMP/active-jobs"
  return 1
}

stop_pid() {  # <pid>
  local deadline=$((SECONDS + 10))
  [ -n "$1" ] || return 0
  if pid_live "$1"; then
    kill -TERM "$1" 2>/dev/null || true
    while pid_live "$1" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
    pid_live "$1" && kill -KILL "$1" 2>/dev/null || true
  fi
  wait "$1" 2>/dev/null || true
}

cleanup() {
  stop_pid "$WAITER_PID"
  stop_pid "$WATCHER_PID"
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

start_waiter() {  # <secs> [extra-file...]
  python3 -I "$WAITER" "$1" "$STATE_DIR" "${@:2}" &
  WAITER_PID=$!
}

# 0 (with WAITER_RC set) when the waiter exits within <polls> 0.1s polls.
waiter_exited_within() {  # <polls>
  local i=0
  while [ "$i" -lt "$1" ]; do
    if ! pid_live "$WAITER_PID"; then
      wait "$WAITER_PID"
      WAITER_RC=$?
      WAITER_PID=
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- a quiet state directory waits the whole timeout ------------------------

python3 -I "$WAITER" 1 "$STATE_DIR"
rc=$?
[ "$rc" -eq 0 ] || fail "a quiet wait must end as a clean timeout (rc 0), got $rc"
pass "state wait: a quiet state directory waits the whole timeout"

python3 -I "$WAITER" 1 "$TMP/no-such-state" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "an unusable state directory must read unavailable (rc 2), got $rc"
python3 -I "$WAITER" not-a-number "$STATE_DIR" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "an unusable timeout must read unavailable (rc 2), got $rc"
pass "state wait: unusable arguments read as unavailable, never as a change"

# --- a status append wakes the wait long before its timeout -----------------

start_waiter 30
sleep 0.3
printf 'working: step 2\n' >> "$STATE_DIR/task1.status"
waiter_exited_within 20 || fail "a status append did not wake the wait within 2s of a 30s timeout"
[ "$WAITER_RC" -eq 10 ] || fail "a status append must wake as a change (rc 10), got $WAITER_RC"
pass "state wait: a status append wakes the wait sub-second"

# --- a new status file and a rename replacement wake it too -----------------

start_waiter 30
sleep 0.3
printf 'working: new task\n' > "$STATE_DIR/task2.status"
waiter_exited_within 20 || fail "a new status file did not wake the wait within 2s of a 30s timeout"
[ "$WAITER_RC" -eq 10 ] || fail "a new status file must wake as a change (rc 10), got $WAITER_RC"
start_waiter 30
sleep 0.3
printf 'working: replaced\n' > "$TMP/replacement"
mv "$TMP/replacement" "$STATE_DIR/task1.status"
waiter_exited_within 20 || fail "a rename replacement did not wake the wait within 2s of a 30s timeout"
[ "$WAITER_RC" -eq 10 ] || fail "a rename replacement must wake as a change (rc 10), got $WAITER_RC"
pass "state wait: a created or replaced status file wakes the wait"

# --- unwatched state noise does not wake it ----------------------------------

start_waiter 1
sleep 0.3
: > "$STATE_DIR/.noise-tmp"
rm -f "$STATE_DIR/.noise-tmp"
touch "$STATE_DIR/.last-watcher-beat"
wait "$WAITER_PID"
rc=$?
WAITER_PID=
[ "$rc" -eq 0 ] || fail "unwatched state noise must not wake the wait (expected clean timeout rc 0), got $rc"
pass "state wait: unwatched state noise waits the whole timeout"

# --- the backlog and hold-domain writes wake it -------------------------------

printf '# Backlog\n' > "$TMP/backlog.md"
start_waiter 30 "$TMP/backlog.md"
sleep 0.3
printf -- '- a queued row\n' >> "$TMP/backlog.md"
waiter_exited_within 20 || fail "a backlog write did not wake the wait within 2s of a 30s timeout"
[ "$WAITER_RC" -eq 10 ] || fail "a backlog write must wake as a change (rc 10), got $WAITER_RC"
mkdir -p "$STATE_DIR/hold-domain/pending"
start_waiter 30
sleep 0.3
printf 'hold body\n' > "$STATE_DIR/hold-domain/pending/h1.body"
waiter_exited_within 20 || fail "a hold-domain write did not wake the wait within 2s of a 30s timeout"
[ "$WAITER_RC" -eq 10 ] || fail "a hold-domain write must wake as a change (rc 10), got $WAITER_RC"
pass "state wait: backlog and hold-domain writes wake the wait"

# --- a real watcher surfaces an append out of its 60s backstop wait ----------

HOME1="$TMP/home1"
mkdir -p "$HOME1/state" "$HOME1/config" "$HOME1/data"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME1/data/backlog.md"
printf 'working: step 1\n' > "$HOME1/state/task1.status"
cat > "$TMP/settle.sh" <<'SH'
. "$1/bin/fm-wake-lib.sh" || exit 1
for f in "$2"/state/*.status; do
  [ -e "$f" ] || continue
  fm_wake_status_mark_current "$2/state" "$f" || exit 1
done
SH
FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" bash "$TMP/settle.sh" "$ROOT" "$HOME1" \
  || fail "state wait: could not settle the fixture status log"
touch "$HOME1/state/.last-heartbeat" "$HOME1/state/.last-check"
fm_test_track_watcher_state "$HOME1/state"

( unset TMUX FM_TASK_ID FM_TEST_NO_STATE_WAIT
  export FM_HOME="$HOME1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_POLL=60 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HEARTBEAT_MAX=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_INACTIVE_RECONCILE_SECS=1800
  exec bash "$ROOT/bin/fm-watch.sh" ) > "$TMP/watch.out" 2>&1 &
WATCHER_PID=$!

# The append must land while the watcher sits in its terminal state wait:
# its fm-watch-statewait.py child is that evidence. Appending during the
# scan itself would pass without proving the wait ever woke.
i=0
until pgrep -P "$WATCHER_PID" -f fm-watch-statewait.py >/dev/null 2>&1; do
  pid_live "$WATCHER_PID" \
    || fail "the watcher exited before its state wait: $(head -c 400 "$TMP/watch.out")"
  i=$((i + 1))
  [ "$i" -lt 300 ] || fail "the watcher never entered its state wait: $(head -c 400 "$TMP/watch.out")"
  sleep 0.1
done
printf 'done: wrapped up\n' >> "$HOME1/state/task1.status"
i=0
while pid_live "$WATCHER_PID" && [ "$i" -lt 200 ]; do
  sleep 0.1
  i=$((i + 1))
done
pid_live "$WATCHER_PID" \
  && fail "the watcher was still waiting 20s after the append under a 60s backstop: $(head -c 400 "$TMP/watch.out")"
wait "$WATCHER_PID"
rc=$?
WATCHER_PID=
[ "$rc" -eq 0 ] || fail "the watcher must close cleanly on the woken cycle, got rc $rc: $(head -c 400 "$TMP/watch.out")"
grep -q '^signal:' "$TMP/watch.out" \
  || fail "the woken cycle must surface the appended status as a signal: $(head -c 400 "$TMP/watch.out")"
pass "state wait: a status append wakes a real watcher out of its 60s backstop wait and surfaces as a signal"

# Regression (chip review of 93d5a173): exit 1 is a Python interpreter that
# never ran the waiter (import failure, broken shim). It must read as a
# failure that falls back to fm_sleep, never as a completed wait: with a
# python3 that always exits 1, the capability probe itself must refuse, so
# state_wait_or_sleep pays the plain sleep every call.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/python3" <<'SH'
#!/bin/sh
echo "ModuleNotFoundError: No module named 'resource'" >&2
exit 1
SH
chmod +x "$FAKEBIN/python3"
SLEEPS="$TMP/fake-sleeps"
: > "$SLEEPS"
( PATH="$FAKEBIN:$PATH" STATE="$STATE_DIR" FM_HOME="$TMP" SCRIPT_DIR="$ROOT/bin" \
    SLEEPS="$SLEEPS" bash -c '
    . "$1" || exit 1
    fm_sleep() { echo "$1" >> "$SLEEPS"; }
    _state_wait_cap="" _state_wait_fails=0
    state_wait_or_sleep 7
    state_wait_or_sleep 7
    echo "cap=$_state_wait_cap" >> "$SLEEPS"
  ' _ "$ROOT/bin/fm-watch.sh" ) >"$TMP/fake.out" 2>&1 \
  || fail "state wait: broken-python drive died: $(head -c 400 "$TMP/fake.out")"
[ "$(grep -c '^7$' "$SLEEPS")" -eq 2 ] \
  || fail "state wait: a python3 exiting 1 must fall back to fm_sleep every call (sleeps: $(tr '\n' ' ' < "$SLEEPS"))"
grep -q '^cap=0$' "$SLEEPS" || fail "state wait: probe rc 1 must leave the wait incapable (cap=0)"
pass "state wait: a python3 exiting 1 reads as never-ran and falls back to fm_sleep"

echo "# fm-watch-state-wait.test.sh: all assertions passed"
