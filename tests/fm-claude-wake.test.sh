#!/usr/bin/env bash
# Behavior tests for ship 2 of the wake-record plan: the Claude turn record
# (bin/fm-claude-turn.sh), the Claude waker (bin/fm-claude-wake.sh), the
# session-start present-without-claim drain, and the Stop hook's
# rewake-pending admission guard.
#
# Every case runs in an isolated temporary home as a child of a fake harness
# (a bash symlink named "claude") whose pid owns the fixture home's session
# lock, so no live home, watcher, or Claude session is touched. A replay runs
# its whole sequence inside one fake harness, so the Claude pid stays fixed
# across its turns and resets. Times on the replay timelines (+77 s, +150 s,
# +330 s, +350 s) are modeled by injecting beacon mtimes and ledger epochs
# rather than sleeping; the session-start digest is modeled by its two
# effects on the waker (the presented set emptied, then the completion record
# rewritten), which tests/fm-session-start.test.sh proves the digest has.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
unset FM_ROOT_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-claude-wake)
fm_test_trap_process_cleanup "$TMP_ROOT"
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE FM_TEST_PIDS="$TMP_ROOT/pids"
: > "$FM_TEST_PIDS"

# Helpers the fake harness children call. Each is a plain script, so the hook
# under test still finds the fake harness above it.
HELPERS="$TMP_ROOT/helpers"
mkdir -p "$HELPERS"
export DRAIN="$ROOT/bin/fm-wake-drain.sh" HELPERS
# payload <session-id> <event> [source|rewake]: a Claude-shaped hook payload.
cat > "$HELPERS/payload" <<'SH'
#!/usr/bin/env bash
sid=$1 event=$2 extra=${3:-}
case "$event:$extra" in
  SessionStart:*) printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$sid" "$extra" ;;
  UserPromptSubmit:rewake)
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"\\n\\n<task-notification>\\n<summary>Stop hook feedback</summary>\\n</task-notification>"}' "$sid" ;;
  UserPromptSubmit:*) printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"status?"}' "$sid" ;;
  Stop:*) printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$sid" ;;
  StopFailure:*) printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"invalid_request"}' "$sid" ;;
  FileChanged:*) printf '{"session_id":"%s","hook_event_name":"FileChanged","file_path":"%s/state/.wake-queue","event":"change"}' "$sid" "$FM_HOME" ;;
  *) exit 2 ;;
esac
SH
# append <state> <name>: append one check row through the production library.
cat > "$HELPERS/append" <<'SH'
#!/usr/bin/env bash
FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
  "$FM_HOME/bin/fm-wake-lib.sh" "wake-$2" "check: $2"
SH
# now: wall-clock seconds with millisecond precision.
cat > "$HELPERS/now" <<'SH'
#!/usr/bin/env bash
python3 -c 'import time; print("%.3f" % time.time())'
SH
# set-mtime <file> <epoch>: inject a file's modification time.
cat > "$HELPERS/set-mtime" <<'SH'
#!/usr/bin/env bash
python3 -c 'import os, sys; open(sys.argv[1], "a").close(); os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$1" "$2"
SH
# ledger-at <state> <epoch>: inject the current ledger entry's commit epoch.
cat > "$HELPERS/ledger-at" <<'SH'
#!/usr/bin/env bash
f="$1/.claude-autoarm-epoch"
awk -v at="$2" 'NR == 1 { sub(/updated_at=[0-9]+/, "updated_at=" at) } { print }' "$f" > "$f.inject" \
  && mv -f "$f.inject" "$f"
SH
# old-claim <state>: a Stop-hook claim whose owner has already exited.
cat > "$HELPERS/old-claim" <<'SH'
#!/usr/bin/env bash
bash -c '. "$1"; fm_autoarm_claim_next "$2" 300' _ "$FM_HOME/bin/fm-wake-lib.sh" "$1"
SH
# wait-sleeping <pid>: return once <pid> sleeps in its session-open wait loop;
# fail when it exits first or never waits.
cat > "$HELPERS/wait-sleeping" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ]; do
  kill -0 "$1" 2>/dev/null || exit 1
  pgrep -P "$1" sleep >/dev/null 2>&1 && exit 0
  sleep 0.05
  i=$((i + 1))
done
exit 1
SH
# wait-gated <gate-dir> <pid>: return once <pid>'s gated sleep holds; fail
# when it exits first or never waits.
cat > "$HELPERS/wait-gated" <<'SH'
#!/usr/bin/env bash
i=0
while [ ! -e "$1/sleeping" ]; do
  kill -0 "$2" 2>/dev/null || exit 1
  [ "$i" -lt 2400 ] || exit 1
  sleep 0.05
  i=$((i + 1))
done
SH
# digest <state> [lock-pid]: the session-start digest's effects the waker
# depends on. A fresh startup first takes the lock for [lock-pid]; then the
# presented set is emptied, and on finishing the completion record naming
# the lock pid is replaced by rename.
cat > "$HELPERS/digest" <<'SH'
#!/usr/bin/env bash
state=$1
[ -z "${2:-}" ] || printf '%s\n' "$2" > "$state/.lock"
rm -f "$state/.main-eligible-rows"
tmp=$(mktemp "$state/.session-start-complete.XXXXXX")
sed -n '1p' "$state/.lock" > "$tmp"
mv -f "$tmp" "$state/.session-start-complete"
SH
# append-and-wake <name> <row> <session-id>: append one check row, then fire
# the waker as its FileChanged does. Prints <name>_RC and <name>_ELAPSED, the
# seconds from the row landing in the queue to the waker's exit.
cat > "$HELPERS/append-and-wake" <<'SH'
#!/usr/bin/env bash
"$HELPERS/append" "$FM_HOME/state" "$2" || exit 1
t0=${EPOCHREALTIME:-$("$HELPERS/now")}
"$HELPERS/payload" "$3" FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null
rc=$?
t1=${EPOCHREALTIME:-$("$HELPERS/now")}
printf '%s_RC=%s\n%s_ELAPSED=%s\n' "$1" "$rc" "$1" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
SH
# burst <session-id>: ten back-to-back appends from one process, then the ten
# FileChanged firings for them, all running at once. Prints REWAKES, the
# wakers that exited 2.
cat > "$HELPERS/burst" <<'SH'
#!/usr/bin/env bash
FM_STATE_OVERRIDE=$FM_HOME/state
# shellcheck source=/dev/null
. "$FM_HOME/bin/fm-wake-lib.sh"
for i in 1 2 3 4 5 6 7 8 9 10; do
  fm_wake_append check "wake-burst-$i" "check: burst-$i"
done
pids=
for i in 1 2 3 4 5 6 7 8 9 10; do
  "$HELPERS/payload" "$1" FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
  pids="$pids $!"
done
rewakes=0
for pid in $pids; do
  wait "$pid"
  [ "$?" -eq 2 ] && rewakes=$((rewakes + 1))
done
printf 'REWAKES=%s\n' "$rewakes"
SH
# in-turn-drain <state>: main drains in its turn and prints its ack command.
cat > "$HELPERS/in-turn-drain" <<'SH'
#!/usr/bin/env bash
FM_STATE_OVERRIDE="$1" "$DRAIN" 2>&1 | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1
SH
# ack <state> <ack-args>: run the acknowledgement the in-turn drain printed.
cat > "$HELPERS/ack" <<'SH'
#!/usr/bin/env bash
state=$1
shift
# shellcheck disable=SC2086 # the printed command's arguments
FM_STATE_OVERRIDE="$state" "$DRAIN" $* >/dev/null 2>&1
SH
chmod +x "$HELPERS"/*

# A sleep(1) stand-in put first on PATH for a Stop hook under test only. With
# FM_SLEEP_GATE set, its claim retry's `sleep 0.2` marks
# $FM_SLEEP_GATE/sleeping and holds until the test creates
# $FM_SLEEP_GATE/released, so a race replay lands its ledger write inside the
# retry whatever the host load; every other sleep runs as before.
SLEEP_GATE_BIN=$(fm_fakebin "$TMP_ROOT/sleep-gate")
REAL_SLEEP=$(command -v sleep) || fail "this host has no sleep to gate"
cat > "$SLEEP_GATE_BIN/sleep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = 0.2 ] && [ -n "\${FM_SLEEP_GATE:-}" ] && [ ! -e "\$FM_SLEEP_GATE/released" ]; then
  : > "\$FM_SLEEP_GATE/sleeping"
  i=0
  while [ ! -e "\$FM_SLEEP_GATE/released" ] && [ "\$i" -lt 2400 ]; do
    "$REAL_SLEEP" 0.05
    i=\$((i + 1))
  done
  exit 0
fi
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$SLEEP_GATE_BIN/sleep"
export SLEEP_GATE_BIN

install_wake_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-claude-turn.sh fm-claude-wake.sh fm-claude-stop-autoarm.sh \
    fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
    fm-path-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh \
    fm-hook-host-lib.sh fm-lock.sh fm-afk-contract.sh fm-classify-lib.sh \
    fm-timeout-lib.sh fm-supervision-engine-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cat > "$dir/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
printf 'tasks[0]{id,title,hold_kind,body}:\n'
SH
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
  chmod +x "$dir/bin"/*.sh
}

# A parked arm: its watcher beats, then waits until the test releases it,
# and closes with the wake line for the row that arrived meanwhile. A
# handling successor confirms a started watcher and exits.
install_parking_arm() {
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --cover-handoff ] || exit 0
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
: > "$FM_HOME/state/arm-waiting"
i=0
while [ ! -e "$FM_HOME/state/arm-release" ] && [ "$i" -lt 600 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf 'check: parked-note\n'
exit 0
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

# Numbered parked arms, for a sequence with several parks. Foreground arm N
# beats, writes state/arm-waiting.N, and waits for state/arm-release.N, which
# holds its close: a wake line, or "vanish", which ends supervision need
# (removes state/task.meta) and closes without an actionable reason. An arm
# started once that need is gone closes the same way at once. A handling
# successor confirms a started watcher and exits.
install_numbered_arms() {
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --cover-handoff ] || exit 0
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
if [ ! -e "$FM_HOME/state/task.meta" ]; then
  printf 'watcher: FAILED - cycle ended without an actionable reason\n'
  exit 1
fi
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
n=$(wc -l < "$FM_HOME/state/arm-ran" | tr -d ' ')
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
: > "$FM_HOME/state/arm-waiting.$n"
i=0
while [ ! -e "$FM_HOME/state/arm-release.$n" ] && [ "$i" -lt 600 ]; do
  sleep 0.05
  i=$((i + 1))
done
close=$(cat "$FM_HOME/state/arm-release.$n" 2>/dev/null || true)
if [ "$close" = vanish ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: FAILED - cycle ended without an actionable reason\n'
  exit 1
fi
printf '%s\n' "$close"
exit 0
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/config/supervision-host-off"
  install_wake_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run one body of bash as a child of the fake harness that owns the home's
# lock. The body sees FM_HOME, S (the state dir), and LOCK_PID, and writes
# STEP lines to stdout.
run_body() {
  local dir=$1 body=$2
  FM_HOME="$dir" FM_BODY="$body" "$FAKE_CLAUDE" -c '
    printf "%s\t%s\n" "$$" "$(LC_ALL=C ps -o lstart= -p "$$")" >> "$FM_TEST_PIDS"
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    LOCK_PID=$$
    S=$FM_HOME/state
    P=$HELPERS/payload
    eval "$FM_BODY"
  ' 2>&1
}

queue_row() { # <home> <payload>
  append_wake "$1/state" check "wake-$2" "check: $2"
}

ledger_outcome() { # <home>
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\).*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# expect <output> <line> <message>: the body printed exactly that STEP line.
expect() {
  printf '%s\n' "$1" | grep -qx -- "$2" || fail "$3, got: $1"
}

# within_second <output> <name>: <name>_ELAPSED, measured from the append to
# the waker's exit, is under one second.
within_second() {
  printf '%s\n' "$1" | sed -n "s/^$2_ELAPSED=//p" | awk '$1 != "" && $1 < 1 { ok=1 } END { exit !ok }' \
    || fail "$2: the waker must answer within a second of the append, got: $1"
}

test_turn_record_from_real_payloads() {
  local dir out primary
  dir=$(make_home "$TMP_ROOT/record")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "BUSY=%s\n" "$(cat "$S/.claude-turn")"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "IDLE=%s\n" "$(cat "$S/.claude-turn")"
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 StopFailure | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "FAILURE=%s\n" "$(cat "$S/.claude-turn")"
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"x\"}" | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "NOSESSION=%s\n" "$(cat "$S/.claude-turn")"
  ')
  printf '%s\n' "$out" | grep -Eq "^BUSY=busy [0-9]+ [0-9]+ sess-1$" \
    || fail "UserPromptSubmit must record a busy turn with the payload session, got: $out"
  [ "$(printf '%s\n' "$out" | sed -n 's/^BUSY=busy \([0-9]*\) .*/\1/p')" = \
    "$(printf '%s\n' "$out" | sed -n 's/^IDLE=idle \([0-9]*\) .*/\1/p')" ] \
    || fail "Stop must record idle and keep the turn-start epoch, got: $out"
  printf '%s\n' "$out" | grep -Eq "^FAILURE=idle [0-9]+ [0-9]+ sess-1$" \
    || fail "StopFailure must record idle, got: $out"
  printf '%s\n' "$out" | grep -Eq "^NOSESSION=busy [0-9]+ [0-9]+ -$" \
    || fail "a payload without session_id must record '-', got: $out"

  # A second session in the same home never writes the primary's record.
  sleep 30 &
  primary=$!
  fm_test_track_pid "$primary"
  printf '%s\n' "$primary" > "$dir/state/.lock.primary"
  printf 'idle 100 %s sess-primary\n' "$primary" > "$dir/state/.claude-turn"
  out=$(run_body "$dir" '
    cp "$S/.lock.primary" "$S/.lock"
    "$P" sess-other UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "AFTER_PROMPT=%s\n" "$(cat "$S/.claude-turn")"
    "$P" sess-other Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "AFTER_STOP=%s\n" "$(cat "$S/.claude-turn")"
  ')
  kill "$primary" 2>/dev/null || true
  wait "$primary" 2>/dev/null || true
  expect "$out" "AFTER_PROMPT=idle 100 $primary sess-primary" "a second session's prompt must leave the primary's record alone"
  expect "$out" "AFTER_STOP=idle 100 $primary sess-primary" "a second session's Stop must leave the primary's record alone"
  pass "turn record: real UserPromptSubmit, Stop, and StopFailure payloads; only the lock owner writes"
}

test_0706z_replay() {
  local dir out
  dir=$(make_home "$TMP_ROOT/0706z")
  out=$(FM_CLAUDE_WAKE_SESSION_WAIT=20 run_body "$dir" '
    printf "%s\n" "$LOCK_PID" > "$S/.session-start-complete"
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    touch "$S/.last-watcher-beat"
    # /clear: the old hook exits without delivering.
    "$HELPERS/old-claim" "$S" || echo OLD_CLAIM_FAILED
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
    w=$!
    "$HELPERS/wait-sleeping" "$w" || echo OPEN_DID_NOT_WAIT
    "$HELPERS/digest" "$S"
    wait "$w"; echo "OPEN_RC=$?"
    # +77 s: the covering watcher closes; its last beat is 73 s before +150 s.
    "$HELPERS/set-mtime" "$S/.last-watcher-beat" $(( $(date +%s) - 73 ))
    "$HELPERS/append-and-wake" FIRST first-note sess-2
    # The rewake turn starts in the second its rewake committed.
    "$HELPERS/ledger-at" "$S" $(( $(date +%s) + 2 ))
    "$P" sess-2 UserPromptSubmit rewake | "$FM_HOME/bin/fm-claude-turn.sh"
    ACK=$("$HELPERS/in-turn-drain" "$S")
    [ -n "$ACK" ] && "$HELPERS/ack" "$S" $ACK || echo ACK_FAILED
    "$P" sess-2 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-2 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; echo "STOP_RC=$?"
    # +330 s: the second note row; the watcher last beat 253 s ago.
    "$HELPERS/set-mtime" "$S/.last-watcher-beat" $(( $(date +%s) - 253 ))
    "$HELPERS/append-and-wake" SECOND second-note sess-2
  ')
  printf '%s\n' "$out" | grep -q 'OLD_CLAIM_FAILED\|OPEN_DID_NOT_WAIT\|ACK_FAILED' \
    && fail "07:06Z replay setup failed, got: $out"
  expect "$out" "OPEN_RC=0" "the session-open check must find nothing to deliver before any row"
  expect "$out" "FIRST_RC=2" "the +150 s note row must wake idle main"
  within_second "$out" FIRST
  expect "$out" "STOP_RC=0" "the handling turn's Stop hook must find nothing left"
  expect "$out" "SECOND_RC=2" "the +330 s note row must wake idle main after the first rewake's own turn"
  within_second "$out" SECOND
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "the second wake must commit a rewake, got: $out"
  pass "07:06Z replay: after /clear and a covering watcher close, the waker exits 2 within a second of the +150 s and +330 s appends"
}

test_reset_followup_expiry() {
  local dir out
  dir=$(make_home "$TMP_ROOT/expiry")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-turn.sh"
    # The follow-up hook that started the covering watcher has exited.
    "$HELPERS/old-claim" "$S" || echo OLD_CLAIM_FAILED
    # +180 s: the watcher is healthy.
    touch "$S/.last-watcher-beat"
    # +350 s: it closes undelivered, 170 s after its last beat, and its
    # close row is appended with no hook parked.
    "$HELPERS/set-mtime" "$S/.last-watcher-beat" $(( $(date +%s) - 170 ))
    "$HELPERS/append-and-wake" CLOSE close-note sess-2
  ')
  printf '%s\n' "$out" | grep -q 'OLD_CLAIM_FAILED' && fail "reset-followup setup failed, got: $out"
  expect "$out" "CLOSE_RC=2" "an undelivered watcher close with no parked hook must wake main"
  within_second "$out" CLOSE
  pass "reset-followup expiry: the waker exits 2 at the +350 s undelivered close append"
}

test_post_reset_rows_already_queued() {
  local dir out
  dir=$(make_home "$TMP_ROOT/postreset")
  out=$(FM_CLAUDE_WAKE_SESSION_WAIT=20 run_body "$dir" '
    printf "%s\n" "$LOCK_PID" > "$S/.session-start-complete"
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" pre-clear-note
    # Main drained the row in that turn, but its context is cleared before
    # the acknowledgement.
    [ -n "$("$HELPERS/in-turn-drain" "$S")" ] || echo DRAIN_FAILED
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; echo "PRECLEAR_STOP_RC=$?"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
    w=$!
    "$HELPERS/wait-sleeping" "$w" && echo OPEN_WAITED=yes
    "$HELPERS/digest" "$S"
    wait "$w"; echo "OPEN_RC=$?"
  ')
  printf '%s\n' "$out" | grep -q 'DRAIN_FAILED' && fail "post-reset setup failed, got: $out"
  expect "$out" "PRECLEAR_STOP_RC=0" "no hook may park or deliver for a row main already drained"
  expect "$out" "OPEN_WAITED=yes" "the /clear session-open check must wait for this open's digest"
  expect "$out" "OPEN_RC=2" "the session-open check must wake main for rows the reset left unread"
  pass "post-reset rows already queued: the /clear session-open check exits 2 once the digest completes"
}

test_fresh_startup_waits_for_its_lock() {
  local dir out
  dir=$(make_home "$TMP_ROOT/startup")
  out=$(FM_CLAUDE_WAKE_SESSION_WAIT=20 run_body "$dir" '
    D=$(bash -c "echo \$\$")
    while kill -0 "$D" 2>/dev/null; do D=$((D + 1)); done
    printf "%s\n" "$D" > "$S/.lock"
    printf "%s\n" "$D" > "$S/.session-start-complete"
    "$HELPERS/append" "$S" queued-while-away
    "$P" sess-1 SessionStart startup | "$FM_HOME/bin/fm-claude-turn.sh"
    [ -e "$S/.claude-turn" ] && echo RECORD_WRITTEN
    "$P" sess-1 SessionStart startup | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
    w=$!
    "$HELPERS/wait-sleeping" "$w" && echo OPEN_WAITED=yes
    "$HELPERS/digest" "$S" "$LOCK_PID"
    wait "$w"; echo "OPEN_RC=$?"
  ')
  printf '%s\n' "$out" | grep -q 'RECORD_WRITTEN' \
    && fail "a session that does not hold the lock yet must not write the turn record, got: $out"
  expect "$out" "OPEN_WAITED=yes" "the startup session-open check must wait while the lock still names the dead session"
  expect "$out" "OPEN_RC=2" "the startup session-open check must wake main once its digest takes the lock"
  pass "fresh startup: the session-open check waits for its own lock and digest, then exits 2"
}

test_interrupt_then_clear() {
  local dir out
  dir=$(make_home "$TMP_ROOT/interrupt")
  out=$(FM_CLAUDE_WAKE_SESSION_WAIT=20 run_body "$dir" '
    printf "%s\n" "$LOCK_PID" > "$S/.session-start-complete"
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" mid-turn-note
    # A manual interrupt fires no hook: the record stays busy.
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "BUSY_RC=$?"
    "$P" sess-1 SessionStart compact | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "AFTER_COMPACT=%s\n" "$(cut -d" " -f1 "$S/.claude-turn")"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "AFTER_CLEAR=%s\n" "$(cut -d" " -f1 "$S/.claude-turn")"
    "$P" sess-2 SessionStart clear | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
    w=$!
    "$HELPERS/wait-sleeping" "$w" || echo OPEN_DID_NOT_WAIT
    "$HELPERS/digest" "$S"
    wait "$w"; echo "OPEN_RC=$?"
  ')
  expect "$out" "BUSY_RC=0" "the waker must exit 0 while the interrupted turn reads busy"
  expect "$out" "AFTER_COMPACT=busy" "a compact, which can happen mid-turn, must not end the turn"
  expect "$out" "AFTER_CLEAR=idle" "a /clear session open must record that no turn is running"
  expect "$out" "OPEN_RC=2" "the session-open check after an interrupt and /clear must wake main"
  pass "interrupt then /clear: session open records idle, so the session-open check exits 2"
}

test_busy_turn_defers_then_stop_delivers_once() {
  local dir out
  dir=$(make_home "$TMP_ROOT/busy")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" mid-turn-note
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "BUSY_WAKE_RC=$?"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; echo "STOP_RC=$?"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "AFTER_WAKE_RC=$?"
  ')
  expect "$out" "BUSY_WAKE_RC=0" "the waker must exit 0 during a busy turn"
  expect "$out" "STOP_RC=2" "the Stop hook must deliver the mid-turn row at turn end"
  expect "$out" "AFTER_WAKE_RC=0" "exactly one rewake may follow a busy turn"
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "the single delivery must be the committed rewake, got: $out"
  pass "busy turn: the waker exits 0, the Stop hook delivers at turn end, exactly one rewake follows"
}

test_parked_hook_present_delivers() {
  local dir out
  dir=$(make_home "$TMP_ROOT/parked")
  install_parking_arm "$dir"
  : > "$dir/state/task.meta"
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/stop-err" &
    h=$!
    i=0
    while [ ! -e "$S/arm-waiting" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
    [ -e "$S/arm-waiting" ] && echo PARKED=yes
    "$HELPERS/append" "$S" parked-note
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "WAKE_RC=$?"
    : > "$S/arm-release"
    wait "$h"; echo "STOP_RC=$?"
    grep -qx "check: parked-note" "$S/stop-err" && echo DELIVERED=yes
  ')
  expect "$out" "PARKED=yes" "the Stop hook must park on its arm"
  expect "$out" "WAKE_RC=0" "the waker must exit 0 while a Stop hook is parked"
  expect "$out" "STOP_RC=2" "the parked hook must deliver when its watcher closes"
  expect "$out" "DELIVERED=yes" "the parked hook's rewake must carry the row"
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "the parked hook's delivery must be the committed rewake, got: $out"
  pass "parked hook present: the waker exits 0 and the parked hook delivers"
}

test_burst_produces_exactly_one_rewake() {
  local dir out
  dir=$(make_home "$TMP_ROOT/burst")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/burst" sess-1
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  expect "$out" "REWAKES=1" "ten concurrent firings must commit exactly one rewake"
  expect "$out" "LATE_RC=0" "a later firing must defer to the pending rewake"
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "the burst's rewake must stay committed, got: $out"
  pass "burst: ten appends whose ten waker firings run concurrently produce exactly one rewake"
}

# The burst race made deterministic: one firing (the test body) is inside its
# claim, holding the ledger mutex, when a second firing that already passed
# its checks waits on that mutex. The first then commits its rewake and lets
# go before the second retries.
test_burst_waiter_never_supersedes_a_commit() {
  local dir out
  dir=$(make_home "$TMP_ROOT/burstrace")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" race-note
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$S/.claude-autoarm.lock" || echo MUTEX_FAILED
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null &
    w=$!
    "$HELPERS/wait-sleeping" "$w" || echo SECOND_DID_NOT_WAIT
    printf "epoch=1 owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\n%s\n" \
      "$$" "$(date +%s)" "$LOCK_PID" "$(fm_pid_identity "$$")" > "$S/.claude-autoarm-epoch"
    fm_lock_release "$S/.claude-autoarm.lock"
    wait "$w"; echo "SECOND_RC=$?"
    sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/LEDGER=\1 \2/p" "$S/.claude-autoarm-epoch"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  printf '%s\n' "$out" | grep -q 'MUTEX_FAILED\|SECOND_DID_NOT_WAIT' && fail "burst race setup failed, got: $out"
  expect "$out" "SECOND_RC=0" "a firing that lost the claim race must not wake main again"
  expect "$out" "LEDGER=1 rewake" "a firing that lost the claim race must leave the committed rewake in place"
  expect "$out" "LATE_RC=0" "a later firing in the burst must still see the rewake pending"
  pass "burst race: a firing that waited on the ledger mutex never supersedes the rewake committed meanwhile"
}

test_foreign_hosts_exit_at_once() {
  local dir out
  dir=$(make_home "$TMP_ROOT/foreign")
  queue_row "$dir" "foreign-note"
  out=$(run_body "$dir" '
    start=$("$HELPERS/now")
    for event in FileChanged SessionStart; do
      printf "%s" "{\"cursor_version\":\"1\",\"session_id\":\"s\",\"hook_event_name\":\"$event\",\"source\":\"startup\"}" \
        | "$FM_HOME/bin/fm-claude-wake.sh"; echo "CURSOR_${event}_RC=$?"
      printf "%s" "{\"session_id\":\"s\",\"transcript_path\":\"/x/.pi/session.jsonl\",\"hook_event_name\":\"$event\",\"source\":\"startup\"}" \
        | "$FM_HOME/bin/fm-claude-wake.sh"; echo "PI_${event}_RC=$?"
    done
    printf "%s" "{\"cursor_version\":\"1\",\"session_id\":\"s\",\"hook_event_name\":\"UserPromptSubmit\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "%s" "{\"session_id\":\"s\",\"transcript_path\":\"/x/.pi/session.jsonl\",\"hook_event_name\":\"UserPromptSubmit\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"
    echo "ELAPSED=$(awk -v a="$start" -v b="$("$HELPERS/now")" "BEGIN { printf \"%.3f\", b - a }")"
  ')
  local name
  for name in CURSOR_FileChanged CURSOR_SessionStart PI_FileChanged PI_SessionStart; do
    expect "$out" "${name}_RC=0" "$name payload must exit 0"
  done
  printf '%s\n' "$out" | sed -n 's/^ELAPSED=//p' | awk '$1 < 3 { ok=1 } END { exit !ok }' \
    || fail "foreign payloads, SessionStart included, must never wait, got: $out"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "foreign payloads must not commit a rewake, got: $out"
  [ ! -e "$dir/state/.claude-turn" ] || fail "foreign payloads must not write the turn record, got: $out"
  pass "foreign hosts: Cursor and pi-code FileChanged and SessionStart payloads exit 0 at once and never wait"
}

test_stop_admission_parks_while_rewake_pending() {
  local dir out
  dir=$(make_home "$TMP_ROOT/pending")
  queue_row "$dir" "pending-note"
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$S" 300 || printf "CLAIM_FAILED\n"
    fm_autoarm_write_owned "$S" "$FM_AUTOARM_MY_GEN" rewake "" "$$" \
      || printf "COMMIT_FAILED\n"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; printf "STOP_RC=%s\n" "$?"
    if [ -s "$S/arm-ran" ]; then printf "PARKED=yes\n"; else printf "PARKED=no\n"; fi
  ')
  expect "$out" "STOP_RC=0" "Stop admission must not deliver while a rewake is pending"
  expect "$out" "PARKED=yes" "Stop admission must park instead of delivering"
  pass "turn boundary: Stop admission parks while a rewake is pending"
}

# Intent item 5 across a whole park: a parked hook delivers rewake R during a
# typed turn U, so U's Stop hook finds R pending and parks. R's own turn then
# runs, and a later row arrives that the watcher does not close for. When the
# park ends without an actionable reason, that row is still delivered.
test_parked_rewake_then_later_row_still_delivered() {
  local dir out
  dir=$(make_home "$TMP_ROOT/rewaketurn")
  install_numbered_arms "$dir"
  : > "$dir/state/task.meta"
  out=$(run_body "$dir" '
    release() { printf "%s\n" "$2" > "$S/release.tmp"; mv -f "$S/release.tmp" "$S/arm-release.$1"; }
    parked() {
      i=0
      while [ ! -e "$S/arm-waiting.$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
      [ -e "$S/arm-waiting.$1" ]
    }
    # An earlier turn ends and its Stop hook parks.
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/first-err" &
    first=$!
    parked 1 || echo FIRST_NOT_PARKED
    # Typed turn U starts a minute before its row arrives (injected epoch).
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    sed "s/^busy [0-9]* /busy $(( $(date +%s) - 60 )) /" "$S/.claude-turn" > "$S/turn.tmp" \
      && mv -f "$S/turn.tmp" "$S/.claude-turn"
    "$HELPERS/append" "$S" during-u
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "DURING_U_WAKE_RC=$?"
    # The parked hook delivers rewake R during U.
    release 1 "check: during-u"
    wait "$first"; echo "R_RC=$?"
    # U ends; its Stop hook finds R pending and parks instead of delivering.
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/park-err" &
    park=$!
    parked 2 && echo U_STOP_PARKED=yes
    # Rewake R runs its own turn: main drains and acknowledges the row, and
    # that turn ends with a Stop hook that defers to the park.
    "$P" sess-1 UserPromptSubmit rewake | "$FM_HOME/bin/fm-claude-turn.sh"
    ACK=$("$HELPERS/in-turn-drain" "$S")
    [ -n "$ACK" ] && "$HELPERS/ack" "$S" $ACK || echo ACK_FAILED
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; echo "R_STOP_RC=$?"
    # A later row the watcher does not close for; the waker defers to the park.
    "$HELPERS/append" "$S" after-r
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "AFTER_R_WAKE_RC=$?"
    # The park ends without an actionable reason once supervision need is gone.
    release 2 vanish
    wait "$park"; echo "PARK_RC=$?"
    grep -qx "check: after-r" "$S/park-err" && echo DELIVERED=yes
  ')
  printf '%s\n' "$out" | grep -q 'FIRST_NOT_PARKED\|ACK_FAILED' && fail "rewake-turn setup failed, got: $out"
  expect "$out" "DURING_U_WAKE_RC=0" "the waker must exit 0 during the typed turn"
  expect "$out" "R_RC=2" "the parked hook must deliver rewake R during the typed turn"
  expect "$out" "U_STOP_PARKED=yes" "the typed turn's Stop hook must park while R is pending"
  expect "$out" "R_STOP_RC=0" "R's own Stop hook must defer to the park"
  expect "$out" "AFTER_R_WAKE_RC=0" "the waker must defer to the parked hook"
  expect "$out" "PARK_RC=2" "the park must deliver the later row once R's own turn has run"
  expect "$out" "DELIVERED=yes" "the park's rewake must carry the later row"
  pass "turn boundary across a park: after rewake R's own turn has run, the parked hook still delivers a later row"
}

test_rewake_from_an_earlier_claude_is_not_pending() {
  local dir out
  dir=$(make_home "$TMP_ROOT/restart")
  queue_row "$dir" "after-restart-note"
  out=$(run_body "$dir" '
    # The previous Claude process committed a rewake; Dale restarted Claude.
    D=$(bash -c "echo \$\$")
    while kill -0 "$D" 2>/dev/null; do D=$((D + 1)); done
    printf "epoch=4 owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\nold-identity\n" \
      "$D" "$(date +%s)" "$D" > "$S/.claude-autoarm-epoch"
    printf "idle %s %s sess-old\n" "$(( $(date +%s) - 60 ))" "$D" > "$S/.claude-turn"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "WAKE_RC=$?"
  ')
  expect "$out" "WAKE_RC=2" "a rewake bound to an earlier Claude process must not suppress the new one"
  pass "restart: a rewake committed by an earlier Claude process is not pending in the new one"
}

test_stop_claim_loses_to_waker_rewake_committed_after_pending_read() {
  local dir out
  dir=$(make_home "$TMP_ROOT/stoprace")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" race-note
    "$HELPERS/old-claim" "$S" || echo OLD_CLAIM_FAILED
    . "$FM_HOME/bin/fm-wake-lib.sh"
    printf "epoch=2 owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\n%s\n" \
      "$$" "$(date +%s)" "$LOCK_PID" "$(fm_pid_identity "$$")" > "$S/.late-rewake"
    fm_lock_try_acquire "$S/.claude-autoarm.lock" || echo MUTEX_FAILED
    mkdir -p "$S/gate"
    "$P" sess-1 Stop | FM_SLEEP_GATE="$S/gate" PATH="$SLEEP_GATE_BIN:$PATH" \
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/stop-err" &
    h=$!
    "$HELPERS/wait-gated" "$S/gate" "$h" || echo STOP_DID_NOT_WAIT
    mv -f "$S/.late-rewake" "$S/.claude-autoarm-epoch"
    fm_lock_release "$S/.claude-autoarm.lock"
    : > "$S/gate/released"
    wait "$h"; echo "STOP_RC=$?"
    sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/LEDGER=\1 \2/p" "$S/.claude-autoarm-epoch"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  printf '%s\n' "$out" | grep -q 'OLD_CLAIM_FAILED\|MUTEX_FAILED\|STOP_DID_NOT_WAIT' \
    && fail "stop race setup failed, got: $out"
  expect "$out" "STOP_RC=0" "a Stop hook whose claim loses to a waker rewake committed after its pending read must not wake main again"
  expect "$out" "LEDGER=2 rewake" "the waker rewake committed after the pending read must stay the only rewake"
  expect "$out" "LATE_RC=0" "a later waker firing must still see the rewake pending"
  pass "stop race: a waker rewake committed between the pending read and the claim yields exactly one rewake"
}

test_stop_claim_loses_to_inflight_waker_rewake() {
  local dir out
  dir=$(make_home "$TMP_ROOT/stopinflight")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" inflight-note
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$S" 300 || echo CLAIM_FAILED
    printf "epoch=%s owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\n%s\n" \
      "$FM_AUTOARM_MY_GEN" "$$" "$(date +%s)" "$LOCK_PID" "$(sed -n 2p "$S/.claude-autoarm-epoch")" > "$S/.inflight-rewake"
    "$HELPERS/set-mtime" "$S/.claude-autoarm-epoch" "$(( $(date +%s) - 1000 ))"
    fm_lock_try_acquire "$S/.claude-autoarm.lock" || echo MUTEX_FAILED
    mkdir -p "$S/gate"
    "$P" sess-1 Stop | FM_SLEEP_GATE="$S/gate" PATH="$SLEEP_GATE_BIN:$PATH" \
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/stop-err" &
    h=$!
    "$HELPERS/wait-gated" "$S/gate" "$h" || echo STOP_DID_NOT_WAIT
    mv -f "$S/.inflight-rewake" "$S/.claude-autoarm-epoch"
    fm_lock_release "$S/.claude-autoarm.lock"
    : > "$S/gate/released"
    wait "$h"; echo "STOP_RC=$?"
    sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/LEDGER=\1 \2/p" "$S/.claude-autoarm-epoch"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  printf '%s\n' "$out" | grep -q 'CLAIM_FAILED\|MUTEX_FAILED\|STOP_DID_NOT_WAIT' \
    && fail "inflight stop race setup failed, got: $out"
  expect "$out" "STOP_RC=0" "a Stop hook whose pending read saw the waker claim still arming must not wake main again once that claim commits its rewake"
  expect "$out" "LEDGER=1 rewake" "the waker rewake committed at the generation the pending read saw must stay the only rewake"
  expect "$out" "LATE_RC=0" "a later waker firing must still see the rewake pending"
  pass "stop race: a waker rewake committed at the generation the pending read saw arming yields exactly one rewake"
}

test_waker_banner_carries_away_line_on_host_home() {
  local dir out
  dir=$(make_home "$TMP_ROOT/wakeaway")
  rm -f "$dir/config/supervision-host-off"
  FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" enter --words 'away for the day' >/dev/null 2>&1 \
    || fail "fixture: could not record away mode"
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" away-note
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>"$S/wake-err"; echo "WAKE_RC=$?"
    grep -Fqx "This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture." "$S/wake-err" && echo AWAY_LINE=yes || echo AWAY_LINE=no
  ')
  expect "$out" "WAKE_RC=2" "the waker must still wake main under an away record on a host home"
  expect "$out" "AWAY_LINE=yes" "a waker wake on a host home with a live away record must carry the away-posture line"

  dir=$(make_home "$TMP_ROOT/wakequiet")
  rm -f "$dir/config/supervision-host-off"
  FM_HOME="$dir" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" quiet-note
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>"$S/wake-err"; echo "WAKE_RC=$?"
    grep -Fqx "This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture." "$S/wake-err" && echo AWAY_LINE=yes || echo AWAY_LINE=no
  ')
  expect "$out" "WAKE_RC=2" "the waker must wake main beside a quiet record"
  expect "$out" "AWAY_LINE=no" "a waker wake beside a quiet record must carry no away-posture line"

  dir=$(make_home "$TMP_ROOT/wakenone")
  rm -f "$dir/config/supervision-host-off"
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" plain-note
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>"$S/wake-err"; echo "WAKE_RC=$?"
    grep -Fqx "This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture." "$S/wake-err" && echo AWAY_LINE=yes || echo AWAY_LINE=no
  ')
  expect "$out" "WAKE_RC=2" "the waker must wake main with no away record"
  expect "$out" "AWAY_LINE=no" "a waker wake with no away record must carry no away-posture line"
  pass "waker banner: a host home with a live away record carries the away-posture line, quiet and no record do not"
}

test_session_start_drain_presents_without_claiming() {
  local dir state seq gen out ack_rc=0 drain_out
  dir="$TMP_ROOT/presentonly"
  state="$dir/state"
  mkdir -p "$state"
  append_wake "$state" check present-row "check: present without claiming" \
    || fail "seed wake failed"
  seq=$(awk -F '\t' '{print $2}' "$state/.wake-queue")
  marker_before=$(cat "$state/.watcher-down" 2>/dev/null || true)
  out=$(FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENT_ONLY=1 \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "present-only drain failed: $out"
  printf '%s\n' "$out" | grep -q 'present without claiming' \
    || fail "present-only drain must print the row, got: $out"
  [ ! -e "$state/.main-eligible-rows" ] \
    || fail "present-only drain must not write main's presented set"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "$marker_before" ] \
    || fail "present-only drain must not begin handling"
  [ -s "$state/.wake-queue" ] || fail "present-only drain must leave the row queued"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$seq" --recovery-generation fixture-gen >/dev/null 2>&1 || ack_rc=$?
  [ "$ack_rc" -ne 0 ] || fail "an acknowledgement typed from the digest alone must be refused"
  [ -s "$state/.wake-queue" ] || fail "a refused acknowledgement must leave the row queued"
  drain_out=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "in-turn drain failed: $drain_out"
  seq=$(printf '%s\n' "$drain_out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) .*$/\1/p' | tail -1)
  gen=$(printf '%s\n' "$drain_out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$seq" ] && [ -n "$gen" ] || fail "in-turn drain must print its acknowledgement: $drain_out"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 \
    || fail "acknowledgement after an in-turn drain must succeed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement must consume the row"
  pass "session-start drain presents without claiming; digest-only ack refused"
}

test_session_start_drain_excludes_branch_grant() {
  local state out
  state="$TMP_ROOT/presentgrant/state"
  mkdir -p "$state"
  append_wake "$state" check main-row "check: main row at session start" || fail "seed main wake failed"
  append_wake "$state" signal branch-row "signal: branch row at session start" || fail "seed branch wake failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" present-grant \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish present-grant 2 \
    || fail "branch grant publication failed"
  out=$(FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENT_ONLY=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "present-only drain failed: $out"
  printf '%s\n' "$out" | grep -q 'main row at session start' \
    || fail "present-only drain must print main's row, got: $out"
  printf '%s\n' "$out" | grep -q 'branch row at session start' \
    && fail "present-only drain must not present a row the live branch grant reserves, got: $out"

  state="$TMP_ROOT/presentheld/state"
  mkdir -p "$state"
  append_wake "$state" signal held-row "signal: held by the branch" || fail "seed held wake failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" held-grant \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish held-grant 1 \
    || fail "branch grant publication failed"
  out=$(FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENT_ONLY=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "present-only drain failed: $out"
  printf '%s\n' "$out" | grep -q 'held by the branch' \
    && fail "present-only drain must not present the branch's held row, got: $out"
  printf '%s\n' "$out" | grep -q '^WAKE ROWS HELD BY SUPERVISION BRANCH: 1 queued row(s) (1)' \
    || fail "present-only drain must say the branch holds the queued row, got: $out"
  pass "session-start drain presents only main's rows and names rows a live branch grant holds"
}

test_turn_record_from_real_payloads
test_0706z_replay
test_reset_followup_expiry
test_post_reset_rows_already_queued
test_fresh_startup_waits_for_its_lock
test_interrupt_then_clear
test_busy_turn_defers_then_stop_delivers_once
test_parked_hook_present_delivers
test_burst_produces_exactly_one_rewake
test_burst_waiter_never_supersedes_a_commit
test_foreign_hosts_exit_at_once
test_stop_admission_parks_while_rewake_pending
test_parked_rewake_then_later_row_still_delivered
test_rewake_from_an_earlier_claude_is_not_pending
test_stop_claim_loses_to_waker_rewake_committed_after_pending_read
test_stop_claim_loses_to_inflight_waker_rewake
test_waker_banner_carries_away_line_on_host_home
test_session_start_drain_presents_without_claiming
test_session_start_drain_excludes_branch_grant
