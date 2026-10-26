#!/usr/bin/env bash
# Behavior tests for ship 2 of the wake-record plan: the Claude turn record
# (bin/fm-claude-turn.sh), the Claude waker (bin/fm-claude-wake.sh), the
# session-start present-without-claim drain, and the Stop hook's
# rewake-pending admission guard.
#
# Every case runs in an isolated temporary home as a child of a fake harness
# (a bash symlink named "claude") whose pid owns the fixture home's session
# lock, so no live home, watcher, or Claude session is touched.
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
# lock. The body sees FM_HOME and LOCK_PID, and writes STEP lines to stdout.
run_body() {
  local dir=$1 body=$2
  FM_HOME="$dir" FM_BODY="$body" "$FAKE_CLAUDE" -c '
    printf "%s\t%s\n" "$$" "$(LC_ALL=C ps -o lstart= -p "$$")" >> "$FM_TEST_PIDS"
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    LOCK_PID=$$
    eval "$FM_BODY"
  ' 2>&1
}

queue_row() { # <home> <payload>
  append_wake "$1/state" check "wake-$2" "check: $2"
}

ledger_outcome() { # <home>
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\).*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_turn_record_and_waker_wakes_idle_main() {
  local dir out rc_file
  dir=$(make_home "$TMP_ROOT/idle")
  queue_row "$dir" "first-note"
  out=$(run_body "$dir" '
    start=$(python3 -c "import time; print(time.time())")
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; rc=$?
    end=$(python3 -c "import time; print(time.time())")
    printf "WAKE_RC=%s ELAPSED=%s\n" "$rc" "$(printf "%s %s" "$end" "$start" | awk "{print \$1-\$2}")"
  ')
  printf '%s\n' "$out" | grep -q 'WAKE_RC=2' || fail "idle main with an unread row: waker must exit 2, got: $out"
  printf '%s\n' "$out" | awk -F'ELAPSED=' '{print $2}' | awk '$1 < 2 {ok=1} END {exit !ok}' \
    || fail "waker must answer promptly after the append, got: $out"
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "waker must commit a rewake outcome, got: $out"
  pass "07:06Z replay: waker exits 2 within a second of the first append, no stall nudge"
}

test_waker_reads_other_pid_turn_as_idle() {
  local dir out
  dir=$(make_home "$TMP_ROOT/otherpid")
  queue_row "$dir" "queued-note"
  printf 'busy %s 999999 sess-dead\n' "$(date +%s)" > "$dir/state/.claude-turn"
  out=$(run_body "$dir" '
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; rc=$?
    printf "WAKE_RC=%s\n" "$rc"
  ')
  printf '%s\n' "$out" | grep -q 'WAKE_RC=2' || fail "a turn left open by a dead pid must read idle, got: $out"
  pass "turn record from another pid reads as idle"
}

test_busy_turn_defers_then_stop_delivers_once() {
  local dir out
  dir=$(make_home "$TMP_ROOT/busy")
  queue_row "$dir" "mid-turn-note"
  out=$(run_body "$dir" '
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"UserPromptSubmit\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"; printf "TURN_RC=%s\n" "$?"
    printf "RECORD=%s\n" "$(cat "$FM_HOME/state/.claude-turn")"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "BUSY_WAKE_RC=%s\n" "$?"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\"}" \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; printf "STOP_RC=%s\n" "$?"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "AFTER_WAKE_RC=%s\n" "$?"
  ')
  printf '%s\n' "$out" | grep -q '^RECORD=busy ' || fail "UserPromptSubmit must record a busy turn, got: $out"
  printf '%s\n' "$out" | grep -q 'BUSY_WAKE_RC=0' || fail "waker must exit 0 during a busy turn, got: $out"
  printf '%s\n' "$out" | grep -q 'STOP_RC=2' || fail "Stop hook must deliver the mid-turn row at turn end, got: $out"
  printf '%s\n' "$out" | grep -q 'AFTER_WAKE_RC=0' || fail "exactly one rewake may follow a busy turn, got: $out"
  [ "$(ledger_outcome "$dir")" = rewake ] || fail "the single delivery must be the committed rewake, got: $out"
  pass "busy turn: waker exits 0, Stop hook delivers at turn end, exactly one rewake"
}

test_parked_hook_present_defers() {
  local dir out
  dir=$(make_home "$TMP_ROOT/parked")
  queue_row "$dir" "parked-note"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_body "$dir" '
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$FM_HOME/state" 300 || printf "CLAIM_FAILED\n"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "WAKE_RC=%s\n" "$?"
  ')
  printf '%s\n' "$out" | grep -q 'WAKE_RC=0' || fail "waker must exit 0 while a Stop hook claim is parked, got: $out"
  [ "$(ledger_outcome "$dir")" = arming ] || fail "the parked claim must stay the delivery owner, got: $out"
  pass "parked hook present: waker exits 0 and the parked hook delivers"
}

test_session_open_waits_for_digest_then_wakes() {
  local dir out
  dir=$(make_home "$TMP_ROOT/sessionopen")
  queue_row "$dir" "pre-clear-note"
  out=$(FM_CLAUDE_WAKE_SESSION_WAIT=5 run_body "$dir" '
    ( sleep 0.3; printf "%s\n" "$$" > "$FM_HOME/state/.session-start-complete" ) &
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"SessionStart\",\"source\":\"clear\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "WAKE_RC=%s\n" "$?"
    wait
  ')
  printf '%s\n' "$out" | grep -q 'WAKE_RC=2' || fail "session-open check must exit 2 once the digest completes, got: $out"
  pass "post-reset rows already queued: session-open check exits 2 after the digest"
}

test_watchers_close_undelivered_still_wakes() {
  local dir out
  dir=$(make_home "$TMP_ROOT/expiry")
  touch "$dir/state/.last-watcher-beat"
  queue_row "$dir" "expiry-note"
  out=$(run_body "$dir" '
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "WAKE_RC=%s\n" "$?"
  ')
  printf '%s\n' "$out" | grep -q 'WAKE_RC=2' || fail "an undelivered watcher close must still wake main, got: $out"
  pass "reset-followup expiry: waker exits 2 at the undelivered close append"
}

test_burst_produces_exactly_one_rewake() {
  local dir out i
  dir=$(make_home "$TMP_ROOT/burst")
  for i in 1 2 3 4 5 6 7 8 9 10; do queue_row "$dir" "burst-$i"; done
  out=$(run_body "$dir" '
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; printf "FIRST=%s\n" "$?"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; printf "SECOND=%s\n" "$?"
  ')
  printf '%s\n' "$out" | grep -q 'FIRST=2' || fail "burst: first waker must exit 2, got: $out"
  printf '%s\n' "$out" | grep -q 'SECOND=0' || fail "burst: a pending rewake must suppress duplicates, got: $out"
  pass "burst: ten appends within a second produce exactly one rewake"
}

test_foreign_hosts_exit_at_once() {
  local dir out
  dir=$(make_home "$TMP_ROOT/foreign")
  queue_row "$dir" "foreign-note"
  out=$(run_body "$dir" '
    start=$(date +%s)
    printf "%s" "{\"cursor_version\":\"1\",\"session_id\":\"s\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "CURSOR_RC=%s\n" "$?"
    printf "%s" "{\"session_id\":\"s\",\"transcript_path\":\"/x/.pi/session.jsonl\",\"hook_event_name\":\"FileChanged\"}" \
      | "$FM_HOME/bin/fm-claude-wake.sh"; printf "PI_RC=%s\n" "$?"
    printf "ELAPSED=%s\n" "$(( $(date +%s) - start ))"
  ')
  printf '%s\n' "$out" | grep -q 'CURSOR_RC=0' || fail "Cursor payload must exit 0, got: $out"
  printf '%s\n' "$out" | grep -q 'PI_RC=0' || fail "pi-code payload must exit 0, got: $out"
  printf '%s\n' "$out" | grep -Eq 'ELAPSED=[01]' || fail "foreign payloads must never wait, got: $out"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "foreign payloads must not commit a rewake, got: $out"
  pass "foreign hosts: Cursor and pi-code payloads exit 0 at once and never wait"
}

test_stop_admission_parks_while_rewake_pending() {
  local dir out
  dir=$(make_home "$TMP_ROOT/pending")
  queue_row "$dir" "pending-note"
  out=$(run_body "$dir" '
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"UserPromptSubmit\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$FM_HOME/state" 300 || printf "CLAIM_FAILED\n"
    fm_autoarm_write_owned "$FM_HOME/state" "$FM_AUTOARM_MY_GEN" rewake "" "$$" \
      || printf "COMMIT_FAILED\n"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\"}" \
      | "$FM_HOME/bin/fm-claude-turn.sh"
    printf "%s" "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\"}" \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>/dev/null; printf "STOP_RC=%s\n" "$?"
    if [ -s "$FM_HOME/state/arm-ran" ]; then printf "PARKED=yes\n"; else printf "PARKED=no\n"; fi
  ')
  printf '%s\n' "$out" | grep -q 'STOP_RC=0' || fail "Stop admission must not deliver while a rewake is pending, got: $out"
  printf '%s\n' "$out" | grep -q 'PARKED=yes' || fail "Stop admission must park instead of delivering, got: $out"
  pass "turn boundary: Stop admission parks while a rewake is pending"
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

test_turn_record_and_waker_wakes_idle_main
test_waker_reads_other_pid_turn_as_idle
test_busy_turn_defers_then_stop_delivers_once
test_parked_hook_present_defers
test_session_open_waits_for_digest_then_wakes
test_watchers_close_undelivered_still_wakes
test_burst_produces_exactly_one_rewake
test_foreign_hosts_exit_at_once
test_stop_admission_parks_while_rewake_pending
test_session_start_drain_presents_without_claiming
