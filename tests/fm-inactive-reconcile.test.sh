#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
fm_git_identity fmtest fmtest@example.invalid
FM_REAL_MKTEMP=$(command -v mktemp)
export FM_REAL_MKTEMP

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ "${FM_NATIVE_RACE_ACTOR:-}" != reconcile ] || : > "$FM_HERDR_WORLD/state-read"
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
  kill-window) exit 0 ;;
esac
SH
  cat > "$fake/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_HERDR_WORLD:?}/herdr.log"
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"client":{"version":"0.8.0","protocol":14},"server":{"running":true}}\n' ;;
  'session list')
    if [ "${FM_NATIVE_RACE_ACTOR:-}" = reconcile ]; then
      : > "$FM_HERDR_WORLD/close-waiting"
      race_deadline=$((SECONDS + 20))
      while [ ! -e "$FM_HERDR_WORLD/close-release" ]; do
        [ -d "$FM_HERDR_WORLD" ] && [ "$SECONDS" -lt "$race_deadline" ] || exit 1
        sleep 0.02
      done
    fi
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$FM_HERDR_WORLD" ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
  'pane get')
    [ "${FM_FAKE_HERDR_UNREACHABLE:-0}" = 1 ] && exit 1
    if [ -e "$FM_HERDR_WORLD/herdr-closed" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1","workspace_id":"w1"}}}\n' "$3" ;;
  'pane read')
    [ "${FM_FAKE_HERDR_UNREACHABLE:-0}" = 1 ] && exit 1
    [ ! -e "$FM_HERDR_WORLD/herdr-closed" ] || exit 1
    printf 'all quiet\n> \n' ;;
  'pane close')
    [ ! -e "$FM_HERDR_WORLD/native-started" ] || : > "$FM_HERDR_WORLD/closed-running"
    if [ "${FM_HOLD_RACE_ORDER:-}" = close-first ]; then
      control_owner=$(cat "$FM_STATE_OVERRIDE/.control-child.lock/pid" 2>/dev/null || true)
      meta_owner=$(cat "$FM_STATE_OVERRIDE/.meta-child.lock/pid" 2>/dev/null || true)
      if [ -z "$control_owner" ] || [ "$control_owner" != "$meta_owner" ]; then
        : > "$FM_HERDR_WORLD/close-without-control"
      fi
      [ ! -e "$FM_HERDR_WORLD/hold-finished" ] || : > "$FM_HERDR_WORLD/closed-held"
    fi
    for record in "$FM_STATE_OVERRIDE/terminal-outcomes"/*; do
      [ -f "$record" ] || continue
      if grep -Fxq "pane_close_target=default:$3" "$record"; then
        : > "$FM_HERDR_WORLD/outcome-before-close"
      fi
    done
    [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 0 ] || exit 1
    : > "$FM_HERDR_WORLD/herdr-closed" ;;
  'pane send-text')
    [ ! -e "$FM_HERDR_WORLD/herdr-closed" ] || exit 1
    printf '%s\n' "$4" > "$FM_HERDR_WORLD/native-text"
    : > "$FM_HERDR_WORLD/native-typed"
    if [ "${FM_NATIVE_RACE_ORDER:-}" = submit-first ]; then
      race_deadline=$((SECONDS + 20))
      while [ ! -e "$FM_HERDR_WORLD/send-release" ]; do
        [ -d "$FM_HERDR_WORLD" ] && [ "$SECONDS" -lt "$race_deadline" ] || exit 1
        sleep 0.02
      done
    fi ;;
  'pane send-keys')
    [ "$4" = enter ] || exit 0
    [ ! -e "$FM_HERDR_WORLD/herdr-closed" ] || exit 1
    "$FM_NATIVE_BUSY_EVENT_BIN" apply "$FM_STATE_OVERRIDE" child busy --current-gen --source claude-hook --event user-prompt-submit || exit 1
    : > "$FM_HERDR_WORLD/native-started" ;;
  'agent get')
    if [ -e "$FM_HERDR_WORLD/native-started" ]; then agent_status=working; else agent_status=idle; fi
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$agent_status" ;;
  *) exit 1 ;;
esac
SH
  cat > "$fake/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake/mktemp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "${FM_HOLD_RACE_ACTOR:-}:$arg" in
    hold:*/.control-child.lock.owner.*) : > "$FM_HERDR_WORLD/hold-lock-attempt" ;;
    reconcile:*/.meta-child.lock.owner.*)
      if [ "${FM_HOLD_RACE_CHECK_ORDER:-0}" = 1 ] && [ ! -e "$FM_STATE_OVERRIDE/.control-child.lock/pid" ]; then
        : > "$FM_HERDR_WORLD/meta-before-control"
      fi ;;
  esac
done
case "${FM_NATIVE_RACE_ACTOR:-}:${1:-}" in
  send:*/.lock-probe.*) : > "$FM_HERDR_WORLD/native-lock-attempt" ;;
  reconcile:*/.inactive-outcome-reconcile.*) : > "$FM_HERDR_WORLD/reconcile-started" ;;
esac
case "${FM_FAKE_FAIL_RECORD_WRITE:-}:${1:-}" in
  pending:*/terminal-outcomes/.pending.*|record:*/terminal-outcomes/.record.*) exit 1 ;;
esac
exec "${FM_REAL_MKTEMP:?}" "$@"
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  for tool in zellij orca cmux; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_HERDR_WORLD:?}/other-backends.log"
SH
  done
  chmod +x "$fake"/*
}

set_child_field() {
  local meta=$1 key=$2 value=$3
  awk -v key="$key" 'index($0, key "=") != 1' "$meta" > "$meta.tmp"
  printf '%s=%s\n' "$key" "$value" >> "$meta.tmp"
  mv "$meta.tmp" "$meta"
}

write_herdr_child() {
  local home=$1 id=$2 status=$3
  write_child "$home" "$id" "$status"
  set_child_field "$home/state/$id.meta" window default:w1:p1
  set_child_field "$home/state/$id.meta" harness claude
  printf '%s\n' 'backend=herdr' "endpoint_task_id=$id" 'herdr_session=default' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' >> "$home/state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" --state idle --source claude-hook --event stop >/dev/null
  age "$home/state/$id.meta"
}

read_child_state() {
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_HERDR_WORLD="$WORLD" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$2"
}

herdr_close_count() {
  if [ -f "$WORLD/herdr.log" ]; then
    grep -c '^pane close ' "$WORLD/herdr.log" || true
  else
    printf '0\n'
  fi
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  fm_test_tasks_toml "$MAIN/.tasks.toml"
  fm_test_tasks_toml "$MATE/.tasks.toml"
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$route" = local ]; then
    cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  else
    cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  fi
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM} sha
  mkdir -p "$home/projects/$id"
  git -C "$home/projects/$id" init -q
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=$home/projects/$id" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1' \
    "pr_head=$sha"
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

write_mate_meta() {
  fm_write_secondmate_meta "$MAIN/state/mate.meta" "$MATE"
  printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
  age "$MAIN/state/mate.meta" "$MAIN/state/mate.status"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_TMUX_LOG="$WORLD/tmux.log" FM_FORGE_LOG="$WORLD/forge.log" FM_HERDR_WORLD="$WORLD" "$RECON" scan ${option:+"$option"}
}

run_native_submit() {
  local task_home=$1 selector=$2 order=$3
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$task_home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" FM_CONFIG_OVERRIDE="$task_home/config" \
    FM_HERDR_WORLD="$WORLD" FM_NATIVE_RACE_ACTOR=send FM_NATIVE_RACE_ORDER="$order" \
    FM_NATIVE_BUSY_EVENT_BIN="$ROOT/bin/fm-busy-event.sh" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.01 FM_SEND_RETRIES=1 \
    "$SEND" "$selector" /no-mistakes
}

wait_native_race_event() {
  local first=$1 second=${2:-$1} deadline=$((SECONDS + 15))
  while [ ! -e "$first" ] && [ ! -e "$second" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.02
  done
}

tmux_kill_count() { # <world>
  if [ -f "$1/tmux.log" ]; then
    grep -c '^kill-window ' "$1/tmux.log" || true
  else
    printf '0\n'
  fi
}

# The teardown-side entry point: deliver one child's terminal ledger line for a
# caller holding its meta lock.
run_report() { # <home> <child>
  local home=$1 child=$2
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" report "$child"
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

reported_outcome_key() { # <home> <id> <state>
  local home=$1 id=$2 state=$3 record key
  for record in "$home/state/terminal-outcomes"/*.reported; do
    [ -f "$record" ] || continue
    grep -Fxq "task_id=$id" "$record" || continue
    grep -Fxq "state=$state" "$record" || continue
    key=$(sed -n 's/^outcome_key=//p' "$record")
    case "$key" in
      "child-outcome-$id-$state-"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s\n' "$key"; return 0 ;;
    esac
  done
  return 1
}

prime_seen() { # <state> <status>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

test_context_paused_herdr_pane_closes_without_outcome() {
  local kind note phase index=0 out
  for kind in ship scout; do
    for note in \
      "session reached Dale's 300K context line; work in progress committed" \
      'context passed 300k tokens; stowed' \
      'session context limit reached; fix committed' \
      'session context limit, a fresh session resumes' \
      'context limit reached mid-diagnosis, fresh session needed' \
      'session reached the 300K context line; work committed, a fresh session resumes' \
      'reached the context limit; a fresh session resumes' \
      'passed the context limit; a fresh session resumes' \
      'passed the 300K context line; a fresh session resumes' \
      'session context limit reached' \
      'context limit reached with a fresh session needed' \
      'context limit reached; awaiting a fresh session to resume' \
      'context limit reached; awaiting a fresh session to continue' \
      'context limit reached; awaiting a fresh session and then continue' \
      'context limit reached; awaiting a fresh session and then restart; waiting for a replacement session to take over' \
      'context limit reached; waiting for a new session to resume and for a replacement session to take over' \
      'context limit reached; awaiting a new session to restart' \
      'context limit reached; waiting for a replacement session to take over' \
      'context limit reached; until a new session takes over' \
      'context limit reached; awaiting a fresh session to carry on' \
      'context limit reached; awaiting a fresh session to continue and then resume' \
      'context limit reached; waiting for a replacement session to resume' \
      'context limit reached; until a fresh session resumes' \
      'context limit reached; waiting until a fresh session resumes; work committed' \
      'SESSION REACHED THE 300 K CONTEXT LINE; a fresh session resumes'; do
      index=$((index + 1))
      make_world "context-paused-close-$kind-$index"
      write_herdr_child "$MAIN" child "paused: $note"
      set_child_field "$MAIN/state/child.meta" kind "$kind"
      age "$MAIN/state/child.meta"
      run_reconcile "$MAIN" --startup
      [ "$(herdr_close_count)" = 1 ] || fail "$kind context-paused herdr pane was not closed: $note"
      for phase in pending reported presented; do
        [ "$(outcome_count "$MAIN" "$phase")" = 0 ] || fail "context pause produced a $phase terminal outcome"
      done
      [ ! -s "$MAIN/state/.wake-queue" ] || fail "context pause woke the supervisor"
      [ -f "$MAIN/state/child.meta" ] && [ -f "$MAIN/state/child.status" ] \
        && [ -d "$MAIN/projects/child" ] || fail "context-paused child records or worktree were removed"
      out=$(read_child_state "$MAIN" child)
      assert_contains "$out" 'state: paused' "closed $kind context-paused child lost its current state"
      assert_contains "$out" "$note" "closed $kind context-paused child lost its reason"
    done
  done
  pass "context-paused ship and scout panes close without outcomes or wakes and retain paused current state"
}

test_event_paused_herdr_pane_stays_open() {
  local note state index=0
  for note in \
    'waiting for the PM call on the context question, until 2026-10-22T15:00Z' \
    'waiting for the PM call on the context limit question, until 2026-10-22T15:00Z' \
    'awaiting a decision about the 300K context line' \
    'context limit reached; awaiting the PM call' \
    'context limit reached; awaiting Firstmate' \
    'context limit reached; waiting for Dale' \
    'context limit reached; waiting for a call' \
    'context limit reached; waiting for a review' \
    'context limit reached; awaiting approval' \
    'context limit reached; until 2026-10-22T15:00Z' \
    'context limit reached; awaiting a fresh session to continue until tomorrow' \
    'context limit reached; awaiting a new session to restart while waiting for the PM call' \
    'context limit reached; awaiting a fresh session to resume; waiting for the PM call' \
    'context limit reached; awaiting a fresh session and PM approval' \
    'context limit reached; waiting for a replacement session to take over and for PM approval' \
    'context limit reached; waiting for a replacement session to take over and PM approval' \
    'context limit reached; awaiting a fresh session to continue or release notes' \
    'context limit reached; awaiting a fresh session to review the work and continue' \
    'context limit reached; awaiting a fresh session, then pick up the remaining commits' \
    'context limit reached; waiting for a fresh session to resume or for a review' \
    'context limit reached; waiting on a fresh session to continue and on Dale' \
    'context limit reached; awaiting a new session and then continue; awaiting Firstmate' \
    'context limit reached; awaiting a fresh session to resume. Waiting for the PM call' \
    'context limit reached; awaiting a fresh session and then continue until 2026-10-22T15:00Z' \
    'session reached the context limit; waiting for the PM call, until 2026-10-22T15:00Z'; do
    for state in unknown done failed; do
      index=$((index + 1))
      make_world "event-paused-keep-$index"
      write_herdr_child "$MAIN" child "paused: $note"
      FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
      [ "$(herdr_close_count)" = 0 ] || fail "event-paused herdr pane was closed with $state state: $note"
      [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "event pause produced a terminal outcome"
    done
  done
  pass "a pause for any other reason never closes"
}

test_pause_during_state_read_supersedes_terminal_closure() {
  local route state pause_kind task_home note expected_closes
  for route in main ledger; do
    for state in done failed; do
      for pause_kind in context event; do
        make_world "pause-during-state-read-$route-$state-$pause_kind"
        task_home="$MAIN"
        if [ "$route" = ledger ]; then
          bind_secondmate local
          task_home="$MATE"
        fi
        write_herdr_child "$task_home" child 'working: finishing the turn'
        note='context limit reached; awaiting a fresh session and then continue'
        expected_closes=1
        if [ "$pause_kind" = event ]; then
          note='context limit reached; waiting for a replacement session to take over and PM approval'
          expected_closes=0
        fi
        cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'paused: %s\n' "$FM_FAKE_PAUSE_NOTE" >> "$FM_STATE_OVERRIDE/$1.status"
touch -r "$FM_STATE_OVERRIDE/$1.turn-ended" "$FM_STATE_OVERRIDE/$1.status"
printf 'state: %s · source: fake\n' "$FM_FAKE_CREW_STATE"
SH
        FM_FAKE_PAUSE_NOTE="$note" FM_FAKE_CREW_STATE="$state" run_reconcile "$task_home" --startup
        [ "$(herdr_close_count)" = "$expected_closes" ] || fail "$route $pause_kind pause arriving during $state read used the wrong closure path"
        [ "$(outcome_count "$task_home" pending)" = 0 ] && [ "$(outcome_count "$task_home" reported)" = 0 ] \
          || fail "a pause arriving during the state read produced a terminal outcome"
        [ ! -s "$task_home/state/.wake-queue" ] || fail "a pause arriving during the state read woke the supervisor"
      done
    done
  done
  pass "pauses arriving during a terminal state read retain pause semantics in both homes"
}

test_captain_holds_keep_inactive_herdr_panes_open() {
  local route state protection task_home note hold_rc expected_rc
  for route in main ledger; do
    for state in paused done failed; do
      for protection in held unreadable; do
        make_world "captain-hold-$route-$state-$protection"
        task_home="$MAIN"
        if [ "$route" = ledger ]; then
          bind_secondmate local
          task_home="$MATE"
        fi
        note='PR https://example.test/owner/repo/pull/1 checks green'
        [ "$state" != paused ] || note='context limit reached, fresh session needed'
        write_herdr_child "$task_home" child "$state: $note"
        FM_HOME="$task_home" FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
          "$ROOT/bin/fm-captain-hold.sh" hold child --title 'Review child work' --reason 'Awaiting the captain' >/dev/null \
          || fail "could not create the authoritative captain hold"
        expected_rc=0
        if [ "$protection" = unreadable ]; then
          chmod 000 "$task_home/data/backlog.md"
          expected_rc=2
        fi
        hold_rc=0
        FM_HOME="$task_home" FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
          "$ROOT/bin/fm-captain-hold.sh" open child >/dev/null 2>&1 || hold_rc=$?
        [ "$hold_rc" -eq "$expected_rc" ] || fail "$protection captain-hold fixture did not reach its predicate result"
        FM_FAKE_CREW_STATE="$state" run_reconcile "$task_home" --startup
        chmod 644 "$task_home/data/backlog.md"
        [ "$(herdr_close_count)" = 0 ] || fail "$route $state pane closed with $protection captain-hold state"
        assert_contains "$(cat "$task_home/state/child.status")" "$state: $note" "captain hold replaced the original status"
      done
    done
  done
  pass "authoritative captain holds and unreadable hold state preserve terminal and context-paused panes in both homes"
}

test_captain_hold_and_pane_closure_are_serialized() {
  local route state order task_home note real_tasks_axi control_lock meta_lock
  local control_owner meta_owner hold_pid reconcile_pid hold_rc reconcile_rc ready check_order expected_closes
  real_tasks_axi=$(command -v tasks-axi) || fail "tasks-axi is required for captain-hold races"
  for route in main ledger; do
    for state in done failed paused; do
      for order in hold-first close-first; do
        make_world "captain-hold-race-$route-$state-$order"
        task_home="$MAIN"
        check_order=1
        if [ "$route" = ledger ]; then
          bind_secondmate local
          task_home="$MATE"
          check_order=0
        fi
        note='PR https://example.test/owner/repo/pull/1 checks green'
        [ "$state" != paused ] || note='context limit reached; awaiting a fresh session to resume'
        write_herdr_child "$task_home" child "$state: $note"
        cat > "$WORLD/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${FM_HOLD_RACE_ACTOR:-}:${1:-}:${2:-}" = hold:hold:child ]; then
  : > "$FM_HERDR_WORLD/hold-acquired-control"
  if [ "$FM_HOLD_RACE_ORDER" = hold-first ]; then
    deadline=$((SECONDS + 20))
    while [ ! -e "$FM_HERDR_WORLD/hold-release" ]; do
      [ "$SECONDS" -lt "$deadline" ] || exit 1
      sleep 0.02
    done
  fi
fi
exec "${FM_HOLD_RACE_TASKS_AXI_BIN:?}" "$@"
SH
        chmod +x "$WORLD/fakebin/tasks-axi"
        control_lock="$task_home/state/.control-child.lock"
        meta_lock=$(fm_meta_lock_path "$task_home/state/child.meta")
        ready=1
        reconcile_pid=
        reconcile_rc=0
        expected_closes=0
        if [ "$order" = close-first ]; then
          expected_closes=1
          FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" FM_NATIVE_RACE_ACTOR=reconcile \
            FM_HOLD_RACE_ACTOR=reconcile FM_HOLD_RACE_ORDER="$order" FM_HOLD_RACE_CHECK_ORDER="$check_order" \
            FM_HOLD_RACE_TASKS_AXI_BIN="$real_tasks_axi" run_reconcile "$task_home" --startup > "$WORLD/reconcile.out" 2>&1 &
          reconcile_pid=$!
          wait_native_race_event "$WORLD/close-waiting" || ready=0
          control_owner=$(cat "$control_lock/pid" 2>/dev/null || true)
          meta_owner=$(cat "$meta_lock/pid" 2>/dev/null || true)
          [ -n "$control_owner" ] && [ "$control_owner" = "$meta_owner" ] || ready=0
        fi
        (
          PATH="$WORLD/fakebin:$PATH" FM_HOME="$task_home" FM_STATE_OVERRIDE="$task_home/state" \
            FM_DATA_OVERRIDE="$task_home/data" FM_HERDR_WORLD="$WORLD" FM_HOLD_RACE_ACTOR=hold \
            FM_HOLD_RACE_ORDER="$order" FM_HOLD_RACE_TASKS_AXI_BIN="$real_tasks_axi" \
            "$ROOT/bin/fm-captain-hold.sh" hold child --title 'Review child work' --reason 'Awaiting the captain' \
            && : > "$WORLD/hold-finished"
        ) > "$WORLD/hold.out" 2>&1 &
        hold_pid=$!
        if [ "$order" = hold-first ]; then
          wait_native_race_event "$WORLD/hold-acquired-control" || ready=0
          FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" FM_HOLD_RACE_ACTOR=reconcile \
            FM_HOLD_RACE_ORDER="$order" FM_HOLD_RACE_CHECK_ORDER="$check_order" \
            FM_HOLD_RACE_TASKS_AXI_BIN="$real_tasks_axi" run_reconcile "$task_home" --startup > "$WORLD/reconcile.out" 2>&1 \
            || reconcile_rc=$?
          [ ! -e "$WORLD/herdr-closed" ] || ready=0
        else
          wait_native_race_event "$WORLD/hold-lock-attempt" || ready=0
          [ ! -e "$WORLD/hold-acquired-control" ] && [ ! -e "$WORLD/hold-finished" ] || ready=0
        fi
        : > "$WORLD/hold-release"
        : > "$WORLD/close-release"
        if [ -n "$reconcile_pid" ]; then wait "$reconcile_pid" || reconcile_rc=$?; fi
        hold_rc=0
        wait "$hold_pid" || hold_rc=$?
        [ "$ready" = 1 ] && [ "$hold_rc" = 0 ] && [ "$reconcile_rc" = 0 ] \
          || { cat "$WORLD/reconcile.out" "$WORLD/hold.out"; fail "$route $state $order race did not serialize hold and closure"; }
        [ ! -e "$WORLD/meta-before-control" ] && [ ! -e "$WORLD/close-without-control" ] \
          && [ ! -e "$WORLD/closed-held" ] || fail "$route $state $order violated the task-control boundary"
        [ ! -e "$control_lock" ] && [ ! -L "$control_lock" ] \
          && [ ! -e "$meta_lock" ] && [ ! -L "$meta_lock" ] || fail "hold/close race left a task lock held"
        FM_HOME="$task_home" FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
          "$ROOT/bin/fm-captain-hold.sh" open child || fail "racing hold did not become authoritative"
        [ "$(herdr_close_count)" = "$expected_closes" ] || fail "$order closed the pane on the wrong side of the hold"
        FM_FAKE_CREW_STATE="$state" FM_HOLD_RACE_TASKS_AXI_BIN="$real_tasks_axi" run_reconcile "$task_home" --startup
        [ "$(herdr_close_count)" = "$expected_closes" ] || fail "a later scan closed over the completed hold"
      done
    done
  done
  pass "captain holds and terminal/context-paused closure share task-control-before-metadata ordering in both homes"
}

test_retained_context_pause_requires_current_evidence_and_missing_pane() {
  local variant out
  for variant in unreachable event superseded secondmate; do
    make_world "retained-context-pause-$variant"
    write_herdr_child "$MAIN" child 'paused: context limit reached, fresh session needed'
    set_child_field "$MAIN/state/child.meta" kind scout
    age "$MAIN/state/child.meta"
    run_reconcile "$MAIN" --startup
    [ -e "$WORLD/herdr-closed" ] || fail "$variant fixture did not close its context-paused pane"
    case "$variant" in
      event) printf 'paused: waiting for the PM call on the context limit question\n' >> "$MAIN/state/child.status" ;;
      superseded) printf 'working: resumed in a new session\n' >> "$MAIN/state/child.status" ;;
      secondmate) set_child_field "$MAIN/state/child.meta" kind secondmate ;;
    esac
    if [ "$variant" = unreachable ]; then
      out=$(FM_FAKE_HERDR_UNREACHABLE=1 read_child_state "$MAIN" child)
    else
      out=$(read_child_state "$MAIN" child)
    fi
    assert_contains "$out" 'state: unknown' "$variant incorrectly reused a retained context pause"
  done
  pass "retained context pauses require current pause evidence and a confirmed missing ordinary pane"
}

test_context_paused_busy_herdr_pane_stays_open() {
  make_world context-paused-busy
  write_herdr_child "$MAIN" child 'paused: context limit reached, fresh session needed'
  "$ROOT/bin/fm-busy-event.sh" apply "$MAIN/state" child busy --current-gen --source claude-hook --event user-prompt-submit
  run_reconcile "$MAIN" --startup
  [ "$(herdr_close_count)" = 0 ] || fail "busy context-paused herdr pane was closed"
  pass "busy evidence keeps a context-paused herdr pane open"
}

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# Away-posture regression: a branch-actor drain that consumes an
# inactive-outcome check row must retire its terminal-outcome receipt exactly
# like a main ack does. The 2026-09-25 away window on the supervision host
# consumed the queue row but left the .pending receipt, so every later cadence
# scan republished the same fingerprint - the 1,734-escalation flood.
test_branch_ack_retires_inactive_outcome_receipt() {
  local err seq generation
  make_world branch-ack
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "scan did not queue the terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "scan did not retain a presentation receipt"

  # The same grant the branch dispatch publishes for this row in the away
  # posture (check rows become branch-eligible), with this test's own live
  # process as the recorded grant owner.
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ { print $2 }' "$MAIN/state/.wake-queue" | tail -1)
  case "$seq" in ''|*[!0-9]*) fail "the queued inactive-outcome row had no sequence" ;; esac
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" activate "$$" branch-ack \
    || fail "branch owner activation failed"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" publish branch-ack "$seq" \
    || fail "branch grant publication failed"

  err="$WORLD/branch-drain.err"
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] \
    || { cat "$err"; fail "branch presentation did not require durable acknowledgement"; }
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] || fail "branch acknowledgement left its check row queued"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "branch acknowledgement left the terminal-outcome receipt pending"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "branch acknowledgement never recorded the presentation receipt"

  # The flood's shape: with the receipt retired, later cadence scans must not
  # republish the same unchanged fingerprint.
  local cycle
  for cycle in 1 2 3; do
    age "$MAIN/state/.inactive-outcome-reconcile"
    FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN"
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] \
      || fail "unchanged inactive outcome re-queued on cadence scan $cycle after its branch acknowledgement"
  done
  pass "a branch-actor acknowledgement retires the inactive-outcome receipt and later scans stay quiet"
}

# An unpushed CI-ready ship done: is not a parent-facing ready signal. The
# ledger pass reads the child's line before any PR is recorded for it, so the
# gate tests the worker copy's HEAD.
test_unpushed_ci_ready_done_is_not_published() {
  make_world unpushed-ready; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green, risk low'
  git -C "$MATE/projects/child" commit -q --allow-empty -m 'only in the copy'
  grep -v '^pr=\|^pr_head=' "$MATE/state/child.meta" > "$MATE/state/child.meta.tmp"
  mv "$MATE/state/child.meta.tmp" "$MATE/state/child.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ ! -s "$MAIN/state/mate.status" ] || fail "unpushed CI-ready done: was published upstream"
  [ "$(outcome_count "$MATE" reported)" = 0 ] || fail "unpushed CI-ready done: left a delivery receipt"
  pass "unpushed CI-ready ship done: is not published upstream"
}

# The ledger pass runs on every poll, so a ship done: already delivered does
# not pay for the git reachability check again.
test_delivered_ledger_done_skips_git_gate() {
  local real_git
  make_world gate-once; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/2 checks green'
  real_git=$(command -v git)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' \
    "$WORLD/git.log" "$real_git" > "$WORLD/fakebin/git"
  chmod +x "$WORLD/fakebin/git"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "pushed CI-ready done: was not delivered"
  [ -s "$WORLD/git.log" ] || fail "first delivery did not test the named head"
  : > "$WORLD/git.log"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ ! -s "$WORLD/git.log" ] || fail "a poll after delivery re-ran the git gate: $(cat "$WORLD/git.log")"
  [ "$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "the delivered done: was published again"
  pass "a delivered ship done: skips the git gate on later polls"
}

# A secondmate delivers a child's terminal ledger line to the parent on the
# very next poll, from the ledger alone: no current-state read, no inactive
# cadence, and no line appended by the mate model. The delivery carries the
# child's note, recorded PR, delivery mode, and merge posture, happens once,
# and takes the outcome away from the inactive path so it is never reported
# twice.
test_local_secondmate_delivers_terminal_ledger_line() {
  local expected key
  make_world local; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "ledger receipt did not retain its collision-resistant key"
  expected="done [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "$expected" \
    || fail "secondmate did not deliver the child's ledger line on a plain poll: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "ledger delivery receipt was not durable"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "a second poll delivered the same ledger line again"
  printf 'Report at /tmp/report.md\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "the inactive path reported a child the ledger delivery already owned"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "the inactive path minted a second receipt"
  pass "secondmate delivers a child's terminal ledger line once, on the next poll, from the ledger alone"
}

# A terminal record written as a multi-line block belongs to the ledger path
# whether the block lands before or during the state read: it is delivered once,
# under the ledger's own outcome key, and the inactive fallback stays out of it.
test_secondmate_multiline_terminal_outcome_is_delivered_once() {
  local terminal timing key
  for terminal in 'done' failed; do
    for timing in before during; do
      make_world "multiline-$terminal-$timing"; bind_secondmate local
      write_child "$MATE" child 'working: finishing validation'
      if [ "$timing" = before ]; then
        printf '%s: validation finished\nSee the report for details.\n\n' "$terminal" >> "$MATE/state/child.status"
        age "$MATE/state/child.status"
      else
        cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s: validation finished\nSee the report for details.\n\n' "$FM_FAKE_CREW_STATE" >> "$FM_STATE_OVERRIDE/$1.status"
printf 'state: %s · source: fake\n' "$FM_FAKE_CREW_STATE"
SH
      fi
      FM_FAKE_CREW_STATE="$terminal" run_reconcile "$MATE" --startup
      age "$MATE/state/child.status"
      FM_FAKE_CREW_STATE="$terminal" run_reconcile "$MATE" --startup
      run_report "$MATE" child
      key=$(reported_outcome_key "$MATE" child "$terminal") \
        || fail "$terminal with trailing prose arriving $timing state read was not owned by the ledger"
      sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" \
        | grep -Fq "$terminal [key=$key]: child child $terminal: validation finished" \
        || fail "$terminal with trailing prose arriving $timing state read was lost: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
      [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
        || fail "$terminal with trailing prose arriving $timing state read was delivered twice"
      [ "$(outcome_count "$MATE" reported)" = 1 ] \
        || fail "multiline $terminal outcome did not retain exactly one receipt"
    done
  done
  pass "multiline terminal outcomes are reported once before or during a state read"
}

# A child that dies mid-prose cannot hide an outcome its run already proves: an
# unterminated continuation line states no terminal event, so the inactive
# fallback still reports the attributed failure upward.
test_secondmate_unterminated_prose_reports_run_outcome() {
  make_world unterminated-prose; bind_secondmate local
  write_child "$MATE" child 'working: compiling'
  printf 'Still going' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" \
    | grep -Fq "failed [key=inactive-outcome-mate-child-failed]: inactive terminal child=child" \
    || fail "an unterminated prose line withheld a proven failure: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "the fallback report did not retain its receipt"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "the proven failure was reported twice"
  pass "an unterminated continuation line does not withhold a proven child outcome"
}

# A persistent child that keeps appending routine prose after one terminal
# outcome does not mint a fresh parent event per sentence: the inactive receipt
# identity binds the incarnation, task, terminal state, and PR only, never the
# child's last status line.
test_inactive_receipt_ignores_later_status_prose() {
  make_world prose-after-outcome; bind_secondmate local
  write_child "$MATE" child 'working: quiet since'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MAIN/state/mate.status")" = 1 ] \
    || fail "inactive fallback did not publish exactly once"
  printf 'working: tidying up after the run\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  printf 'working: still tidying\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "changed status prose minted a duplicate parent event: $(cat "$MAIN/state/mate.status")"
  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "changed status prose created a second terminal receipt"
  pass "later status prose does not change the inactive terminal receipt identity"
}

# A busy child cannot keep later ledger outcomes from being visited, and is
# retried on the next poll after its lifecycle lock becomes available.
test_busy_child_does_not_starve_later_ledger_outcomes() {
  local holder i delivered=0
  make_world busy-ledger; bind_secondmate local
  write_child "$MATE" a-busy 'done: busy child finished'
  write_child "$MATE" b-ready 'done: later child finished'
  printf 'epoch=%s\ncursor=\n' "$(date +%s)" > "$MATE/state/.inactive-outcome-reconcile"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/a-busy.meta")
    fm_lock_acquire_wait "$lock"
    : > "$2/busy-lock-held"
    while [ ! -e "$2/release-busy-lock" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  holder=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/busy-lock-held" ]; do sleep 0.05; i=$((i + 1)); done
  if [ -e "$WORLD/busy-lock-held" ]; then
    FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
    grep -Fq 'child-outcome-b-ready-done' "$MAIN/state/mate.status" 2>/dev/null && delivered=1
  fi
  : > "$WORLD/release-busy-lock"
  reap "$holder"
  [ "$delivered" -eq 1 ] \
    || fail "a busy early child starved a later terminal ledger outcome"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  grep -Fq 'child-outcome-a-busy-done' "$MAIN/state/mate.status" \
    || fail "the skipped busy child was not retried on the next poll"
  pass "busy child locks do not starve later ledger outcomes"
}

# A scout's done line carries its report pointer, a failed line is delivered
# under the failed verb, and a later terminal line after recovery is a new
# delivery rather than a suppressed duplicate.
test_secondmate_ledger_delivery_carries_report_and_failure() {
  local scout_key boom_key replaced_key
  make_world ledger-shapes; bind_secondmate local
  write_child "$MATE" scout 'done: report written'
  mkdir -p "$MATE/data/scout"
  printf '# findings\n' > "$MATE/data/scout/report.md"
  write_child "$MATE" boom 'failed: build broke'
  write_child "$MATE" replaced-pr $'working: old PR https://example.test/owner/repo/pull/11\ndone: PR https://example.test/owner/repo/pull/22'
  awk '$0 !~ /^pr=/' "$MATE/state/replaced-pr.meta" > "$MATE/state/replaced-pr.meta.tmp"
  mv "$MATE/state/replaced-pr.meta.tmp" "$MATE/state/replaced-pr.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  scout_key=$(reported_outcome_key "$MATE" scout 'done') || fail "scout receipt key missing"
  boom_key=$(reported_outcome_key "$MATE" boom failed) || fail "failed receipt key missing"
  replaced_key=$(reported_outcome_key "$MATE" replaced-pr 'done') || fail "replacement PR receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$scout_key]: child scout done: report written pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off report=data/scout/report.md" \
    || fail "scout delivery lost its report pointer: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "failed [key=$boom_key]: child boom failed: build broke pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off" \
    || fail "failed line was not delivered under the failed verb: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$replaced_key]: child replaced-pr done: PR https://example.test/owner/repo/pull/22 pr=https://example.test/owner/repo/pull/22 mode=no-mistakes yolo=off" \
    || fail "ledger fallback did not prefer the terminal ready line PR: $(cat "$MAIN/state/mate.status")"
  printf 'working: retrying\ndone: fixed on retry\n' >> "$MATE/state/boom.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  boom_key=$(reported_outcome_key "$MATE" boom 'done') || fail "recovered receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$boom_key]: child boom done: fixed on retry" \
    || fail "a new terminal line after recovery was not delivered"
  [ "$(grep -c 'child-outcome-boom-' "$MAIN/state/mate.status")" = 2 ] \
    || fail "recovery delivered the wrong number of lines: $(cat "$MAIN/state/mate.status")"
  pass "ledger delivery carries the report pointer, the failed verb, and each new terminal line"
}

# A PR URL a worker only ever mentioned in prose is never claimed as the
# task's delivered PR: without a recorded PR, only a terminal line in the
# ready-signal shape carries one, and a scout never carries one at all.
test_pr_field_requires_recorded_pr_or_ready_signal_line() {
  local id prose_key ready_key stamped_key placeholder_key scout_key
  make_world pr-provenance; bind_secondmate local
  write_child "$MATE" prose $'working: context in https://example.test/other/repo/pull/33\ndone: cleanup finished'
  write_child "$MATE" ready 'done: PR https://example.test/owner/repo/pull/44 checks green'
  write_child "$MATE" stamped 'done [at=1788576000]: PR https://example.test/owner/repo/pull/66 checks green'
  write_child "$MATE" placeholder 'done [at=<epoch>]: PR https://example.test/owner/repo/pull/77 checks green'
  write_child "$MATE" lookout 'done: PR https://example.test/owner/repo/pull/55'
  for id in prose ready stamped placeholder; do
    awk '$0 !~ /^pr=/' "$MATE/state/$id.meta" > "$MATE/state/$id.meta.tmp"
    mv "$MATE/state/$id.meta.tmp" "$MATE/state/$id.meta"
  done
  awk '{ sub(/^kind=ship$/, "kind=scout"); print }' "$MATE/state/lookout.meta" \
    > "$MATE/state/lookout.meta.tmp"
  mv "$MATE/state/lookout.meta.tmp" "$MATE/state/lookout.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  prose_key=$(reported_outcome_key "$MATE" prose 'done') || fail "prose receipt key missing"
  ready_key=$(reported_outcome_key "$MATE" ready 'done') || fail "ready receipt key missing"
  stamped_key=$(reported_outcome_key "$MATE" stamped 'done') || fail "stamped ready receipt key missing"
  placeholder_key=$(reported_outcome_key "$MATE" placeholder 'done') \
    || fail "unsubstituted-stamp ready receipt key missing"
  scout_key=$(reported_outcome_key "$MATE" lookout 'done') || fail "scout receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$prose_key]: child prose done: cleanup finished mode=no-mistakes yolo=off" \
    || fail "a PR mentioned only in prose was claimed as the delivery: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$ready_key]: child ready done: PR https://example.test/owner/repo/pull/44 checks green pr=https://example.test/owner/repo/pull/44 mode=no-mistakes yolo=off" \
    || fail "a ready-signal terminal line did not carry its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$stamped_key]: child stamped done: PR https://example.test/owner/repo/pull/66 checks green pr=https://example.test/owner/repo/pull/66 mode=no-mistakes yolo=off" \
    || fail "a stamped ready-signal terminal line did not carry its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$placeholder_key]: child placeholder done: PR https://example.test/owner/repo/pull/77 checks green pr=https://example.test/owner/repo/pull/77 mode=no-mistakes yolo=off" \
    || fail "a ready-signal line whose stamp was left unsubstituted lost its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$scout_key]: child lookout done: PR https://example.test/owner/repo/pull/55 mode=no-mistakes yolo=off" \
    || fail "a scout's ready-looking line carried a PR claim: $(cat "$MAIN/state/mate.status")"
  pass "pr= requires the recorded PR or a ready-signal terminal line, whatever its stamp, and never a scout"
}

# If a terminal ledger line lands while the authoritative state read is in
# flight, the ledger path remains the single owner on the next poll.
test_terminal_line_during_state_read_yields_to_ledger_delivery() {
  make_world state-ledger-race; bind_secondmate local
  write_herdr_child "$MATE" child 'working: finishing now'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_HERDR_WORLD/state-appended" ]; then
  printf 'done: PR https://example.test/owner/repo/pull/1 checks green\n' >> "$FM_STATE_OVERRIDE/$1.status"
  : > "$FM_HERDR_WORLD/state-appended"
fi
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  run_reconcile "$MATE" --startup
  [ ! -e "$MAIN/state/mate.status" ] \
    || ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "inactive reconciliation claimed an outcome whose terminal ledger arrived during state read"
  run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")" = 1 ] \
    || fail "the next ledger pass did not deliver the raced terminal line exactly once"
  ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "one raced terminal event was reported by both reconciliation paths"
  [ "$(herdr_close_count)" = 0 ] || fail "a newly appended terminal ledger line closed its pane"
  age "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  run_reconcile "$MATE" --startup
  [ "$(herdr_close_count)" = 1 ] || fail "raced terminal ledger outcome never became eligible for closure"
  [ "$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")" = 1 ] \
    || fail "closing the raced terminal outcome duplicated its parent report"
  pass "terminal lines arriving during state reads remain ledger-owned"
}

# A terminal append can land after the inactive path's final ledger read but
# before its already-selected outcome is observed on the next poll. The receipt
# store reconciles that ledger event with the fallback delivery, while a later
# same-state completion remains independently deliverable.
test_terminal_line_after_inactive_delivery_is_not_reported_twice() {
  make_world inactive-ledger-race; bind_secondmate local
  write_child "$MATE" child 'working: finishing now'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "inactive fallback did not publish exactly once"

  printf 'done: completion landed after reconciliation\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "one completion was published by both inactive and ledger paths: $(cat "$MAIN/state/mate.status")"
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "the raced ledger event was not durably reconciled with the fallback receipt"

  printf 'working: retrying after completion\ndone: completed again\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 2 ] \
    || fail "the inactive claim suppressed a later same-state terminal event: $(cat "$MAIN/state/mate.status")"
  grep -Fq 'child child done: completed again' "$MAIN/state/mate.status" \
    || fail "the later same-state terminal event was not delivered"
  pass "inactive and ledger paths reconcile one raced completion without hiding later events"
}

# An intervening progress line means the next terminal line is a new completion,
# not a late ledger rendering of the inactive fallback.
test_progress_after_inactive_delivery_starts_a_new_event() {
  make_world inactive-recovery; bind_secondmate local
  write_child "$MATE" child 'working: first attempt finishing'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  printf 'working: retry started\ndone: retry completed\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 2 ] \
    || fail "an intervening progress event did not separate two completions: $(cat "$MAIN/state/mate.status")"
  grep -Fq 'child child done: retry completed' "$MAIN/state/mate.status" \
    || fail "the completion after recovery was not delivered"
  pass "progress after an inactive fallback starts a distinct terminal event"
}

# Receipt identity covers the complete terminal ledger line even when the
# captain-facing rendering truncates two long notes to the same text.
test_long_terminal_lines_have_distinct_receipts() {
  local prefix
  make_world long-ledger; bind_secondmate local
  prefix=$(awk 'BEGIN { for (i = 0; i < 1300; i++) printf "a" }')
  write_child "$MATE" child "failed: ${prefix}one"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  printf 'failed: %stwo\n' "$prefix" >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "distinct complete ledger lines collided in the receipt store"
  [ "$(grep -c 'child-outcome-child-failed-' "$MAIN/state/mate.status")" = 2 ] \
    || fail "distinct complete ledger lines collapsed into one parent delivery"
  pass "complete long ledger lines retain distinct receipt identities"
}

# A line still being appended has no trailing newline yet and must wait.
test_secondmate_partial_ledger_line_waits_for_newline() {
  local key
  make_world partial; bind_secondmate local
  write_child "$MATE" child 'working: nearly there'
  printf 'done: half writ' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ ! -s "$MAIN/state/mate.status" ] \
    || fail "an unterminated ledger line was delivered: $(cat "$MAIN/state/mate.status")"
  printf 'ten\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "completed ledger receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: half written" \
    || fail "the completed line was not delivered once its newline landed"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "completing the partial line delivered the outcome twice"
  pass "a ledger line still being appended waits for its newline"
}

# The remote route delivers the same line into this home's parent-replies
# input, once.
test_secondmate_remote_route_ledger_delivery() {
  make_world remote-ledger; bind_secondmate remote
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote ledger delivery was not once-only: $(cat "$MATE/state/parent-replies.status" 2>/dev/null)"
  pass "the remote route carries a child's ledger line once"
}

# A ship done: the gate accepted stays owed while its parent write is pending.
# Teardown removes the worktree before `report`, so the retry delivers that
# line instead of re-testing a copy that no longer exists.
test_pending_ledger_done_is_delivered_after_worktree_removal() {
  local key
  make_world pending-retry; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/2 checks green'
  cp "$MATE/.fm-secondmate-parent" "$WORLD/parent-binding"
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" pending)" = 1 ] || fail "failed parent write did not leave a pending delivery"
  rm -rf "$MATE/projects/child"
  cp "$WORLD/parent-binding" "$MATE/.fm-secondmate-parent"
  run_report "$MATE" child || fail "report refused the pending delivery"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "pending delivery was dropped instead of reported"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: PR https://example.test/owner/repo/pull/2 checks green" \
    || fail "report did not deliver the pending done after the worktree was removed"
  pass "a pending ship done: is delivered by report after teardown removed the worktree"
}

# `report <child>` is the teardown-side delivery: it delivers or says nothing
# is owed with 0, and returns non-zero only when the channel cannot be written.
test_report_subcommand_delivers_and_refuses() {
  local rc key
  make_world report; bind_secondmate local
  write_child "$MATE" child 'done: final word'
  run_report "$MATE" child || fail "report refused a deliverable ledger line"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "report receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: final word" \
    || fail "report did not deliver the child's final line"
  run_report "$MATE" child || fail "report did not treat an already delivered line as owed nothing"
  write_child "$MATE" quiet 'working: nothing terminal'
  run_report "$MATE" quiet || fail "report refused a child that owes nothing"
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" stuck 'failed: cannot reach anyone'
  rc=0
  run_report "$MATE" stuck >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "report claimed delivery through an unusable parent binding"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "undeliverable report did not queue its notice"
  write_child "$MAIN" child 'done: main home child'
  run_report "$MAIN" child || fail "report failed in a main home"
  [ ! -e "$MAIN/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  pass "report delivers a child's final line, owes nothing twice, and refuses only an unwritable channel"
}

# Teardown calls report while holding the child's metadata lock. A concurrent
# scan may hold the scan lock while waiting for that metadata lock, so report
# must not wait for the scan lock in the opposite order.
test_report_avoids_scan_meta_lock_inversion() {
  local holder scan_pid report_pid i completed=0
  make_world report-lock-order; bind_secondmate local
  write_child "$MATE" child 'done: final word'
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/child.meta")
    fm_lock_acquire_wait "$lock"
    : > "$2/meta-held"
    while [ ! -e "$2/release-meta" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  holder=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/meta-held" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/meta-held" ] || { reap "$holder"; fail "metadata lock holder did not start"; }

  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE" --startup &
  scan_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$MATE/state/.inactive-outcome-reconcile.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$MATE/state/.inactive-outcome-reconcile.lock" ] \
    || { : > "$WORLD/release-meta"; reap "$holder"; reap "$scan_pid"; fail "scan lock holder did not start"; }

  (run_report "$MATE" child && : > "$WORLD/report-complete") &
  report_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/report-complete" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/report-complete" ] && completed=1
  : > "$WORLD/release-meta"
  reap "$holder"
  reap "$report_pid"
  reap "$scan_pid"
  [ "$completed" -eq 1 ] || fail "report deadlocked behind a scan waiting for the caller's metadata lock"
  pass "report preserves teardown's metadata-before-scan lock order"
}

test_local_secondmate_rejects_relative_parent_home() {
  make_world relative-parent; bind_secondmate local
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=relative-parent\n' \
    > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  (cd "$WORLD" && FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
  [ ! -e "$WORLD/relative-parent/state/mate.status" ] \
    || fail "relative parent home received a false durable report"
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "relative parent route was recorded as reported"
  [ "$(outcome_count "$MATE" pending)" = 1 ] \
    || fail "failed relative parent route did not retain its pending receipt"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] \
    || fail "failed relative parent route did not surface a recovery notice"
  pass "relative local parent homes fail closed"
}

# A present invalid identity marker cannot turn a secondmate home into a main
# home. The original child state remains available after the routing alarm.
test_invalid_secondmate_marker_blocks_routing() {
  local kind out target
  for kind in malformed symlink; do
    make_world "invalid-marker-$kind"
    write_child "$MATE" child 'failed: terminal'
    if [ "$kind" = malformed ]; then
      printf '../main\n' > "$MATE/.fm-secondmate-home"
    else
      target="$WORLD/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$MATE/.fm-secondmate-home"
    fi

    out=$(FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
    printf '%s\n' "$out" | grep -Fq 'inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker' \
      || fail "$kind secondmate marker did not surface the blocked terminal obligation"
    [ "$(outcome_count "$MATE" pending)" = 0 ] \
      || fail "$kind secondmate marker created a main-home pending receipt"
    [ "$(wake_count "$MATE" 'inactive-reconcile-diagnostic:invalid-secondmate-home')" = 1 ] \
      || fail "$kind secondmate marker diagnostic was not durably queued"
    ! grep -Fq 'inactive-outcome:' "$MATE/state/.wake-queue" 2>/dev/null \
      || fail "$kind secondmate marker routed a captain presentation wake"
    [ -f "$MATE/state/child.meta" ] && [ -f "$MATE/state/child.status" ] \
      || fail "$kind secondmate marker lost the terminal obligation"
  done
  pass "invalid secondmate markers block routing and surface the obligation"
}

# A remote child route writes the existing mirror input once even across restarts.
test_remote_parent_reply_is_idempotent() {
  make_world remote; bind_secondmate remote; write_child "$MATE" child 'working: quiet since'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote parent reply was not restart-idempotent"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "remote parent report receipt missing"
  pass "remote parent-replies mirror input is durable and idempotent"
}

# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id; bind_secondmate remote
  write_child "$MATE" child 'working: quiet since' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  rm -f "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  write_child "$MATE" child 'working: quiet since' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "reused task id collided with the retired incarnation receipt"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 2 ] \
    || fail "reused task id did not produce an independent parent report"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite; bind_secondmate remote
  write_child "$MATE" child 'working: quiet since' spawn-old
  meta="$MATE/state/child.meta"
  tmp="$MATE/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup

  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "legacy metadata rewrite duplicated the parent report"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race; bind_secondmate remote
  write_child "$MATE" child 'working: quiet since' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MATE" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.reported' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

test_terminal_herdr_child_pane_closes_and_records_stay() {
  local state out record fingerprint
  for state in "done" failed; do
    make_world "pane-close-$state"
    write_herdr_child "$MAIN" child "$state: PR https://example.test/owner/repo/pull/1 checks green"
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(herdr_close_count)" = 1 ] || fail "$state herdr child pane was not closed"
    [ -e "$WORLD/outcome-before-close" ] || fail "$state outcome was not durable before closing"
    [ -f "$MAIN/state/child.meta" ] && [ -f "$MAIN/state/child.status" ] \
      && [ -d "$MAIN/projects/child" ] || fail "$state child records or worktree were removed"
    [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "$state terminal outcome was not retained"
    out=$(read_child_state "$MAIN" child)
    assert_contains "$out" "state: $state" "closed $state child lost its retained current state"
    record=$(find "$MAIN/state/terminal-outcomes" -name '*.pending' -type f)
    fingerprint=$(sed -n 's/^fingerprint=//p' "$record")
    FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$RECON" acknowledge "$fingerprint"
    out=$(read_child_state "$MAIN" child)
    assert_contains "$out" "state: $state" "presentation discarded the closed $state outcome"
  done
  pass "terminal herdr panes close after persistence and retain current state through presentation"
}

test_other_backend_panes_stay_open() {
  local backend meta state
  for state in "done" failed; do
    for backend in default tmux zellij orca cmux; do
      make_world "pane-keep-$state-$backend"
      write_child "$MAIN" child "$state: PR https://example.test/owner/repo/pull/1 checks green"
      meta="$MAIN/state/child.meta"
      if [ "$backend" != default ]; then
        printf 'backend=%s\nendpoint_task_id=child\n' "$backend" >> "$meta"
        case "$backend" in
          zellij)
            set_child_field "$meta" window zs:1
            printf '%s\n' 'zellij_session=zs' 'zellij_tab_id=1' 'zellij_pane_id=1' >> "$meta" ;;
          orca)
            set_child_field "$meta" window fm-child
            printf 'terminal=term-1\norca_worktree_id=wid::%s\n' "$MAIN/projects/child" >> "$meta" ;;
          cmux)
            set_child_field "$meta" window workspace:surface
            printf '%s\n' 'cmux_workspace_id=workspace' 'cmux_surface_id=surface' >> "$meta" ;;
        esac
        age "$meta"
      fi
      FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
      [ "$(tmux_kill_count "$WORLD")" = 0 ] && [ ! -s "$WORLD/other-backends.log" ] \
        || fail "$backend endpoint was touched"
      [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "$backend outcome was not reconciled"
    done
  done
  pass "tmux, Zellij, Orca, and cmux endpoints stay open"
}

test_herdr_close_requires_semantic_idle() {
  local state evidence meta
  for state in "done" failed; do
    for evidence in busy unknown missing malformed stale codex grok; do
      make_world "pane-$state-$evidence"
      write_herdr_child "$MAIN" child "$state: PR https://example.test/owner/repo/pull/1 checks green"
      meta="$MAIN/state/child.meta"
      case "$evidence" in
        busy|unknown)
          "$ROOT/bin/fm-busy-event.sh" apply "$MAIN/state" child "$evidence" --current-gen --source claude-hook --event test ;;
        missing|codex|grok)
          "$ROOT/bin/fm-busy-event.sh" retire "$MAIN/state" child --current-gen
          if [ "$evidence" != missing ]; then set_child_field "$meta" harness "$evidence"; fi ;;
        malformed) printf 'invalid\n' > "$MAIN/state/child.busy-state" ;;
        stale) printf 'replacement-gen\n' > "$MAIN/state/child.busy-gen" ;;
      esac
      age "$meta"
      FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
      [ "$(herdr_close_count)" = 0 ] || fail "$state pane closed with $evidence evidence"
    done
  done
  for state in working paused parked blocked unknown; do
    make_world "pane-nonterminal-$state"
    write_herdr_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(herdr_close_count)" = 0 ] || fail "$state pane closed despite nonterminal state"
  done
  pass "only positive semantic idle permits terminal herdr closure"
}

test_pending_steering_keeps_inactive_herdr_pane_open() {
  local route state delivery task_home phase lock message note expected_outcomes
  for route in main ledger; do
    for state in "done" failed paused; do
      for delivery in '' fire-and-forget; do
        make_world "pending-steer-$route-$state-${delivery:-ordinary}"
        task_home="$MAIN"
        phase=pending
        if [ "$route" = ledger ]; then
          bind_secondmate local
          task_home="$MATE"
          phase=reported
        fi
        note='PR https://example.test/owner/repo/pull/1 checks green'
        expected_outcomes=1
        if [ "$state" = paused ]; then
          note='context limit reached, fresh session needed'
          expected_outcomes=0
        fi
        write_herdr_child "$task_home" child "$state: $note"
        lock=$(fm_meta_lock_path "$task_home/state/child.meta")
        fm_lock_acquire_wait "$lock" || fail "could not lock metadata for steering enqueue"
        message=$(fm_task_inbox_write "$task_home/state" child 'Please continue with this follow-up.' "$delivery") \
          || fail "could not enqueue steering message"
        fm_lock_release "$lock"

        FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" run_reconcile "$task_home" --startup
        [ "$(outcome_count "$task_home" "$phase")" = "$expected_outcomes" ] || fail "$state scan produced an unexpected outcome count"
        [ "$(herdr_close_count)" = 0 ] && [ ! -e "$WORLD/herdr-closed" ] \
          || fail "$route $state pane closed with an unhandled ${delivery:-ordinary} message"
        [ -f "$message" ] || fail "closure check consumed an unhandled message"

        mv "$message" "$(fm_task_inbox_handled_dir "$task_home/state" child)/"
        FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" run_reconcile "$task_home" --startup
        [ "$(herdr_close_count)" = 1 ] && [ -e "$WORLD/herdr-closed" ] \
          || fail "$route $state pane stayed open after its message was acknowledged"
      done
    done
  done
  pass "unhandled ordinary and fire-and-forget steering prevents terminal and context-paused closure in both homes"
}

test_native_submit_and_terminal_closure_are_serialized() {
  local route state task_home selector order send_pid reconcile_pid send_rc reconcile_rc ready active_before_close
  local native_activity receipt_phase meta_lock
  for route in main ledger; do
    for state in "done" failed; do
      make_world "native-close-$route-$state"
      task_home="$MAIN"
      selector=child
      receipt_phase=pending
      if [ "$route" = ledger ]; then
        bind_secondmate local
        task_home="$MATE"
        selector=fm-child
        receipt_phase=reported
      fi
      write_herdr_child "$task_home" child "$state: PR https://example.test/owner/repo/pull/1 checks green"
      "$ROOT/bin/fm-busy-event.sh" apply "$task_home/state" child busy --current-gen --source claude-hook --event test
      FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" run_reconcile "$task_home" --startup >/dev/null
      [ "$(outcome_count "$task_home" "$receipt_phase")" = 1 ] || fail "native closure race has no accepted terminal outcome"
      "$ROOT/bin/fm-busy-event.sh" apply "$task_home/state" child idle --current-gen --source claude-hook --event stop
      age "$task_home/state/child.meta" "$task_home/state/child.status" "$task_home/state/child.turn-ended"
      ready=1
      active_before_close=0
      native_activity=0
      if [ "$state" = "done" ]; then
        order=submit-first
        selector=default:w1:p1
        run_native_submit "$task_home" "$selector" "$order" > "$WORLD/send.out" 2> "$WORLD/send.err" &
        send_pid=$!
        wait_native_race_event "$WORLD/native-typed" || ready=0
        [ ! "$task_home/state/child.meta" -nt "$task_home/state/child.status" ] || native_activity=1
        age "$task_home/state/child.meta"
        FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" FM_NATIVE_RACE_ACTOR=reconcile \
          run_reconcile "$task_home" --startup > "$WORLD/reconcile.out" 2>&1 &
        reconcile_pid=$!
        if [ -e "$WORLD/native-lock-attempt" ]; then
          wait_native_race_event "$WORLD/reconcile-started" || ready=0
        else
          wait_native_race_event "$WORLD/close-waiting" || ready=0
        fi
        : > "$WORLD/send-release"
        wait_native_race_event "$WORLD/native-started" || ready=0
      else
        order=close-first
        FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_FAKE_CREW_STATE="$state" FM_NATIVE_RACE_ACTOR=reconcile \
          run_reconcile "$task_home" --startup > "$WORLD/reconcile.out" 2>&1 &
        reconcile_pid=$!
        wait_native_race_event "$WORLD/close-waiting" || ready=0
        run_native_submit "$task_home" "$selector" "$order" > "$WORLD/send.out" 2> "$WORLD/send.err" &
        send_pid=$!
        wait_native_race_event "$WORLD/native-lock-attempt" "$WORLD/native-typed" || ready=0
        if [ ! -e "$WORLD/native-lock-attempt" ]; then
          wait_native_race_event "$WORLD/native-started" || ready=0
        fi
        [ ! -e "$WORLD/native-started" ] || active_before_close=1
      fi
      : > "$WORLD/send-release"
      : > "$WORLD/close-release"
      send_rc=0
      reconcile_rc=0
      wait "$send_pid" || send_rc=$?
      wait "$reconcile_pid" || reconcile_rc=$?
      meta_lock=$(fm_meta_lock_path "$task_home/state/child.meta")
      [ ! -e "$meta_lock" ] && [ ! -L "$meta_lock" ] || fail "native submission left its metadata lock held"
      [ "$ready" = 1 ] || { cat "$WORLD/send.err" "$WORLD/reconcile.out"; fail "native closure race never reached its synchronization points"; }
      [ ! -e "$WORLD/closed-running" ] || fail "native submission was killed while closure waited"
      [ "$reconcile_rc" = 0 ] || fail "reconciliation failed during native submission"
      if [ "$order" = submit-first ]; then
        [ "$send_rc" = 0 ] || { cat "$WORLD/send.err"; fail "native submission failed before closure"; }
        [ "$native_activity" = 1 ] || fail "native submission did not refresh task activity under its lock"
        [ "$(cat "$WORLD/native-text")" = /no-mistakes ] || fail "native command was changed before submission"
        [ "$(herdr_close_count)" = 0 ] || fail "closure ignored the new busy state after waiting for the native submission"
        [ -e "$WORLD/state-read" ] || fail "closure did not re-read state after the native submission released its lock"
      else
        [ "$active_before_close" = 0 ] || fail "native submission bypassed the closing task's metadata lock"
        [ "$send_rc" -ne 0 ] || fail "native submission reported success after its endpoint closed"
        [ ! -e "$WORLD/native-text" ] || fail "native command was typed after its endpoint closed"
        [ -e "$WORLD/herdr-closed" ] || fail "idle terminal pane did not close before the waiting native submission"
      fi
    done
  done
  pass "native task submissions and both terminal closure paths share their metadata/activity boundary"
}

test_herdr_prevalidation_and_unproven_identity_stay_open() {
  local mode evidence meta
  for mode in no-mistakes ''; do
    make_world "pane-handoff-${mode:-default}"
    write_herdr_child "$MAIN" child 'done: implementation ready for validation'
    set_child_field "$MAIN/state/child.meta" mode "$mode"
    age "$MAIN/state/child.meta"
    FM_FAKE_CREW_STATE="done" run_reconcile "$MAIN" --startup
    [ "$(herdr_close_count)" = 0 ] || fail "pre-validation $mode handoff pane closed"
  done
  for evidence in task endpoint incarnation captain-held recent; do
    make_world "pane-identity-$evidence"
    write_herdr_child "$MAIN" child 'failed: boom'
    meta="$MAIN/state/child.meta"
    case "$evidence" in
      task) set_child_field "$meta" endpoint_task_id other ;;
      endpoint) set_child_field "$meta" herdr_pane_id w1:p2 ;;
      incarnation) set_child_field "$meta" spawn_gen '' ;;
      captain-held) printf 'captain-held: awaiting captain\n' > "$MAIN/state/child.status" ;;
      recent) touch "$MAIN/state/child.turn-ended" ;;
    esac
    age "$meta"
    FM_FAKE_CREW_STATE=failed run_reconcile "$MAIN" --startup
    [ "$(herdr_close_count)" = 0 ] || fail "pane closed with $evidence identity/activity"
  done
  pass "pre-validation handoffs, ambiguous identities, held work, and recent turns stay open"
}

test_secondmate_ledger_children_close_without_duplicate_reports() {
  local state route receipt
  for route in local remote; do
    for state in "done" failed; do
      make_world "ledger-close-$route-$state"; bind_secondmate "$route"
      write_herdr_child "$MATE" child "$state: PR https://example.test/owner/repo/pull/1 checks green"
      if [ "$route" = local ]; then
        "$ROOT/bin/fm-busy-event.sh" apply "$MATE/state" child busy --current-gen --source claude-hook --event test
        FM_FAKE_CREW_STATE="$state" run_reconcile "$MATE" --startup
        [ "$(herdr_close_count)" = 0 ] || fail "a running ledger child was closed"
        assert_contains "$(read_child_state "$MATE" child)" 'state: working' "terminal ledger hid a running turn"
        "$ROOT/bin/fm-busy-event.sh" apply "$MATE/state" child idle --current-gen --source claude-hook --event stop
      else
        FM_FAKE_CREW_STATE="$state" FM_FAKE_HERDR_CLOSE_FAIL=1 run_reconcile "$MATE" --startup
        [ ! -e "$WORLD/herdr-closed" ] || fail "failed close removed the pane"
        assert_contains "$(read_child_state "$MATE" child)" "state: $state" "a failed close broke live terminal state"
      fi
      [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "ledger outcome was not reported"
      FM_FAKE_CREW_STATE="$state" run_reconcile "$MATE" --startup
      [ -e "$WORLD/herdr-closed" ] || fail "deduplicated ledger outcome prevented a later pane close"
      [ "$(outcome_count "$MATE" reported)" = 1 ] && [ "$(outcome_count "$MATE" pending)" = 0 ] \
        || fail "ledger closure created a duplicate outcome"
      if [ "$route" = local ]; then receipt="$MAIN/state/mate.status"; else receipt="$MATE/state/parent-replies.status"; fi
      [ "$(wc -l < "$receipt" | tr -d ' ')" = 1 ] || fail "ledger close duplicated its parent report"
      assert_contains "$(read_child_state "$MATE" child)" "state: $state" "reported ledger closure lost terminal state"
    done
  done
  pass "ledger-owned terminal children close in both parent routes without duplicate reports"
}

test_herdr_close_waits_for_durable_outcome() {
  local failure
  for failure in pending record; do
    make_world "pane-write-failed-$failure"
    write_herdr_child "$MAIN" child 'failed: boom'
    FM_FAKE_CREW_STATE=failed FM_FAKE_FAIL_RECORD_WRITE="$failure" run_reconcile "$MAIN" --startup >/dev/null 2>&1 || true
    [ "$(herdr_close_count)" = 0 ] || fail "$failure write failure still closed the pane"
  done
  pass "outcome and close-intent write failures preserve the pane"
}

test_retained_herdr_outcome_is_bound_to_spawn_and_endpoint() {
  local variant record out
  for variant in scout direct-PR local-only spawn endpoint task unmarked unreachable earlier-failure; do
    make_world "pane-retained-$variant"
    write_herdr_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
    case "$variant" in
      scout) set_child_field "$MAIN/state/child.meta" kind scout ;;
      direct-PR|local-only) set_child_field "$MAIN/state/child.meta" mode "$variant" ;;
      earlier-failure)
        printf 'failed: earlier attempt\n' > "$MAIN/state/child.status"
        age "$MAIN/state/child.meta" "$MAIN/state/child.status"
        FM_FAKE_CREW_STATE=failed FM_FAKE_HERDR_CLOSE_FAIL=1 run_reconcile "$MAIN" --startup
        printf 'done: PR https://example.test/owner/repo/pull/1 checks green\n' >> "$MAIN/state/child.status"
        age "$MAIN/state/child.status" ;;
    esac
    age "$MAIN/state/child.meta"
    FM_FAKE_CREW_STATE="done" run_reconcile "$MAIN" --startup
    [ -e "$WORLD/herdr-closed" ] || fail "$variant fixture did not close its pane"
    record=$(find "$MAIN/state/terminal-outcomes" -name '*.pending' -type f | head -1)
    case "$variant" in
      spawn) set_child_field "$MAIN/state/child.meta" spawn_gen replacement ;;
      endpoint) set_child_field "$MAIN/state/child.meta" window default:w1:p2 ;;
      task) set_child_field "$record" task_id other ;;
      unmarked) set_child_field "$record" pane_close_target '' ;;
    esac
    if [ "$variant" = unreachable ]; then
      out=$(FM_FAKE_HERDR_UNREACHABLE=1 read_child_state "$MAIN" child)
    else
      out=$(read_child_state "$MAIN" child)
    fi
    case "$variant" in
      scout|direct-PR|local-only|earlier-failure) assert_contains "$out" 'state: done' "$variant lost its closed outcome" ;;
      *) assert_contains "$out" 'state: unknown' "$variant incorrectly reused a closed outcome" ;;
    esac
  done
  pass "retained closed outcomes require the exact spawn, endpoint, and confirmed missing pane"
}

# The actual watcher poll invokes the helper, while an idle secondmate remains
# exempt from wedge escalation and emits no false wake.
test_watcher_hook_and_idle_secondmate_exemption() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"

  make_world idle-secondmate; bind_secondmate local; write_mate_meta; prime_seen "$MAIN/state" "$MAIN/state/mate.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WORLD/idle.out" 2>&1 &
  pid=$!; sleep 2; kill -0 "$pid" 2>/dev/null || fail "idle secondmate watcher exited unexpectedly"; reap "$pid"
  grep -F 'stale:' "$WORLD/idle.out" >/dev/null && fail "idle secondmate was treated as a wedge"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "idle secondmate emitted a false wake"
  pass "watcher hook wakes for terminal loss and preserves idle secondmate exemption"
}

# The real watcher poll in a secondmate home delivers a child's terminal ledger
# line to the parent channel on its first cycle, with no line appended by the
# mate and no wake needed in the mate home for it.
test_watcher_poll_delivers_child_ledger_line_to_parent() {
  local pid i key
  make_world watcher-ledger; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  prime_seen "$MATE/state" "$MATE/state/child.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_CONFIG_OVERRIDE="$MATE/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_FORGE_LOG="$WORLD/forge.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='unknown' "$WATCH" > "$WORLD/mate-watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -q 'child-outcome-child-done' "$MAIN/state/mate.status" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "watcher ledger receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off" \
    || fail "the watcher poll did not deliver the child's ledger line to the parent: $(cat "$MAIN/state/mate.status" 2>/dev/null; cat "$WORLD/mate-watch.out")"
  [ ! -s "$WORLD/forge.log" ] || fail "ledger delivery invoked a forge command"
  pass "the real watcher poll delivers a child's terminal ledger line to the parent channel"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  # The unbounded wake-lock wait is ended by the process-group backstop, which
  # fires one second after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

# A secondmate home seeded without its parent binding cannot report ANY terminal
# outcome upward, and every later one fails for the same reason. The diagnostic
# has to name the binding, or three weeks of identical failures read as three
# weeks of unrelated report failures.
test_missing_parent_binding_names_itself() {
  local out
  make_world missing-binding
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  write_child "$MATE" child 'done: PR merged'
  write_child "$MATE" quiet 'working: quiet since'
  out=$(FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup)
  case "$out" in
    *"actionable: child outcome needs parent report: child=child"*".fm-secondmate-parent"*) ;;
    *) fail "a missing parent binding did not name itself for a ledger delivery: $out" ;;
  esac
  case "$out" in
    *"actionable: inactive terminal outcome needs parent report: child=quiet"*".fm-secondmate-parent"*) ;;
    *) fail "a missing parent binding did not name itself for an inactive report: $out" ;;
  esac
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "an outcome that never reached a parent was recorded as reported"
  pass "a secondmate home with no parent binding names the missing binding instead of failing quietly"
}

test_notice_recovery_does_not_duplicate_wake() {
  local record err seq generation
  make_world notice-recovery; bind_secondmate remote
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'working: quiet since'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "parent-report failure did not queue one notice"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  awk '{ sub(/^notice_emitted=1$/, "notice_emitted=0"); print }' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "recovery duplicated an already queued notice"

  err="$WORLD/drain.err"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 0 ] || fail "acknowledged notice was emitted again"
  pass "notice recovery remains idempotent across queue acknowledgement"
}

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_reconciliation_sets_no_forge_mode_for_state_read() {
  make_world no-forge-env; write_child "$MAIN" child 'working: quiet since'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_CREW_STATE_NO_FORGE:-}" > "${FM_NO_FORGE_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  export FM_NO_FORGE_LOG="$WORLD/no-forge.log"
  run_reconcile "$MAIN" --startup
  unset FM_NO_FORGE_LOG
  assert_grep '1' "$WORLD/no-forge.log" "inactive reconciliation did not set crew-state no-forge mode"
  pass "reconciliation state reads set no-forge mode"
}

test_main_direct_terminal_presentation_receipt
test_branch_ack_retires_inactive_outcome_receipt
test_unpushed_ci_ready_done_is_not_published
test_delivered_ledger_done_skips_git_gate
test_local_secondmate_delivers_terminal_ledger_line
test_secondmate_multiline_terminal_outcome_is_delivered_once
test_secondmate_unterminated_prose_reports_run_outcome
test_inactive_receipt_ignores_later_status_prose
test_busy_child_does_not_starve_later_ledger_outcomes
test_secondmate_ledger_delivery_carries_report_and_failure
test_pr_field_requires_recorded_pr_or_ready_signal_line
test_terminal_line_during_state_read_yields_to_ledger_delivery
test_terminal_line_after_inactive_delivery_is_not_reported_twice
test_progress_after_inactive_delivery_starts_a_new_event
test_long_terminal_lines_have_distinct_receipts
test_secondmate_partial_ledger_line_waits_for_newline
test_secondmate_remote_route_ledger_delivery
test_report_subcommand_delivers_and_refuses
test_pending_ledger_done_is_delivered_after_worktree_removal
test_report_avoids_scan_meta_lock_inversion
test_local_secondmate_rejects_relative_parent_home
test_invalid_secondmate_marker_blocks_routing
test_remote_parent_reply_is_idempotent
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_terminal_herdr_child_pane_closes_and_records_stay
test_other_backend_panes_stay_open
test_herdr_close_requires_semantic_idle
test_pending_steering_keeps_inactive_herdr_pane_open
test_native_submit_and_terminal_closure_are_serialized
test_herdr_prevalidation_and_unproven_identity_stay_open
test_secondmate_ledger_children_close_without_duplicate_reports
test_herdr_close_waits_for_durable_outcome
test_retained_herdr_outcome_is_bound_to_spawn_and_endpoint
test_watcher_hook_and_idle_secondmate_exemption
test_watcher_poll_delivers_child_ledger_line_to_parent
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_missing_parent_binding_names_itself
test_reconciliation_never_calls_forge
test_reconciliation_sets_no_forge_mode_for_state_read
test_context_paused_herdr_pane_closes_without_outcome
test_event_paused_herdr_pane_stays_open
test_pause_during_state_read_supersedes_terminal_closure
test_context_paused_busy_herdr_pane_stays_open
test_captain_holds_keep_inactive_herdr_panes_open
test_captain_hold_and_pane_closure_are_serialized
test_retained_context_pause_requires_current_evidence_and_missing_pane

echo "all inactive reconciliation tests passed"
