#!/usr/bin/env bash
# Fake-boundary tests for the opt-in scheduled Codex primary controller.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TICK="$ROOT/bin/fm-primary-tick.sh"
TMP_ROOT=$(fm_test_tmproot fm-primary-tick)
SESSION_UUID=11111111-2222-4333-8444-555555555555
DEAD_PID=9000000

setup_case() {  # <name>
  local name=$1 base
  base="$TMP_ROOT/$name"
  CASE_HOME="$base/home"
  CASE_FAKEBIN="$base/fakebin"
  CASE_RECOVERY="$base/recovery-window"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/config" "$CASE_HOME/.codex" \
    "$CASE_HOME/bin" "$CASE_FAKEBIN"
  cp "$ROOT/AGENTS.md" "$CASE_HOME/AGENTS.md"
  git -C "$CASE_HOME" init -q
  git -C "$CASE_HOME" config user.name Fixture
  git -C "$CASE_HOME" config user.email fixture@example.invalid
  cat > "$CASE_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
shift 2 # exact configured -S socket
command_name=${1:-}
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$FM_FAKE_TMUX_LOG"
case "$command_name" in
  list-panes)
    if [ "${FM_FAKE_DUPLICATE_PANES:-}" = 1 ]; then
      printf '%%3\t/dev/ttys009\n%%4\t/dev/ttys009\n'
    else
      printf '%%3\t/dev/ttys009\n'
    fi
    ;;
  list-clients)
    [ "${FM_FAKE_CLIENTS:-}" != error ] || exit 1
    [ "${FM_FAKE_CLIENTS:-}" != 1 ] || printf 'client-1\n'
    ;;
  capture-pane)
    if [ "${1:-}" = -e ]; then
      case "$(cat "$FM_FAKE_COMPOSER_FILE")" in
        pending|typed) printf '╭────────────╮\n│ › wake      │\n╰────────────╯\n' ;;
        empty) printf '╭────────────╮\n│ › \033[2mtip\033[0m      │\n╰────────────╯\n' ;;
        *) printf 'unknown pane rendering\n' ;;
      esac
    elif [ "$(cat "$FM_FAKE_BUSY_FILE")" = busy ]; then
      printf 'Working\nesc to interrupt\n'
    else
      printf 'Codex\n? for shortcuts\n'
    fi
    ;;
  display-message)
    case "$*" in
      *cursor_y*) printf '1\n' ;;
      *pane_id*) printf '%%3\n' ;;
      *) exit 1 ;;
    esac
    ;;
  has-session)
    [ "${FM_FAKE_SESSION_EXISTS:-1}" = 1 ]
    ;;
  list-windows)
    if [ -f "$FM_FAKE_RECOVERY_FILE" ]; then
      printf 'fm-primary-clock-11111111\t%s\n' "$FM_PRIMARY_SESSION_UUID"
    fi
    ;;
  send-keys)
    case "$*" in
      *' -l '*) printf 'typed\n' > "$FM_FAKE_COMPOSER_FILE" ;;
      *' Enter'*)
        if [ "${FM_FAKE_SUBMIT_MODE:-clear}" = clear ]; then
          printf 'empty\n' > "$FM_FAKE_COMPOSER_FILE"
          printf 'busy\n' > "$FM_FAKE_BUSY_FILE"
        fi
        ;;
    esac
    ;;
  new-window|new-session)
    printf 'recovery\n' > "$FM_FAKE_RECOVERY_FILE"
    printf '@99\n'
    ;;
  set-window-option) ;;
  *) exit 1 ;;
esac
SH
  cat > "$CASE_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
args="$*"
case " $args " in
  *' -axo pid=,comm=,args= '*)
    case "${FM_FAKE_PS_MODE:-live}" in
      ps-error) exit 1 ;;
      dead) exit 0 ;;
      dead-pid-error) exit 0 ;;
      duplicate)
        printf '%s codex codex resume %s --model gpt-6-luna -c model_reasoning_effort=max --sandbox danger-full-access --ask-for-approval never --cd %s\n' \
          "$FM_FAKE_OWNER_PID" "$FM_PRIMARY_SESSION_UUID" "$FM_ROOT_OVERRIDE"
        printf '%s codex codex resume %s --model gpt-6-luna -c model_reasoning_effort=max --sandbox danger-full-access --ask-for-approval never --cd %s\n' \
          "$((FM_FAKE_OWNER_PID + 1))" "$FM_PRIMARY_SESSION_UUID" "$FM_ROOT_OVERRIDE"
        ;;
      live)
        printf '%s codex codex resume %s --model gpt-6-luna -c model_reasoning_effort=max --sandbox danger-full-access --ask-for-approval never --cd %s\n' \
          "$FM_FAKE_OWNER_PID" "$FM_PRIMARY_SESSION_UUID" "$FM_ROOT_OVERRIDE"
        ;;
      *) exit 2 ;;
    esac
    ;;
  *' -o tty= -o args= '*)
    [ "${FM_FAKE_PS_MODE:-live}" != ps-error ] || exit 1
    printf 'ttys009 codex resume %s --model gpt-6-luna -c model_reasoning_effort=max --sandbox danger-full-access --ask-for-approval never --cd %s\n' \
      "$FM_PRIMARY_SESSION_UUID" "$FM_ROOT_OVERRIDE"
    ;;
  *' -o comm= -p '*) printf 'codex\n' ;;
  *' -o lstart= -o command= '*) printf 'Mon Jan 1 00:00:00 2026 /bin/bash fixture\n' ;;
  *' -o pid= '*)
    case "${FM_FAKE_PS_MODE:-live}" in
      dead|ps-error) exit 0 ;;
      dead-pid-error) exit 1 ;;
      *) printf '%s\n' "$FM_FAKE_OWNER_PID" ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$CASE_FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$CASE_FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_FAKEBIN/tmux" "$CASE_FAKEBIN/ps" "$CASE_FAKEBIN/sleep" "$CASE_FAKEBIN/codex"
  : > "$base/tmux.log"
  printf 'empty\n' > "$base/composer"
  printf 'idle\n' > "$base/busy"
  : > "$CASE_HOME/state/.lock"
  CASE_BASE="$base"
}

prepare_live() {
  printf '%s\n' "$$" > "$CASE_HOME/state/.lock"
}

seed_wake() {
  printf '100\t1\theartbeat\ttest-wake\tfixture durable work\n' > "$CASE_HOME/state/.wake-queue"
}

run_tick() {
  local owner=$1 mode=$2
  shift 2
  env \
    PATH="$CASE_FAKEBIN:$PATH" \
    FM_HOME="$CASE_HOME" \
    FM_ROOT_OVERRIDE="$CASE_HOME" \
    CODEX_HOME="$CASE_HOME/.codex" \
    FM_STATE_OVERRIDE="$CASE_BASE/unpinned-state" \
    FM_WAKE_QUEUE="$CASE_BASE/unpinned-queue" \
    FM_WAKE_QUEUE_LOCK="$CASE_BASE/unpinned-queue.lock" \
    FM_PRIMARY_SESSION_UUID="$SESSION_UUID" \
    FM_PRIMARY_TMUX_SESSION=primary-test \
    FM_PRIMARY_TMUX_SOCKET="$CASE_BASE/tmux.sock" \
    FM_PRIMARY_TMUX_BIN="$CASE_FAKEBIN/tmux" \
    FM_PRIMARY_CODEX_BIN="$CASE_FAKEBIN/codex" \
    FM_FAKE_OWNER_PID="$owner" \
    FM_FAKE_PS_MODE="$mode" \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    FM_FAKE_COMPOSER_FILE="$CASE_BASE/composer" \
    FM_FAKE_BUSY_FILE="$CASE_BASE/busy" \
    FM_FAKE_RECOVERY_FILE="$CASE_RECOVERY" \
    "$TICK" "$@"
}

count_types() {
  grep -c 'send-keys -t %3 -l ' "$CASE_BASE/tmux.log" 2>/dev/null || true
}

test_quiet_reconciliation_does_not_create_a_task_or_queue_record() {
  setup_case no-work
  prepare_live
  local out
  out=$(run_tick "$$" live) || fail "no-work tick refused a pinned live primary: $out"
  assert_contains "$out" 'idle wake confirmed' "quiet interval should request bounded primary reconciliation"
  assert_contains "$(<"$CASE_BASE/tmux.log")" 'create no tasks when nothing is eligible' \
    "quiet prompt must leave eligibility and task creation to the primary"
  [ ! -e "$CASE_HOME/state/.wake-queue" ] || fail "clock manufactured a queue record"
  [ -z "$(find "$CASE_HOME/state" -name '*.meta' -print -quit)" ] || fail "clock created a task metadata file"
  assert_equals 1 "$(count_types)" "quiet reconciliation prompt should be typed once"
  pass "primary clock: quiet intervals reconcile without creating a task or durable wake"
}

test_live_busy_leaves_durable_work_for_checkpoint() {
  setup_case busy
  prepare_live
  seed_wake
  : > "$CASE_BASE/unpinned-queue"
  printf 'busy\n' > "$CASE_BASE/busy"
  local out
  out=$(run_tick "$$" live) || fail "busy tick refused a pinned live primary: $out"
  assert_contains "$out" 'live busy:' "busy primary should defer to its next checkpoint"
  assert_contains "$out" 'existing durable wakes' "clock did not read the pinned home's durable wake queue"
  assert_equals 0 "$(count_types)" "busy primary received terminal input"
  [ ! -e "$CASE_BASE/unpinned-queue.lock" ] || fail "clock used an inherited queue lock outside FM_HOME"
  pass "primary clock: live busy primary keeps its durable wake without terminal input"
}

test_idle_empty_prompt_delivers_existing_wake_once() {
  setup_case idle
  prepare_live
  seed_wake
  local out
  out=$(run_tick "$$" live) || fail "safe idle wake failed: $out"
  assert_contains "$out" 'idle wake confirmed' "idle delivery must be confirmed by native busy transition"
  assert_equals 1 "$(count_types)" "idle delivery must type the wake exactly once"
  pass "primary clock: safe idle delivery types once and confirms a native busy transition"
}

test_idle_human_input_or_attached_client_is_preserved() {
  local out rc
  setup_case typed
  prepare_live
  seed_wake
  printf 'pending\n' > "$CASE_BASE/composer"
  out=$(run_tick "$$" live) || fail "pending composer should defer without failure: $out"
  assert_contains "$out" 'preserving user input' "pending composer must be preserved"
  assert_equals 0 "$(count_types)" "pending composer was overwritten"

  setup_case composer-unknown
  prepare_live
  seed_wake
  printf 'unrecognized\n' > "$CASE_BASE/composer"
  out=$(run_tick "$$" live) || fail "ambiguous composer should defer without failure: $out"
  assert_contains "$out" "composer state 'unknown'" "ambiguous composer must defer"
  assert_equals 0 "$(count_types)" "ambiguous composer received terminal input"

  setup_case attached
  prepare_live
  seed_wake
  out=$(FM_FAKE_CLIENTS=1 run_tick "$$" live) || fail "attached-client guard failed: $out"
  assert_contains "$out" 'attached tmux client' "attached client must defer delivery"
  assert_equals 0 "$(count_types)" "attached client received terminal input"

  setup_case endpoint-ambiguous
  prepare_live
  seed_wake
  out=$(FM_FAKE_DUPLICATE_PANES=1 run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate TTY-to-pane mapping was accepted"
  assert_contains "$out" 'not bound to exactly one pane' "ambiguous pane binding refusal missing"
  assert_equals 0 "$(count_types)" "ambiguous pane mapping received terminal input"

  setup_case client-state-unknown
  prepare_live
  seed_wake
  out=$(FM_FAKE_CLIENTS=error run_tick "$$" live) || fail "unreadable client state should defer safely: $out"
  assert_contains "$out" 'attached tmux client or unreadable client state' "unreadable client state did not defer"
  assert_equals 0 "$(count_types)" "unreadable client inventory received terminal input"

  setup_case away-mode
  prepare_live
  seed_wake
  : > "$CASE_HOME/state/.afk-contract"
  out=$(run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "normal clock acted while away mode owned supervision"
  assert_contains "$out" 'away-mode ownership is present' "away-mode refusal missing"
  assert_equals 0 "$(count_types)" "normal clock injected during away mode"
  pass "primary clock: pending user text and attached clients block automatic delivery"
}

test_process_identity_ambiguity_refuses_delivery() {
  setup_case ambiguous
  prepare_live
  seed_wake
  local out rc
  out=$(run_tick "$$" duplicate 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate native UUID process inventory was accepted"
  assert_contains "$out" 'one exact pinned Codex owner' "ambiguous process inventory refusal missing"
  assert_equals 0 "$(count_types)" "ambiguous identity caused terminal input"
  pass "primary clock: duplicate native UUID process evidence fails closed"
}

test_model_and_home_mismatch_refuse_before_dispatch() {
  setup_case model
  prepare_live
  local out rc
  out=$(FM_PRIMARY_MODEL=gpt-6-astra run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "non-pinned model was accepted"
  assert_contains "$out" 'model must remain gpt-6-luna' "model identity refusal missing"
  assert_equals 0 "$(count_types)" "model mismatch caused terminal input"

  setup_case home-mismatch
  local other="$CASE_BASE/other-code"
  mkdir -p "$other/bin"
  cp "$ROOT/AGENTS.md" "$other/AGENTS.md"
  git -C "$other" init -q
  out=$(env \
    FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$other" CODEX_HOME="$CASE_HOME/.codex" \
    FM_PRIMARY_SESSION_UUID="$SESSION_UUID" FM_PRIMARY_TMUX_SESSION=primary-test \
    FM_PRIMARY_TMUX_SOCKET="$CASE_BASE/tmux.sock" FM_PRIMARY_TMUX_BIN="$CASE_FAKEBIN/tmux" \
    FM_PRIMARY_CODEX_BIN="$CASE_FAKEBIN/codex" PATH="$CASE_FAKEBIN:$PATH" \
    "$TICK" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a code root from another repository was accepted"
  assert_contains "$out" "not the operational home's repository" "home/code-root mismatch refusal missing"
  pass "primary clock: pinned model and same-repository home/root identity are enforced"
}

test_confirmed_death_recovers_once_with_pinned_settings() {
  setup_case recovery
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  local out command_line
  out=$(run_tick "$DEAD_PID" dead --check) || fail "confirmed-dead check refused: $out"
  assert_contains "$out" 'confirmed-dead primary is eligible' "check mode must identify eligible recovery"
  assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "check mode launched a replacement"

  out=$(run_tick "$DEAD_PID" dead) || fail "confirmed-dead recovery failed: $out"
  assert_contains "$out" 'same native session resume launched' "recovery launch was not reported"
  command_line=$(grep '^new-window ' "$CASE_BASE/tmux.log")
  assert_contains "$command_line" 'FM_HOME=' "resume command omitted the pinned Firstmate home"
  assert_contains "$command_line" 'FM_ROOT_OVERRIDE=' "resume command omitted the pinned code root"
  assert_contains "$command_line" 'CODEX_HOME=' "resume command omitted the pinned Codex home"
  assert_contains "$command_line" "$SESSION_UUID" "resume command changed the native session UUID"
  assert_contains "$command_line" '--model gpt-6-luna' "resume command changed the model"
  assert_contains "$command_line" 'model_reasoning_effort="max"' "resume command changed reasoning effort"
  assert_contains "$command_line" '--sandbox danger-full-access' "resume command changed sandbox"
  assert_contains "$command_line" '--ask-for-approval never' "resume command changed approval posture"
  assert_contains "$command_line" 'FM_BOOTSTRAP_DETECT_ONLY=1' "resume could repeat startup mutation sweeps"
  assert_contains "$command_line" 'FM_CODEX_WATCH_CHECKPOINT=900' "resume omitted the bounded checkpoint cadence"

  out=$(run_tick "$DEAD_PID" dead) || fail "repeat tick failed: $out"
  assert_contains "$out" 'already exists' "repeat tick did not preserve the existing recovery window"
  assert_equals 1 "$(grep -c '^new-window ' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "repeat tick dispatched a second recovery owner"
  pass "primary clock: confirmed death resumes the same UUID once and preserves its recovery window"
}

test_dead_or_unreadable_process_inventory_never_recovers() {
  setup_case ps-error
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  local out rc
  out=$(run_tick "$DEAD_PID" ps-error 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable process table licensed recovery"
  assert_contains "$out" 'process table is ambiguous' "global process-table refusal missing"
  assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "ambiguous PID evidence launched a replacement"

  setup_case dead-pid-error
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  out=$(run_tick "$DEAD_PID" dead-pid-error 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable PID-specific process query licensed recovery"
  assert_contains "$out" 'could not independently confirm' "PID-specific process-table refusal missing"
  assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "ambiguous PID query launched a replacement"
  pass "primary clock: process-table errors are not interpreted as confirmed death"
}

test_malformed_primary_lock_never_recovers() {
  setup_case malformed-lock
  printf '%s\n%s\n' "$DEAD_PID" 12345 > "$CASE_HOME/state/.lock"
  local out rc
  out=$(run_tick "$DEAD_PID" dead 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "multi-line primary lock was accepted"
  assert_contains "$out" 'exactly one readable PID' "malformed primary lock refusal missing"
  assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "malformed lock launched a replacement"
  pass "primary clock: malformed or multi-owner primary lock fails closed"
}

test_ambiguous_watcher_lock_prevents_recovery() {
  setup_case watcher-lock
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  mkdir -p "$CASE_HOME/state/.watch.lock"
  printf '%s\n' "$((DEAD_PID + 1))" > "$CASE_HOME/state/.watch.lock/pid"
  local out rc
  out=$(run_tick "$DEAD_PID" dead 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous watcher lock did not block recovery"
  assert_contains "$out" 'watcher singleton is held but its identity/health is ambiguous' "watcher-lock refusal missing"
  assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "ambiguous watcher lock launched a replacement"
  pass "primary clock: an ambiguous watcher singleton prevents replacement"
}

test_launchd_example_has_one_non_boot_repeating_owner() {
  local plist="$ROOT/docs/launchd/com.firstmate.primary-clock.plist.example" contents
  contents=$(<"$plist")
  assert_equals 1 "$(grep -c '<key>Label</key>' "$plist")" "LaunchAgent example must declare one label"
  assert_equals 1 "$(grep -c '<key>StartInterval</key>' "$plist")" "LaunchAgent example must have one interval trigger"
  assert_contains "$contents" '<string>com.firstmate.primary-clock</string>' "clock label missing"
  assert_contains "$contents" '<integer>900</integer>' "15-minute interval missing"
  assert_contains "$contents" '<key>RunAtLoad</key>' "RunAtLoad must be explicit"
  assert_contains "$contents" '<false/>' "LaunchAgent must not run during installation"
  assert_not_contains "$contents" '<key>KeepAlive</key>' "clock must not become a continuously restarted service"
  pass "primary clock: one explicit 900-second LaunchAgent job owns scheduled ticks"
}

test_quiet_reconciliation_does_not_create_a_task_or_queue_record
test_live_busy_leaves_durable_work_for_checkpoint
test_idle_empty_prompt_delivers_existing_wake_once
test_idle_human_input_or_attached_client_is_preserved
test_process_identity_ambiguity_refuses_delivery
test_model_and_home_mismatch_refuse_before_dispatch
test_confirmed_death_recovers_once_with_pinned_settings
test_dead_or_unreadable_process_inventory_never_recovers
test_malformed_primary_lock_never_recovers
test_ambiguous_watcher_lock_prevents_recovery
test_launchd_example_has_one_non_boot_repeating_owner
