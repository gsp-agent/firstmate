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
  CASE_ROLLOUT="$CASE_HOME/.codex/sessions/2026/09/23/rollout-2026-09-23T000000Z-$SESSION_UUID.jsonl"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/config" "$CASE_HOME/.codex" \
    "$(dirname "$CASE_ROLLOUT")" "$CASE_HOME/bin" "$CASE_FAKEBIN"
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
    case "$*" in
      *window_id*)
        if [ -f "$FM_FAKE_RECOVERY_FILE" ]; then
          case "$(<"$FM_FAKE_RECOVERY_FILE")" in
            marked-dead)
              printf '@8\trenamed-recovery\t%s\t%%9\t1\n' "$FM_PRIMARY_SESSION_UUID"
              ;;
            named-dead)
              printf '@8\tfm-primary-clock-11111111\t-\t%%9\t1\n'
              ;;
            marked-live)
              printf '@8\trenamed-recovery\t%s\t%%9\t0\n' "$FM_PRIMARY_SESSION_UUID"
              ;;
            new-window|respawned)
              printf '@99\tfm-primary-clock-11111111\t%s\t%%99\t0\n' "$FM_PRIMARY_SESSION_UUID"
              ;;
            *) exit 2 ;;
          esac
        fi
        ;;
      *)
        if [ "${FM_FAKE_DUPLICATE_PANES:-}" = 1 ]; then
          printf '%%3\t/dev/ttys009\n%%4\t/dev/ttys009\n'
        else
          printf '%%3\t/dev/ttys009\n'
        fi
        ;;
    esac
    ;;
  list-clients)
    [ "${FM_FAKE_CLIENTS:-}" != error ] || exit 1
    if [ -n "${FM_FAKE_START_ON_CLIENTS_FILE:-}" ] && [ ! -e "$FM_FAKE_START_ON_CLIENTS_FILE" ]; then
      printf '{"timestamp":"2026-01-01T00:00:03Z","type":"event_msg","payload":{"type":"task_started","turn_id":"raced-turn"}}\n' \
        >> "$FM_FAKE_ROLLOUT_FILE"
      : > "$FM_FAKE_START_ON_CLIENTS_FILE"
    fi
    [ "${FM_FAKE_CLIENTS:-}" != 1 ] || printf 'client-1\n'
    ;;
  capture-pane)
    if [ "${1:-}" = -e ]; then
      case "$(cat "$FM_FAKE_COMPOSER_FILE")" in
        pending|typed) printf '╭────────────╮\n│ › wake      │\n╰────────────╯\n' ;;
        empty) printf '› \033[2mAsk Codex to do anything\033[0m\n' ;;
        *) printf 'unknown pane rendering\n' ;;
      esac
    elif [ "$(cat "$FM_FAKE_BUSY_FILE")" = busy ]; then
      printf 'Working (52m 55s • esc to interrupt)\n› Ask Codex to do anything\n'
    elif [ "$(cat "$FM_FAKE_BUSY_FILE")" = unmatched ]; then
      printf 'Working (52m 55s)\n› Ask Codex to do anything\n'
    else
      printf 'Codex\n? for shortcuts\n'
    fi
    ;;
  display-message)
    case "$*" in
      *cursor_y*)
        if [ "$(cat "$FM_FAKE_COMPOSER_FILE")" = empty ]; then printf '0\n'; else printf '1\n'; fi
        ;;
      *pane_id*) printf '%%3\n' ;;
      *) exit 1 ;;
    esac
    ;;
  has-session)
    [ "${FM_FAKE_SESSION_EXISTS:-1}" = 1 ]
    ;;
  list-windows)
    if [ -f "$FM_FAKE_RECOVERY_FILE" ]; then printf 'fm-primary-clock-11111111\t%s\n' "$FM_PRIMARY_SESSION_UUID"; fi
    ;;
  send-keys)
    case "$*" in
      *' -l '*) printf 'typed\n' > "$FM_FAKE_COMPOSER_FILE" ;;
      *' Enter'*)
        if [ "${FM_FAKE_SUBMIT_MODE:-clear}" = clear ]; then
          printf 'empty\n' > "$FM_FAKE_COMPOSER_FILE"
          printf 'busy\n' > "$FM_FAKE_BUSY_FILE"
          printf '{"timestamp":"2026-01-01T00:00:04Z","type":"event_msg","payload":{"type":"task_started","turn_id":"submitted-turn"}}\n' \
            >> "$FM_FAKE_ROLLOUT_FILE"
        fi
        ;;
    esac
    ;;
  new-window|new-session)
    printf 'new-window\n' > "$FM_FAKE_RECOVERY_FILE"
    printf '@99\n'
    ;;
  respawn-pane)
    printf 'respawned\n' > "$FM_FAKE_RECOVERY_FILE"
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
  *' -o lstart= '*)
    [ "${FM_FAKE_PS_START_MODE:-normal}" != error ] || exit 1
    printf '%s\n' "${FM_FAKE_OWNER_START:-Thu Jan  1 00:00:00 2026}"
    ;;
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
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"baseline-turn"}}\n' \
    >> "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"baseline-turn"}}\n' \
    >> "$CASE_ROLLOUT"
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
    FM_FAKE_OWNER_START="${FM_FAKE_OWNER_START:-Thu Jan  1 00:00:00 2026}" \
    FM_FAKE_PS_START_MODE="${FM_FAKE_PS_START_MODE:-normal}" \
    FM_FAKE_PS_MODE="$mode" \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    FM_FAKE_COMPOSER_FILE="$CASE_BASE/composer" \
    FM_FAKE_BUSY_FILE="$CASE_BASE/busy" \
    FM_FAKE_RECOVERY_FILE="$CASE_RECOVERY" \
    FM_FAKE_ROLLOUT_FILE="$CASE_ROLLOUT" \
    FM_FAKE_START_ON_CLIENTS_FILE="${FM_FAKE_START_ON_CLIENTS:+$CASE_BASE/start-on-clients}" \
    "$TICK" "$@"
}

seed_busy_rollout() {
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"working-turn"}}\n' \
    >> "$CASE_ROLLOUT"
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
  seed_busy_rollout
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

test_native_lifecycle_overrides_unmatched_render_and_rechecks_before_submit() {
  setup_case unmatched-render
  prepare_live
  seed_wake
  seed_busy_rollout
  printf 'unmatched\n' > "$CASE_BASE/busy"
  local out rc render composer legacy_busy
  render=$(env \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    FM_FAKE_COMPOSER_FILE="$CASE_BASE/composer" \
    FM_FAKE_BUSY_FILE="$CASE_BASE/busy" \
    FM_FAKE_RECOVERY_FILE="$CASE_RECOVERY" \
    "$CASE_FAKEBIN/tmux" -S "$CASE_BASE/tmux.sock" capture-pane -p -t %3 -S -40) \
    || fail "could not read the deliberately misleading rendered fixture"
  composer=$(env \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    FM_FAKE_COMPOSER_FILE="$CASE_BASE/composer" \
    FM_FAKE_BUSY_FILE="$CASE_BASE/busy" \
    FM_FAKE_RECOVERY_FILE="$CASE_RECOVERY" \
    "$CASE_FAKEBIN/tmux" -S "$CASE_BASE/tmux.sock" capture-pane -e -p -t %3 -S 0 -E -) \
    || fail "could not read the idle-looking composer fixture"
  assert_contains "$render" 'Working (52m 55s)' "fixture lacks its unmatched nonempty busy-looking render"
  assert_contains "$render" '› Ask Codex to do anything' "fixture lacks its idle-looking bare composer"
  assert_contains "$composer" 'Ask Codex to do anything' "fixture lacks the styled idle placeholder"
  # shellcheck disable=SC2016 # Positional parameters expand inside the nested Bash probe.
  legacy_busy=$(env \
    FM_FAKE_TMUX_LOG="$CASE_BASE/tmux.log" \
    FM_FAKE_COMPOSER_FILE="$CASE_BASE/composer" \
    FM_FAKE_BUSY_FILE="$CASE_BASE/busy" \
    FM_FAKE_RECOVERY_FILE="$CASE_RECOVERY" \
    bash -c '
      . "$1/bin/fm-tmux-lib.sh"
      fake_tmux=$2
      fake_socket=$3
      tmux() { "$fake_tmux" -S "$fake_socket" "$@"; }
      fm_pane_busy_state %3 codex
    ' _ "$ROOT" "$CASE_FAKEBIN/tmux" "$CASE_BASE/tmux.sock") \
    || fail "could not evaluate the prior rendered busy fallback"
  assert_equals idle "$legacy_busy" "fixture must reproduce the false-idle renderer result"

  out=$(run_tick "$$" live) || fail "unmatched lifecycle should defer safely: $out"
  assert_contains "$out" 'live busy:' "an unmatched native task_started event was not treated as busy"
  assert_equals 0 "$(grep -c '^send-keys ' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "false-idle render caused terminal input during an unmatched native turn"

  setup_case lifecycle-race
  prepare_live
  seed_wake
  out=$(FM_FAKE_START_ON_CLIENTS=1 run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a turn started during the human-input guard but was still submitted"
  assert_contains "$out" 'lifecycle stopped proving idle before submit' "fresh pre-submit lifecycle check did not refuse"
  assert_equals 0 "$(count_types)" "turn-start race received terminal input"
  pass "primary clock: native turn lifecycle wins over render text and is rechecked before input"
}

test_idle_empty_prompt_delivers_existing_wake_once() {
  setup_case idle
  prepare_live
  seed_wake
  local out
  out=$(run_tick "$$" live) || fail "safe idle wake failed: $out"
  assert_contains "$out" 'idle wake confirmed' "idle delivery must be confirmed by a new native turn-start event"
  assert_equals 1 "$(count_types)" "idle delivery must type the wake exactly once"
  pass "primary clock: safe idle delivery types once and confirms a native turn-start event"
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
  assert_contains "$command_line" 'Firstmate 15-minute reconciliation: inspect the existing authorized backlog' \
    "confirmed-dead recovery omitted its native reconciliation prompt"

  out=$(run_tick "$DEAD_PID" dead 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a live recovery pane without the pinned process was accepted as success"
  assert_contains "$out" 'live or ambiguous' "live recovery candidate did not fail closed"
  assert_equals 1 "$(grep -c '^new-window ' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "repeat tick dispatched a second recovery owner"
  pass "primary clock: new recovery launch does not duplicate or trust an unverified live pane"
}

test_dead_marked_or_named_recovery_pane_is_retried_and_reacquired_once() {
  local kind out
  for kind in marked named; do
    setup_case "recovery-$kind"
    printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
    if [ "$kind" = marked ]; then
      printf 'marked-dead\n' > "$CASE_RECOVERY"
    else
      printf 'named-dead\n' > "$CASE_RECOVERY"
    fi
    out=$(run_tick "$DEAD_PID" dead) || fail "$kind dead pane was not retried: $out"
    assert_contains "$out" 'retried in the verified dead pane' "$kind stale pane did not receive bounded retry"
    assert_contains "$(<"$CASE_BASE/tmux.log")" 'respawn-pane -t %9 -c ' "$kind pane ID was not reused"
    assert_not_contains "$(<"$CASE_BASE/tmux.log")" 'respawn-pane -k' "recovery killed a pane instead of respawning a dead one"
    assert_equals 0 "$(grep -c '^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
      "$kind stale window created a second pane"

    seed_busy_rollout
    printf '%s\n' "$$" > "$CASE_HOME/state/.lock"
    out=$(run_tick "$$" live) || fail "$kind retry did not recognize the reacquired exact primary: $out"
    assert_contains "$out" 'live busy:' "$kind retry was not owned by the reacquired primary"
    assert_equals 1 "$(grep -c '^respawn-pane ' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
      "$kind dead pane was respawned more than once after lock reacquisition"
    assert_equals 0 "$(count_types)" "$kind recovery duplicate received terminal input"
  done
  pass "primary clock: exact marked and named dead panes retry once and stop after lock reacquisition"
}

test_live_recovery_candidate_is_preserved_and_refused() {
  setup_case live-recovery-candidate
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  printf 'marked-live\n' > "$CASE_RECOVERY"
  local out rc
  out=$(run_tick "$DEAD_PID" dead 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a live stale recovery pane was overwritten"
  assert_contains "$out" 'live or ambiguous' "live stale pane refusal missing"
  assert_equals 0 "$(grep -c '^respawn-pane\|^new-window\|^new-session' "$CASE_BASE/tmux.log" 2>/dev/null || true)" \
    "live recovery candidate was modified or duplicated"
  pass "primary clock: live stale candidate is preserved without overwrite or duplicate launch"
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

test_bare_resume_keeps_pre_owner_unmatched_turn_busy() {
  setup_case bare-resume-orphan
  prepare_live
  seed_wake
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"2025-12-31T23:59:59Z","type":"event_msg","payload":{"type":"task_started","turn_id":"abandoned-before-resume"}}\n' \
    >> "$CASE_ROLLOUT"
  local out
  out=$(run_tick "$$" live) || fail "bare resume should remain conservatively busy: $out"
  assert_contains "$out" 'live busy:' "bare resume treated an unmatched prior task as idle"
  assert_equals 0 "$(count_types)" "bare resume sent while the prior native task remained unmatched"
  pass "primary clock: bare resume keeps an unmatched prior task busy until a later native task transition"
}

test_recovery_native_task_order_resolves_orphan_without_wallclock() {
  setup_case recovery-native-order
  seed_wake
  printf '%s\n' "$DEAD_PID" > "$CASE_HOME/state/.lock"
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:03Z","type":"event_msg","payload":{"type":"task_started","turn_id":"orphan-A"}}\n' \
    >> "$CASE_ROLLOUT"
  local out command_line
  out=$(run_tick "$DEAD_PID" dead) || fail "confirmed-dead recovery did not launch: $out"
  command_line=$(grep '^new-window ' "$CASE_BASE/tmux.log")
  assert_contains "$command_line" 'Firstmate 15-minute reconciliation: inspect the existing authorized backlog' \
    "recovery launch did not send the normal reconciliation prompt"

  # The recovery prompt's native start is later in JSONL order, although its
  # wall-clock timestamp moved behind the replacement owner's process start.
  printf '{"timestamp":"2026-01-01T00:00:04Z","type":"event_msg","payload":{"type":"task_started","turn_id":"replacement-B"}}\n' \
    >> "$CASE_ROLLOUT"
  printf '%s\n' "$$" > "$CASE_HOME/state/.lock"
  out=$(FM_FAKE_OWNER_START='Thu Jan  1 00:00:05 2026' run_tick "$$" live) \
    || fail "live replacement-B task was not preserved under clock rollback: $out"
  assert_contains "$out" 'live busy:' "a live task started after the recovery prompt was classified idle"
  assert_equals 0 "$(count_types)" "live replacement-B task received terminal input"

  # Native record order, not timestamp order, closes only B. A remains an
  # unmatched historical start and is never rewritten as completed.
  printf '{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"replacement-B"}}\n' \
    >> "$CASE_ROLLOUT"
  out=$(FM_FAKE_OWNER_START='Thu Jan  1 00:00:05 2026' run_tick "$$" live) \
    || fail "matching replacement-B completion did not establish current idle: $out"
  assert_contains "$out" 'idle wake confirmed' "completed replacement-B did not permit the normal reconciliation send"
  assert_equals 1 "$(count_types)" "completed replacement-B did not send exactly one reconciliation prompt"
  pass "primary clock: confirmed recovery prompt, ordered native B start/completion, and rollback timestamps preserve the send boundary"
}

test_nonmatching_terminal_does_not_clear_newer_task() {
  setup_case mismatched-terminal
  prepare_live
  seed_wake
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"orphan-A"}}\n' \
    >> "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"task_started","turn_id":"live-B"}}\n' \
    >> "$CASE_ROLLOUT"
  printf '{"timestamp":"2026-01-01T00:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"orphan-A"}}\n' \
    >> "$CASE_ROLLOUT"
  local out rc
  out=$(run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a terminal for superseded A cleared the current B task"
  assert_contains "$out" 'native turn lifecycle is unknown' "nonmatching terminal did not fail closed"
  assert_equals 0 "$(count_types)" "nonmatching terminal allowed terminal input"
  pass "primary clock: only the active task's matching terminal can establish idle"
}

test_malformed_event_timestamp_refuses_delivery() {
  setup_case malformed-event-time
  prepare_live
  seed_wake
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","session_id":"%s"}}\n' \
    "$SESSION_UUID" "$SESSION_UUID" > "$CASE_ROLLOUT"
  printf '{"timestamp":"not-a-timestamp","type":"event_msg","payload":{"type":"task_started","turn_id":"malformed-time"}}\n' \
    >> "$CASE_ROLLOUT"
  out=$(run_tick "$$" live 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a lifecycle event without a readable timestamp was accepted"
  assert_contains "$out" 'native turn lifecycle is unknown' "malformed event time did not make lifecycle evidence unknown"
  assert_equals 0 "$(count_types)" "clock submitted with a malformed lifecycle timestamp"
  pass "primary clock: unreadable owner or event time prevents automatic input"
}

test_quiet_reconciliation_does_not_create_a_task_or_queue_record
test_live_busy_leaves_durable_work_for_checkpoint
test_idle_empty_prompt_delivers_existing_wake_once
test_native_lifecycle_overrides_unmatched_render_and_rechecks_before_submit
test_idle_human_input_or_attached_client_is_preserved
test_process_identity_ambiguity_refuses_delivery
test_model_and_home_mismatch_refuse_before_dispatch
test_confirmed_death_recovers_once_with_pinned_settings
test_dead_marked_or_named_recovery_pane_is_retried_and_reacquired_once
test_live_recovery_candidate_is_preserved_and_refused
test_dead_or_unreadable_process_inventory_never_recovers
test_malformed_primary_lock_never_recovers
test_ambiguous_watcher_lock_prevents_recovery
test_bare_resume_keeps_pre_owner_unmatched_turn_busy
test_recovery_native_task_order_resolves_orphan_without_wallclock
test_nonmatching_terminal_does_not_clear_newer_task
test_malformed_event_timestamp_refuses_delivery
test_launchd_example_has_one_non_boot_repeating_owner
