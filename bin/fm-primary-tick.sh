#!/usr/bin/env bash
# One opt-in launchd tick for the pinned Codex primary.
# It never creates Firstmate tasks and never replaces a live or ambiguous owner.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}"
FM_HOME="${FM_HOME:-}"
CODEX_HOME="${CODEX_HOME:-}"
FM_PRIMARY_SESSION_UUID="${FM_PRIMARY_SESSION_UUID:-}"
FM_PRIMARY_TMUX_SESSION="${FM_PRIMARY_TMUX_SESSION:-}"
FM_PRIMARY_TMUX_SOCKET="${FM_PRIMARY_TMUX_SOCKET:-}"
FM_PRIMARY_TMUX_BIN="${FM_PRIMARY_TMUX_BIN:-}"
FM_PRIMARY_CODEX_BIN="${FM_PRIMARY_CODEX_BIN:-}"
FM_PRIMARY_MODEL="${FM_PRIMARY_MODEL:-gpt-6-luna}"
FM_PRIMARY_EFFORT="${FM_PRIMARY_EFFORT:-max}"
FM_PRIMARY_RECOVERY_WINDOW="fm-primary-clock-${FM_PRIMARY_SESSION_UUID%%-*}"
FM_PRIMARY_WAKE_TEXT=': Firstmate 15-minute reconciliation: inspect the existing authorized backlog and durable wake queue, determine whether work is eligible, handle it under Firstmate rules, and create no tasks when nothing is eligible. Acknowledge durable wakes only after handling, then return to the Codex foreground checkpoint.'
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: fm-primary-tick.sh [--check]

Run one bounded tick for the explicitly pinned Codex primary. --check reads
identity and endpoint state without queuing, typing, or launching.

Required environment: FM_HOME, FM_ROOT_OVERRIDE, CODEX_HOME,
FM_PRIMARY_SESSION_UUID, FM_PRIMARY_TMUX_SESSION, FM_PRIMARY_TMUX_SOCKET,
FM_PRIMARY_TMUX_BIN, FM_PRIMARY_CODEX_BIN.
The primary is pinned to gpt-6-luna/max, danger-full-access, approval=never.
EOF
}

case "${1:-}" in
  '') ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

say() { printf 'primary-clock: %s\n' "$*"; }
fail() { say "refused: $*"; exit 1; }

[ -n "$FM_HOME" ] || fail "FM_HOME is required"
[ -n "$FM_ROOT_OVERRIDE" ] || fail "FM_ROOT_OVERRIDE is required"
[ -n "$CODEX_HOME" ] || fail "CODEX_HOME is required"
[ -n "$FM_PRIMARY_SESSION_UUID" ] || fail "FM_PRIMARY_SESSION_UUID is required"
[ -n "$FM_PRIMARY_TMUX_SESSION" ] || fail "FM_PRIMARY_TMUX_SESSION is required"
[ -n "$FM_PRIMARY_TMUX_SOCKET" ] || fail "FM_PRIMARY_TMUX_SOCKET is required"
[ -n "$FM_PRIMARY_TMUX_BIN" ] || fail "FM_PRIMARY_TMUX_BIN is required"
[ -n "$FM_PRIMARY_CODEX_BIN" ] || fail "FM_PRIMARY_CODEX_BIN is required"
for pinned_path in "$FM_HOME" "$FM_ROOT_OVERRIDE" "$CODEX_HOME" "$FM_PRIMARY_TMUX_BIN" "$FM_PRIMARY_CODEX_BIN"; do
  case "$pinned_path" in /*) ;; *) fail "pinned paths and executables must be absolute" ;; esac
done
[ "$FM_PRIMARY_MODEL" = gpt-6-luna ] || fail "model must remain gpt-6-luna"
[ "$FM_PRIMARY_EFFORT" = max ] || fail "reasoning effort must remain max"
[[ "$FM_PRIMARY_SESSION_UUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
  || fail "native session identity is not a UUID"
case "$FM_PRIMARY_TMUX_SESSION" in
  ''|*[!A-Za-z0-9._-]*) fail "tmux session name must use only letters, digits, dot, underscore, or hyphen" ;;
esac
case "$FM_PRIMARY_TMUX_SOCKET" in /*) ;; *) fail "tmux socket path must be absolute" ;; esac
[ -d "$FM_HOME/state" ] || fail "pinned Firstmate state directory is absent"
[ -d "$FM_ROOT_OVERRIDE" ] || fail "pinned Firstmate root is absent"
[ -d "$CODEX_HOME" ] || fail "pinned Codex home is absent"
[ -x "$FM_PRIMARY_TMUX_BIN" ] || fail "pinned tmux executable is unavailable"
[ -x "$FM_PRIMARY_CODEX_BIN" ] || fail "pinned Codex executable is unavailable"

FM_ROOT="$FM_ROOT_OVERRIDE"
STATE="$FM_HOME/state"
# shellcheck disable=SC2034 # The sourced wake library reads this selected home state.
FM_STATE_OVERRIDE="$STATE"
FM_WAKE_QUEUE="$STATE/.wake-queue"
FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_is_gate_agent "$FM_ROOT" && fail "no-mistakes gate agents cannot own the primary clock"
{ [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; } \
  || fail "the primary clock is not for secondmate homes"
{ [ ! -e "$FM_ROOT_OVERRIDE/.fm-secondmate-home" ] && [ ! -L "$FM_ROOT_OVERRIDE/.fm-secondmate-home" ]; } \
  || fail "the primary code root carries a secondmate marker"
fm_primary_scope_matches "$FM_HOME" "$STATE" || fail "Firstmate operational home scope did not verify"

fm_primary_common_dir() {  # <git checkout> -> canonical git common directory
  local root=$1 common
  common=$(cd "$root" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$root" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P) || return 1
}

[ -f "$FM_ROOT_OVERRIDE/AGENTS.md" ] && [ -d "$FM_ROOT_OVERRIDE/bin" ] \
  || fail "pinned Firstmate code root is incomplete"
HOME_COMMON=$(fm_primary_common_dir "$FM_HOME") || fail "operational home Git identity is unreadable"
ROOT_COMMON=$(fm_primary_common_dir "$FM_ROOT_OVERRIDE") || fail "pinned code-root Git identity is unreadable"
[ "$HOME_COMMON" = "$ROOT_COMMON" ] || fail "pinned code root is not the operational home's repository"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source tmux || fail "tmux submit helpers could not be loaded"

# Keep every tmux operation on the configured server, including calls inside
# the existing composer and submit helpers.
tmux() { "$FM_PRIMARY_TMUX_BIN" -S "$FM_PRIMARY_TMUX_SOCKET" "$@"; }

fm_primary_has_token() {
  printf '%s\n' "$2" | awk -v token="$1" '
    { for (i = 1; i <= NF; i++) if ($i == token) found = 1 }
    END { exit !found }
  '
}

fm_primary_args_match_pin() {
  local args=$1
  fm_primary_has_token "$FM_PRIMARY_SESSION_UUID" "$args" || return 1
  awk -v args="$args" 'BEGIN { n = split(args, a, /[[:space:]]+/); for (i = 1; i < n; i++) if ((a[i] == "--model" || a[i] == "-m") && a[i + 1] == "gpt-6-luna") ok = 1; exit !ok }' \
    || return 1
  fm_primary_has_token 'model_reasoning_effort=max' "$args" \
    || fm_primary_has_token 'model_reasoning_effort="max"' "$args" \
    || return 1
  awk -v args="$args" 'BEGIN { n = split(args, a, /[[:space:]]+/); for (i = 1; i < n; i++) if ((a[i] == "--sandbox" || a[i] == "-s") && a[i + 1] == "danger-full-access") sandbox = 1; else if ((a[i] == "--ask-for-approval" || a[i] == "-a") && a[i + 1] == "never") approval = 1; exit !(sandbox && approval) }' \
    || return 1
  case " $args " in
    *" --cd $FM_ROOT_OVERRIDE "*|*" -C $FM_ROOT_OVERRIDE "*) ;;
    *) return 1 ;;
  esac
}

fm_primary_pid_row() {  # <pid> -> <tty><TAB><args>
  local pid=$1 row tty args comm
  row=$(ps -p "$pid" -o tty= -o args= 2>/dev/null) || return 1
  row=${row#"${row%%[![:space:]]*}"}
  tty=${row%%[[:space:]]*}
  args=${row#"$tty"}
  args=${args#"${args%%[![:space:]]*}"}
  [ -n "$tty" ] && [ -n "$args" ] || return 1
  case "$tty" in '?'|??) return 1 ;; esac
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  fm_harness_process_matches "$comm" "$args" || return 1
  case "$args" in *codex*) ;; *) return 1 ;; esac
  fm_primary_args_match_pin "$args" || return 1
  printf '%s\t%s\n' "$tty" "$args"
}

fm_primary_uuid_process_rows() {  # print only <pid><TAB>pin|mismatch; never publish argv
  local process_rows row pid rest comm args state
  process_rows=$(LC_ALL=C ps -axo pid=,comm=,args= 2>/dev/null) || return 1
  while IFS= read -r row; do
    row=${row#"${row%%[![:space:]]*}"}
    [ -n "$row" ] || continue
    pid=${row%%[[:space:]]*}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    rest=${row#"$pid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    comm=${rest%%[[:space:]]*}
    args=${rest#"$comm"}
    args=${args#"${args%%[![:space:]]*}"}
    [ -n "$comm" ] && [ -n "$args" ] || continue
    fm_primary_has_token "$FM_PRIMARY_SESSION_UUID" "$args" || continue
    fm_harness_process_matches "$comm" "$args" || continue
    case "$comm $args" in *codex*) ;; *) continue ;; esac
    state=mismatch
    fm_primary_args_match_pin "$args" && state=pin
    printf '%s\t%s\n' "$pid" "$state"
  done <<< "$process_rows"
}

fm_primary_assert_unique_codex_pid() {  # <expected-pid|empty>
  local expected=$1 rows pid state count=0 found_pid='' found_state=''
  rows=$(fm_primary_uuid_process_rows) || return 1
  while IFS=$'\t' read -r pid state; do
    [ -n "$pid" ] || continue
    count=$((count + 1))
    found_pid=$pid
    found_state=$state
  done <<< "$rows"
  if [ -z "$expected" ]; then
    [ "$count" -eq 0 ]
  else
    [ "$count" -eq 1 ] && [ "$found_pid" = "$expected" ] && [ "$found_state" = pin ]
  fi
}

fm_primary_pane_for_tty() {  # <tty without /dev/>
  local tty=$1 panes pane pane_tty found='' count=0
  panes=$(tmux list-panes -a -t "$FM_PRIMARY_TMUX_SESSION" -F '#{pane_id}\t#{pane_tty}' 2>/dev/null) || return 1
  while IFS=$'\t' read -r pane pane_tty; do
    [ -n "$pane" ] || continue
    [ "${pane_tty#/dev/}" = "$tty" ] || continue
    found=$pane
    count=$((count + 1))
  done <<< "$panes"
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

fm_primary_codex_lifecycle_state() {  # print busy|idle|unknown from exact native rollout
  local sessions="$CODEX_HOME/sessions" matches rollout state match_count
  [ -d "$sessions" ] && [ ! -L "$sessions" ] || { printf 'unknown\n'; return 0; }
  matches=$(find "$sessions" -type f -name "rollout-*-$FM_PRIMARY_SESSION_UUID.jsonl" -print 2>/dev/null) \
    || { printf 'unknown\n'; return 0; }
  [ -n "$matches" ] || { printf 'unknown\n'; return 0; }
  match_count=$(printf '%s\n' "$matches" | awk 'END { print NR }')
  [ "$match_count" -eq 1 ] || { printf 'unknown\n'; return 0; }
  rollout=$matches
  [ -f "$rollout" ] && [ ! -L "$rollout" ] && [ -r "$rollout" ] \
    || { printf 'unknown\n'; return 0; }

  state=$(jq -s -r --arg uuid "$FM_PRIMARY_SESSION_UUID" '
    def lifecycle_event:
      .type == "event_msg"
      and (.payload | type == "object")
      and (.payload.type | type == "string")
      and (.payload.type | test("^(task|turn)_"));
    if length == 0 or any(.[]; type != "object") or .[0].type != "session_meta" then
      "unknown"
    else
      [ .[] | select(.type == "session_meta") ] as $meta |
      if ($meta | length) != 1
        or (($meta[0].payload.id == $uuid or $meta[0].payload.session_id == $uuid) | not)
        or ($meta[0].payload.id != null and $meta[0].payload.id != $uuid)
        or ($meta[0].payload.session_id != null and $meta[0].payload.session_id != $uuid) then
        "unknown"
      else
        [ .[] | select(lifecycle_event) ] as $events |
        reduce $events[] as $event (
          {active: [], seen: [], invalid: false};
          ($event.payload.type) as $kind |
          ($event.payload.turn_id // "") as $id |
          if ($id | type) != "string" or $id == "" then
            .invalid = true
          elif $kind == "task_started" or $kind == "turn_started" then
            if (.seen | index($id)) != null then .invalid = true
            else .active += [$id] | .seen += [$id]
            end
          elif $kind == "task_complete" or $kind == "turn_complete"
            or $kind == "task_completed" or $kind == "turn_completed"
            or $kind == "task_aborted" or $kind == "turn_aborted" then
            if (.active | index($id)) == null then .invalid = true
            else .active -= [$id]
            end
          else
            .invalid = true
          end
        ) as $state |
        if $state.invalid or ($state.seen | length) == 0 then "unknown"
        elif ($state.active | length) > 0 then "busy"
        else "idle"
        end
      end
    end
  ' "$rollout" 2>/dev/null) || state=unknown
  case "$state" in busy|idle) printf '%s\n' "$state" ;; *) printf 'unknown\n' ;; esac
}

fm_primary_no_clients() {
  local clients
  clients=$(tmux list-clients -t "$FM_PRIMARY_TMUX_SESSION" -F '#{client_name}' 2>/dev/null) || return 1
  [ -z "$clients" ]
}

fm_primary_pending_wakes() {  # true when any existing durable wake awaits handling
  local kind keys result=1
  if [ -e "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] && [ -r "$FM_WAKE_QUEUE" ] || return 2
  else
    return 1
  fi
  fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 5 || return 2
  if [ -e "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ]; then
    [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] && [ -r "$FM_WAKE_QUEUE" ] \
      && awk -F '\t' 'NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^(signal|stale|check|heartbeat)$/ && $4 != "" { next } { exit 1 }' \
        "$FM_WAKE_QUEUE" 2>/dev/null || {
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          return 2
        }
  fi
  for kind in signal stale check heartbeat; do
    keys=$(fm_wake_queued_keys_locked "$kind") || {
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 2
    }
    if [ -n "$keys" ]; then
      result=0
      break
    fi
  done
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 2
  return "$result"
}

fm_primary_is_descendant() {  # <pid> <ancestor>
  local pid=$1 ancestor=$2 parent
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
    [ "$pid" = "$ancestor" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=$(printf '%s' "$parent" | tr -d '[:space:]')
    case "$parent" in ''|*[!0-9]*|1) return 1 ;; esac
    pid=$parent
  done
  return 1
}

fm_primary_checkpoint_active() {
  local watch_path="$SCRIPT_DIR/fm-watch.sh" grace
  grace=$(fm_poll_derived_grace) || return 1
  fm_watcher_healthy "$STATE" "$watch_path" "$grace" "$FM_HOME" || return 1
  fm_primary_is_descendant "$FM_WATCHER_HEALTHY_PID" "$PRIMARY_PID"
}

fm_primary_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_primary_resume_command() {
  local q_home q_root q_codex_home q_codex q_uuid q_effort
  q_home=$(fm_primary_shell_quote "$FM_HOME") || return 1
  q_root=$(fm_primary_shell_quote "$FM_ROOT_OVERRIDE") || return 1
  q_codex_home=$(fm_primary_shell_quote "$CODEX_HOME") || return 1
  q_codex=$(fm_primary_shell_quote "$FM_PRIMARY_CODEX_BIN") || return 1
  q_uuid=$(fm_primary_shell_quote "$FM_PRIMARY_SESSION_UUID") || return 1
  q_effort=$(fm_primary_shell_quote 'model_reasoning_effort="max"') || return 1
  printf 'exec env FM_HOME=%s FM_ROOT_OVERRIDE=%s CODEX_HOME=%s %s resume %s --model gpt-6-luna -c %s --sandbox danger-full-access --ask-for-approval never --cd %s' \
    "$q_home" "$q_root" "$q_codex_home" "$q_codex" "$q_uuid" "$q_effort" "$q_root"
}

FM_PRIMARY_RECOVERY_PANE=''
FM_PRIMARY_RECOVERY_WINDOW_ID=''
fm_primary_recovery_candidate() {  # 0 none; 1 exactly one dead candidate; 2 ambiguous or live
  local panes row window_id name marker pane dead extra count=0
  FM_PRIMARY_RECOVERY_PANE=''
  FM_PRIMARY_RECOVERY_WINDOW_ID=''
  tmux has-session -t "$FM_PRIMARY_TMUX_SESSION" 2>/dev/null || return 0
  panes=$(tmux list-panes -a -t "$FM_PRIMARY_TMUX_SESSION" \
    -F '#{window_id}\t#{window_name}\t#{?@fm-primary-clock-thread,#{@fm-primary-clock-thread},-}\t#{pane_id}\t#{pane_dead}' \
    2>/dev/null) || return 2
  while IFS=$'\t' read -r window_id name marker pane dead extra; do
    [ -n "$window_id" ] || continue
    [ -z "$extra" ] || return 2
    [[ "$window_id" =~ ^@[0-9]+$ && "$pane" =~ ^%[0-9]+$ ]] || return 2
    case "$dead" in 0|1) ;; *) return 2 ;; esac
    [ "$marker" = "$FM_PRIMARY_SESSION_UUID" ] && {
      count=$((count + 1))
      FM_PRIMARY_RECOVERY_WINDOW_ID=$window_id
      FM_PRIMARY_RECOVERY_PANE=$pane
      [ "$count" -eq 1 ] || return 2
      [ "$dead" = 1 ] || return 2
      continue
    }
    if [ "$name" = "$FM_PRIMARY_RECOVERY_WINDOW" ]; then
      [ "$marker" = '-' ] || return 2
      count=$((count + 1))
      FM_PRIMARY_RECOVERY_WINDOW_ID=$window_id
      FM_PRIMARY_RECOVERY_PANE=$pane
      [ "$count" -eq 1 ] || return 2
      [ "$dead" = 1 ] || return 2
    fi
  done <<< "$panes"
  [ "$count" -eq 0 ] && return 0
  [ "$count" -eq 1 ] || return 2
  return 1
}

fm_primary_pin_recovery_window() {  # <window id>
  local window_id=$1
  tmux set-window-option -t "$window_id" automatic-rename off >/dev/null 2>&1 \
    && tmux set-window-option -t "$window_id" allow-rename off >/dev/null 2>&1 \
    && tmux set-window-option -t "$window_id" @fm-primary-clock-thread "$FM_PRIMARY_SESSION_UUID" \
      >/dev/null 2>&1
}

fm_primary_launch_resume() {
  local command window_id session_exists status candidate_pane candidate_window
  fm_primary_recovery_candidate
  status=$?
  case "$status" in
    1)
      candidate_pane=$FM_PRIMARY_RECOVERY_PANE
      candidate_window=$FM_PRIMARY_RECOVERY_WINDOW_ID
      fm_primary_no_clients || fail "dead recovery pane has an attached client or unreadable client state"
      fm_primary_recovery_candidate
      [ "$?" -eq 1 ] && [ "$FM_PRIMARY_RECOVERY_PANE" = "$candidate_pane" ] \
        && [ "$FM_PRIMARY_RECOVERY_WINDOW_ID" = "$candidate_window" ] \
        || fail "dead recovery pane changed during revalidation"
      fm_primary_no_clients || fail "a tmux client attached before recovery; no pane was respawned"
      command=$(fm_primary_resume_command) || fail "could not construct the pinned resume command"
      command=${command/exec env /exec env FM_BOOTSTRAP_DETECT_ONLY=1 FM_CODEX_WATCH_CHECKPOINT=900 }
      fm_primary_pin_recovery_window "$candidate_window" \
        || fail "dead recovery pane exists but its identity marker could not be pinned"
      tmux respawn-pane -t "$candidate_pane" -c "$FM_ROOT_OVERRIDE" "$command" \
        >/dev/null 2>&1 || fail "the verified dead recovery pane could not be respawned"
      say "same native session resume retried in the verified dead pane; primary lock/start is not yet confirmed"
      return 0
      ;;
    2) fail "recovery pane inventory is live or ambiguous; refusing to overwrite it" ;;
    0) ;;
    *) fail "recovery pane inventory is ambiguous" ;;
  esac
  command=$(fm_primary_resume_command) || fail "could not construct the pinned resume command"
  command=${command/exec env /exec env FM_BOOTSTRAP_DETECT_ONLY=1 FM_CODEX_WATCH_CHECKPOINT=900 }
  session_exists=0
  tmux has-session -t "$FM_PRIMARY_TMUX_SESSION" 2>/dev/null && session_exists=1
  if [ "$session_exists" -eq 1 ]; then
    window_id=$(tmux new-window -dP -F '#{window_id}' -t "$FM_PRIMARY_TMUX_SESSION:" \
      -n "$FM_PRIMARY_RECOVERY_WINDOW" -c "$FM_ROOT_OVERRIDE" "$command" 2>/dev/null) \
      || fail "detached recovery window could not be created"
  else
    window_id=$(tmux new-session -dP -F '#{window_id}' -s "$FM_PRIMARY_TMUX_SESSION" \
      -n "$FM_PRIMARY_RECOVERY_WINDOW" -c "$FM_ROOT_OVERRIDE" "$command" 2>/dev/null) \
      || fail "detached recovery session could not be created"
  fi
  [ -n "$window_id" ] || fail "tmux did not return the recovery window identity"
  fm_primary_pin_recovery_window "$window_id" \
    || fail "recovery window exists but its name/identity could not be pinned"
  say "same native session resume launched in a detached window; primary lock/start is not yet confirmed"
}

LOCK_FILE="$STATE/.lock"
[ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] || fail "the existing primary lock is absent or not a regular file"
PRIMARY_PID=$(awk 'NR == 1 { if ($0 ~ /^[0-9]+$/) pid = $0; else bad = 1; next } { bad = 1 } END { if (NR != 1 || bad || pid == "") exit 1; print pid }' \
  "$LOCK_FILE" 2>/dev/null) || fail "the existing primary lock does not contain exactly one readable PID"
case "$PRIMARY_PID" in ''|0|1|*[!0-9]*) fail "the existing primary lock does not contain one valid PID" ;; esac
if [ -e "$STATE/.afk-contract" ] || [ -L "$STATE/.afk-contract" ] \
  || [ -e "$STATE/.afk" ] || [ -L "$STATE/.afk" ]; then
  fail "away-mode ownership is present; the normal primary clock will not act"
fi

if kill -0 "$PRIMARY_PID" 2>/dev/null; then
  LIVE_ROW=$(fm_primary_pid_row "$PRIMARY_PID") || fail "live lock PID does not prove the pinned Codex UUID/model/policy"
  fm_primary_assert_unique_codex_pid "$PRIMARY_PID" \
    || fail "process table does not prove one exact pinned Codex owner"
  LIVE_TTY=${LIVE_ROW%%$'\t'*}
  PANE=$(fm_primary_pane_for_tty "$LIVE_TTY") || fail "live lock PID is not bound to exactly one pane in the pinned tmux session"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    say "check: pinned primary is live at pane $PANE"
    exit 0
  fi
  fm_primary_pending_wakes
  wake_state=$?
  [ "$wake_state" -ne 2 ] || fail "durable wake queue could not be read safely"
  LIFECYCLE=$(fm_primary_codex_lifecycle_state)
  case "$LIFECYCLE" in
    busy)
      if fm_primary_checkpoint_active; then
        say "live checkpoint: reconciliation stays with the foreground primary; no terminal input sent"
      elif [ "$wake_state" -eq 0 ]; then
        say "live busy: existing durable wakes are left for the next safe checkpoint; no terminal input sent"
      else
        say "live busy: no terminal input sent; the next foreground checkpoint owns reconciliation"
      fi
      exit 0
      ;;
    idle) ;;
    *) fail "Codex native turn lifecycle is unknown; no terminal input sent" ;;
  esac
  COMPOSER=$(fm_tmux_composer_state "$PANE")
  [ "$COMPOSER" = empty ] || {
    say "live idle prompt has composer state '$COMPOSER'; preserving user input and leaving the durable wake pending"
    exit 0
  }
  fm_primary_no_clients || {
    say "live idle prompt has an attached tmux client or unreadable client state; leaving the durable wake pending"
    exit 0
  }
  # Revalidate the identity and both human-input guards immediately before the
  # shared one-type/Enter-only-retry helper. The helper verifies composer state.
  LIVE_ROW=$(fm_primary_pid_row "$PRIMARY_PID") || fail "primary identity changed before submit"
  fm_primary_assert_unique_codex_pid "$PRIMARY_PID" || fail "primary process ownership changed before submit"
  [ "${LIVE_ROW%%$'\t'*}" = "$LIVE_TTY" ] || fail "primary terminal changed before submit"
  [ "$(fm_primary_pane_for_tty "$LIVE_TTY")" = "$PANE" ] || fail "primary pane changed before submit"
  fm_primary_no_clients || fail "a tmux client attached before submit; no input was sent"
  [ "$(fm_primary_codex_lifecycle_state)" = idle ] || fail "Codex native turn lifecycle stopped proving idle before submit"
  [ "$(fm_tmux_composer_state "$PANE")" = empty ] || fail "composer stopped being positively empty before submit"
  verdict=$(fm_backend_send_text_submit tmux "$PANE" "$FM_PRIMARY_WAKE_TEXT" 3 1 1 2>/dev/null) \
    || fail "verified submit helper failed"
  [ "$verdict" = empty ] || {
    say "idle reconciliation submit not confirmed (submit verdict=$verdict); user input is not resent"
    exit 1
  }
  for _ in 1 2 3 4 5; do
    [ "$(fm_primary_pid_row "$PRIMARY_PID" 2>/dev/null || true)" != "" ] \
      || fail "primary identity became ambiguous after submit"
    fm_primary_assert_unique_codex_pid "$PRIMARY_PID" \
      || fail "native Codex ownership became ambiguous after submit"
    [ "$(fm_primary_codex_lifecycle_state)" = busy ] && {
      say "idle wake confirmed by a new native Codex turn-start event"
      exit 0
    }
    sleep 1
  done
  say "submit cleared the composer but no native turn-start event was observed; text will not be resent"
  exit 1
fi

# A dead PID licenses recovery only when ps independently confirms absence and
# a process-wide scan finds no process holding the exact native UUID.
DEAD_ROW=$(ps -p "$PRIMARY_PID" -o pid= 2>/dev/null) \
  || fail "process table could not independently confirm the primary PID absent"
[ -z "$DEAD_ROW" ] || fail "kill/ps observations disagree about the primary PID"
fm_primary_assert_unique_codex_pid '' \
  || fail "the native UUID is still present or the process table is ambiguous; recovery would overlap"
if [ -L "$STATE/.watch.lock" ] && [ ! -e "$STATE/.watch.lock" ]; then
  fail "watcher singleton link is broken; lock ownership is ambiguous"
fi
if [ -e "$STATE/.watch.lock" ] && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" \
  "$(fm_poll_derived_grace)" "$FM_HOME" && ! fm_watcher_lock_unheld "$STATE"; then
  fail "watcher singleton is held but its identity/health is ambiguous"
fi
if [ "$CHECK_ONLY" -eq 1 ]; then
  say "check: confirmed-dead primary is eligible for same-session recovery"
  exit 0
fi
fm_primary_launch_resume
