#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch is the only control verb that changes durable records, so these
# tests pin the transaction itself, hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tasks-axi-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_remove_tree "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -f "$D/picker-on-exit" ]; then
            # Live background work: the submitting Enter that follows opens
            # Claude's "Background work is running" picker and the agent stays.
            : > "$D/exit-typed"
          else
            printf 'zsh' > "$D/command"
          fi
          if [ -f "$D/dispatch-on-exit.json" ]; then
            cp "$D/dispatch-on-exit.json" "$FM_HOME/config/crew-dispatch.json" || exit 1
          fi
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        Enter)
          if [ -f "$D/picker" ]; then
            printf 'Enter\n' >> "$D/picker-enters"
            # Enter confirms the selected row. Only "Exit and stop tasks" ends
            # the agent; "Move to background" or "Stay" would leave it alive.
            case "$(grep '^❯' "$D/picker")" in
              '❯ 1. Exit and stop tasks') printf 'zsh' > "$D/command"; : > "$D/picker-confirmed" ;;
              *) : > "$D/picker-other-row" ;;
            esac
            rm -f "$D/picker"
          elif [ -f "$D/exit-typed" ]; then
            rm -f "$D/exit-typed"
            cp "$D/picker-on-exit" "$D/picker"
          fi
          ;;
        Escape)
          if [ -f "$D/picker" ]; then
            : > "$D/picker-escaped"
            rm -f "$D/picker"
          fi
          ;;
      esac
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -f "$D/picker" ]; then cat "$D/picker"; exit 0; fi
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    [ "$(cat "$D/command")" != codex ] || printf '%s\n' '• Working (1s • esc to interrupt)'
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude or codex spawn pre-registers folder trust in the launching user's
  # own store (bin/fm-claude-trust.sh, bin/fm-codex-trust.sh), and a relaunch
  # reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json or
  # ~/.codex/config.toml.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' CODEX_HOME='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude or codex spawn pre-registers folder trust in the launching user's
  # own store (bin/fm-claude-trust.sh, bin/fm-codex-trust.sh), so it runs
  # against a throwaway HOME; without it this suite would write the developer's
  # real ~/.claude.json or ~/.codex/config.toml.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' CODEX_HOME='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# --- 1. same-harness relaunch -----------------------------------------------

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text() {
  local dir out rc
  dir=$(new_case pending-exit rl43)
  add_ship_task "$dir" rl43 claude
  printf 'i' > "$dir/fake/composer"

  out=$(run_control "$dir" rl43 relaunch --note "preserve the pending draft"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command into pending composer text"
  assert_contains "$out" "composer visibly holds pending text" \
    "the refusal should name the pending composer text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pending composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be concatenated onto pending composer text"
  pass "fm-control relaunch: pending composer text refuses before the exit command is typed"
}

test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven() {
  local dir out rc
  dir=$(new_case unproven-exit rl44)
  add_ship_task "$dir" rl44 claude

  out=$(FM_FAKE_COMPOSER_READ_FAIL=1 \
    run_control "$dir" rl44 relaunch --note "preserve on an unreadable composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the composer state cannot be proven empty"
  assert_contains "$out" "not proven empty" \
    "the refusal should name the unproven composer state, not claim pending text"
  assert_not_contains "$out" "visibly holds pending text" \
    "an unreadable composer is not the same claim as observed pending text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unproven composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the composer state is not proven empty"
  pass "fm-control relaunch: an unreadable composer fails safe before the exit command is typed"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  grep -q '^unset TRACEPARENT; .*claude' "$dir/fake/literal" \
    || fail "disabled relaunch must clear the pane carrier before replacement launch"
  ! grep -q '^export TRACEPARENT=' "$dir/fake/literal" \
    || fail "disabled relaunch must not export a replacement trace carrier"
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief launch_brief first_line role_line task_line
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  cp "$ROOT/AGENTS.md" "$dir/wt/AGENTS.md"
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  launch_brief="$dir/home/data/rl2/launch-brief.md"
  first_line=$(sed -n '1p' "$launch_brief")
  [ "$first_line" = '# Current worker role contract' ] ||
    fail "a Firstmate-worktree relaunch did not establish the crewmate identity first"
  role_line=$(grep -n '^# Current worker role contract$' "$launch_brief" | cut -d: -f1)
  task_line=$(grep -n '^# Task$' "$launch_brief" | head -1 | cut -d: -f1)
  [ "$role_line" -lt "$task_line" ] || fail "the relaunched worker identity followed its task content"
  assert_grep "$dir/home/state/rl2.inbox" "$launch_brief" \
    "the Firstmate-worktree relaunch omitted the worker's exact steering inbox"
  assert_grep 'do not reject it as another home' "$launch_brief" \
    "the Firstmate-worktree relaunch did not distinguish its inbox from cross-home state"
  pass "fm-control relaunch: progress and the Firstmate-worktree worker identity reach the replacement"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop() {
  local dir out rc id=rl-ultra
  dir=$(new_case native-ultra "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-6-astra|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(run_control "$dir" "$id" relaunch --model openai-codex/gpt-6-astra --note "invalid native effort transfer"); rc=$?
  expect_code 1 "$rc" "Ultra transferred to ordinary Pi"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "model-aware relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid Ultra relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "invalid Ultra relaunch sent lifecycle input"
  out=$(run_control "$dir" "$id" relaunch --note "preserve explicit native effort"); rc=$?
  expect_code 0 "$rc" "native Ultra relaunch failed: $out"
  [ "$(meta_field "$dir" "$id" effort)" = ultra ] || fail "relaunch lost Ultra metadata"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "relaunch lost native model"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "relaunch lost native flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "--thinking 'ultra'" "relaunch used an invalid Pi level"
  pass "native Ultra relaunch preserves its profile and rejects an unsupported model before stopping"
}

# A fake claude that answers `claude auth status` the way the real runner
# does: signed in only when the selected config root holds a stored login.
make_claude_auth_stub() {  # <case-dir>
  cat > "$1/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$1/fakebin/claude"
}

test_signed_out_worker_account_pin_refuses_before_stop() {
  local dir out rc id=rl-acct-out
  dir=$(new_case acct-out "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "account signed out"); rc=$?
  expect_code 1 "$rc" "a relaunch under a signed-out account pin must refuse"
  assert_contains "$out" "config/claude-account pins Claude workers to $dir/work, which is not signed in" \
    "the refusal should name the pin and the signed-out root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a signed-out pin must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a signed-out pin must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"
  pass "fm-control relaunch: a signed-out worker account pin refuses before the old agent stops"
}

test_worker_account_pin_follows_the_relaunch() {
  local dir out rc id=rl-acct
  dir=$(new_case acct "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(run_control "$dir" "$id" relaunch --note "pinned account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a signed-in account pin should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/work" ] || fail "the relaunched record should carry the pinned account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/work'" \
    "the replacement should launch under the pinned root"
  rm "$dir/home/config/claude-account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "pin removed"); rc=$?
  expect_code 0 "$rc" "a relaunch after the pin is removed should succeed"$'\n'"$out"
  assert_no_grep "account=" "$dir/home/state/$id.meta" "a relaunch without a pin must drop the previous account from the record"
  assert_not_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR=" \
    "an unpinned replacement must launch exactly as before"
  pass "fm-control relaunch: the replacement follows the home's current worker account pin"
}

test_pi_exclude_tools_follow_the_relaunch() {
  local dir out rc id=rl-pi-excl
  dir=$(new_case pi-exclude "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' '# hide writes' 'mcp__srv__writeTool' 'mcp__srv__adminTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "keep exclusions"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch with exclusions should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "--exclude-tools 'mcp__srv__writeTool,mcp__srv__adminTool'" \
    "the relaunched Pi worker must keep the home's tool exclusions"
  rm "$dir/home/config/crew-exclude-tools"
  : > "$dir/fake/literal"
  printf pi > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "exclusions removed"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch after the file is removed should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/literal")" "--exclude-tools" \
    "a relaunch without the file must launch with no exclusions"
  pass "fm-control relaunch: a Pi replacement keeps the home's tool exclusions"
}

test_exclude_tools_refusals_happen_before_the_agent_stops() {
  local dir out rc id=rl-excl-refuse
  dir=$(new_case excl-refuse "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' 'two words' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "bad list"); rc=$?
  expect_code 1 "$rc" "a malformed exclusion list must refuse the relaunch"
  assert_contains "$out" "config/crew-exclude-tools has a malformed entry" "refusal must name the entry"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a malformed exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  printf '%s\n' 'mcp__srv__writeTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
  expect_code 1 "$rc" "relaunching onto a runtime that cannot hide tools must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "refusal must name the config file"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an unhonorable exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  pass "fm-control relaunch: exclusion-list refusals happen before the running agent stops"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "Firstmate operational input waiting: read" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

test_secondmate_claude_relaunch_keeps_local_settings() {
  local dir home prior settings out rc
  dir=$(new_case smlocal sml)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml"
  printf 'codex\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-local-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/smhome/.claude"
  printf 'sml\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  prior='{"permissions":{"allow":["Bash(echo hi)"]}}'
  printf '%s\n' "$prior" > "$dir/smhome/.claude/settings.local.json"
  printf '%s\n' '{"feedbackDrafts":"on"}' > "$home/state/sml.claude-settings.json"
  printf 'gen=retired\n' > "$dir/smhome/.fm-busy-stop"
  {
    echo "window=fmses:fm-sml"
    echo "endpoint_task_id=sml"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml.meta"
  printf '%s\n' "fm-sml" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml relaunch); rc=$?
  expect_code 0 "$rc" "a claude secondmate relaunch should retire wiring without touching local settings"$'\n'"$out"
  settings="$dir/smhome/.claude/settings.local.json"
  [ "$(cat "$settings")" = "$prior" ] \
    || fail "relaunch rewrote the mate home's settings.local.json"
  [ ! -e "$home/state/sml.claude-settings.json" ] \
    || fail "relaunch left the retired claude settings file in place"
  [ ! -e "$dir/smhome/.fm-busy-stop" ] \
    || fail "relaunch left the retired Stop pointer in the mate home"
  pass "fm-control relaunch: a claude secondmate keeps settings.local.json and retires the state settings file and the Stop pointer"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# A promoted scout records kind=ship and a custom ship branch in its meta, but
# its brief is the scout scaffold: it never gained a Ship branch line, and a
# relaunch cannot regenerate the brief (--branch-prefix is refused there). The
# recorded branch is authoritative, so the relaunch must proceed on it.
test_spawn_relaunch_adopts_the_single_dispatch_pair() {
  local dir out
  dir=$(new_case dispatchadopt rl43)
  add_ship_task "$dir" rl43 grok
  printf 'model=grok-4.7\n' >> "$dir/home/state/rl43.meta"
  printf 'effort=medium\n' >> "$dir/home/state/rl43.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"livecheck","use":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}]}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'grok' > "$dir/fake/becomes"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl43 --relaunch)
  [ "$(meta_field "$dir" rl43 model)" = grok-4.7 ] \
    || fail "relaunch should record the dispatch file model, got '$(meta_field "$dir" rl43 model)'"
  [ "$(meta_field "$dir" rl43 effort)" = xhigh ] \
    || fail "relaunch should adopt the dispatch file effort xhigh, got '$(meta_field "$dir" rl43 effort)'"
  assert_contains "$out" "spawned rl43 harness=grok" "the relaunch should report grok"
  pass "fm-spawn --relaunch: a recorded pair matching no dispatch profile launches on the file pair and records it"
}

test_spawn_relaunch_refuses_when_the_file_offers_two_pairs() {
  local dir out rc
  dir=$(new_case dispatchmulti rl44)
  add_ship_task "$dir" rl44 grok
  printf 'model=grok-4.7\n' >> "$dir/home/state/rl44.meta"
  printf 'effort=medium\n' >> "$dir/home/state/rl44.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"livecheck","use":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}],"default":{"harness":"grok","model":"grok-4.7","effort":"high"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'grok' > "$dir/fake/becomes"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl44 --relaunch); rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch with two dispatch pairs to choose from should refuse"
  assert_contains "$out" "xhigh" "refusal did not print the first dispatch pair"
  assert_contains "$out" "high" "refusal did not print the second dispatch pair"
  [ "$(meta_field "$dir" rl44 effort)" = medium ] \
    || fail "refused relaunch should keep the recorded effort, got '$(meta_field "$dir" rl44 effort)'"
  pass "fm-spawn --relaunch: more than one dispatch pair for the harness refuses rather than guessing"
}

# The two-pair refusal has to happen on the relaunch verb, before exit. Driving
# fm-spawn --relaunch directly never stops an agent, so it cannot see this.
test_relaunch_refuses_an_ambiguous_dispatch_pair_before_the_agent_stops() {
  local dir out rc brief
  dir=$(new_case dispatchrefuse rl45)
  add_ship_task "$dir" rl45 grok
  printf 'model=grok-4.7\n' >> "$dir/home/state/rl45.meta"
  printf 'effort=medium\n' >> "$dir/home/state/rl45.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"livecheck","use":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}],"default":{"harness":"grok","model":"grok-4.7","effort":"high"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  brief=$(cat "$dir/home/data/rl45/brief.md")
  out=$(run_control "$dir" rl45 relaunch --note "keep the worker"); rc=$?
  expect_code 1 "$rc" "an ambiguous dispatch pair must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "grok-4.7 high" "the refusal must print the default pair"
  assert_contains "$out" "grok-4.7 xhigh" "the refusal must print the rule pair"
  [ "$(cat "$dir/fake/command")" = grok ] \
    || fail "a refused relaunch stopped the worker, command is $(cat "$dir/fake/command")"
  [ ! -s "$dir/fake/literal" ] \
    || fail "a refused relaunch sent lifecycle input: $(cat "$dir/fake/literal")"
  [ "$(meta_field "$dir" rl45 effort)" = medium ] \
    || fail "a refused relaunch changed the recorded effort"
  [ ! -e "$dir/home/state/rl45.control-relaunch" ] \
    || fail "a refused relaunch wrote a journal"
  [ "$(cat "$dir/home/data/rl45/brief.md")" = "$brief" ] \
    || fail "a refused relaunch rewrote the instructions"
  pass "fm-control relaunch: an ambiguous dispatch pair refuses before the worker is stopped"
}

test_relaunch_journal_records_the_adopted_dispatch_pair() {
  local dir out rc
  dir=$(new_case dispatchjournal rl46)
  add_ship_task "$dir" rl46 grok
  printf 'model=grok-4.7\n' >> "$dir/home/state/rl46.meta"
  printf 'effort=medium\n' >> "$dir/home/state/rl46.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"livecheck","use":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}]}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl46 relaunch --note "adopt the file pair"); rc=$?
  expect_code 0 "$rc" "a single dispatch pair should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" rl46 to_model)" = grok-4.7 ] \
    || fail "journal recorded to_model=$(journal_field "$dir" rl46 to_model)"
  [ "$(journal_field "$dir" rl46 to_effort)" = xhigh ] \
    || fail "journal recorded to_effort=$(journal_field "$dir" rl46 to_effort) instead of the launched pair"
  [ "$(meta_field "$dir" rl46 model)" = grok-4.7 ] \
    || fail "the task record kept model $(meta_field "$dir" rl46 model)"
  [ "$(meta_field "$dir" rl46 effort)" = xhigh ] \
    || fail "the task record kept effort $(meta_field "$dir" rl46 effort)"
  assert_contains "$out" "model=grok-4.7 effort=xhigh" \
    "the operator line must name the pair that launched"
  pass "fm-control relaunch: the journal records the dispatch pair the replacement launched"
}

test_relaunch_refuses_an_unknown_adopted_effort_before_the_agent_stops() {
  local dir out rc id=rl-adopt-typo
  dir=$(new_case dispatch-typo "$id")
  add_ship_task "$dir" "$id" grok
  printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"typo"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf grok > "$dir/fake/command"
  printf grok > "$dir/fake/becomes"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "reject the invalid adopted effort"); rc=$?
  expect_code 1 "$rc" "an unknown adopted effort must refuse: $out"
  [ "$(cat "$dir/fake/command")" = grok ] || fail "an unknown adopted effort stopped the worker"
  [ ! -s "$dir/fake/literal" ] || fail "an unknown adopted effort sent lifecycle input"
  [ ! -e "$dir/home/state/$id.control-relaunch" ] || fail "an unknown adopted effort wrote a journal"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "an unknown adopted effort changed the task record"
  assert_contains "$out" "invalid effort 'typo'" "the refusal must identify the adopted effort"
  pass "fm-control relaunch: an unknown adopted effort refuses before stopping the worker"
}

test_spawn_relaunch_refuses_an_unknown_adopted_effort() {
  local dir out rc id=rl-spawn-typo
  dir=$(new_case spawn-dispatch-typo "$id")
  add_ship_task "$dir" "$id" grok
  printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"typo"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf zsh > "$dir/fake/command"
  printf grok > "$dir/fake/becomes"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 1 "$rc" "a direct relaunch must refuse an unknown adopted effort: $out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "an unknown adopted effort launched a replacement"
  [ ! -s "$dir/fake/literal" ] || fail "an unknown adopted effort sent launch input"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "an unknown adopted effort was recorded"
  assert_contains "$out" "invalid effort 'typo'" "the refusal must identify the adopted effort"
  pass "fm-spawn --relaunch: an unknown adopted effort refuses before launch or publication"
}

test_relaunch_keeps_the_prestop_pair_when_dispatch_changes() {
  local dir out rc id=rl-dispatch-change
  dir=$(new_case dispatch-change "$id")
  add_ship_task "$dir" "$id" grok
  printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"high"}}' \
    > "$dir/fake/dispatch-on-exit.json"
  printf grok > "$dir/fake/command"
  printf grok > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --model grok-4.7 --effort xhigh --note "keep the pre-stop pair"); rc=$?
  expect_code 0 "$rc" "a changed dispatch file must not replace the control decision: $out"
  [ "$(jq -r '.default.effort' "$dir/home/config/crew-dispatch.json")" = high ] \
    || fail "the fixture did not change dispatch at the control handoff"
  [ "$(meta_field "$dir" "$id" model)" = grok-4.7 ] || fail "the replacement lost the pre-stop model"
  [ "$(meta_field "$dir" "$id" effort)" = xhigh ] || fail "the replacement lost the pre-stop effort"
  [ "$(journal_field "$dir" "$id" to_model)" = grok-4.7 ] || fail "the journal lost the pre-stop model"
  [ "$(journal_field "$dir" "$id" to_effort)" = xhigh ] || fail "the journal lost the pre-stop effort"
  [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "the control relaunch did not complete"
  [ "$(cat "$dir/fake/command")" = grok ] || fail "the replacement is not running"
  assert_contains "$(cat "$dir/fake/literal")" "--reasoning-effort 'xhigh'" "the launch lost the pre-stop effort"
  assert_not_contains "$(cat "$dir/fake/literal")" "--reasoning-effort 'high'" "the launch adopted the changed file pair"
  pass "fm-control relaunch: a dispatch change after stopping preserves the pre-stop launch pair"
}

test_spawn_relaunch_with_explicit_axes_still_adopts_the_file_pair() {
  local dir out rc id=rl-direct-axes
  dir=$(new_case direct-dispatch-axes "$id")
  add_ship_task "$dir" "$id" grok
  printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"high"}}' \
    > "$dir/home/config/crew-dispatch.json"
  printf zsh > "$dir/fake/command"
  printf grok > "$dir/fake/becomes"
  out=$(run_spawn "$dir" "$id" --relaunch --harness grok --model grok-4.7 --effort xhigh); rc=$?
  expect_code 0 "$rc" "a direct relaunch must still adopt the sole file pair: $out"
  [ "$(meta_field "$dir" "$id" model)" = grok-4.7 ] || fail "a direct relaunch lost the adopted model"
  [ "$(meta_field "$dir" "$id" effort)" = high ] || fail "a direct relaunch skipped dispatch adoption"
  assert_contains "$(cat "$dir/fake/literal")" "--reasoning-effort 'high'" "a direct relaunch did not launch the adopted effort"
  pass "fm-spawn --relaunch: explicit axes without a control handoff still adopt the sole file pair"
}

test_relaunch_validates_the_adopted_profile_before_the_agent_stops() {
  local dir out rc check id
  for check in pin effort; do
    id="rl-adopt-$check"
    dir=$(new_case "dispatch-$check" "$id")
    add_ship_task "$dir" "$id" pi
    printf 'model=anthropic/claude-sonnet-4-6\neffort=high\n' >> "$dir/home/state/$id.meta"
    printf pi > "$dir/fake/command"
    printf pi > "$dir/fake/becomes"
    cat > "$dir/fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ]; then
  printf '%s\n' '{"status":"ready"}'
else
  printf 'Options: --tui-mode\n'
fi
SH
    chmod +x "$dir/fakebin/pi"
    mkdir -p "$dir/home/config" "$dir/account"
    printf '%s\n' "$dir/account" anthropic > "$dir/home/config/pi-account"
    if [ "$check" = pin ]; then
      printf '%s\n' '{"default":{"harness":"pi","model":"codex-native/gpt-6-astra","effort":"high"}}'
    else
      printf '%s\n' '{"default":{"harness":"pi","model":"anthropic/claude-sonnet-4-6","effort":"ultra"}}'
    fi > "$dir/home/config/crew-dispatch.json"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    out=$(run_control "$dir" "$id" relaunch --note "validate the adopted pair"); rc=$?
    expect_code 1 "$rc" "an invalid adopted $check must refuse before stopping: $out"
    assert_contains "$out" "adopts the dispatch file pair" "the recorded profile did not reach dispatch adoption"
    if [ "$check" = pin ]; then
      assert_contains "$out" "names provider 'codex-native'" "the adopted provider must fail the account pin"
    else
      assert_contains "$out" "ultra effort requires pi or pi-signed" "the adopted effort must fail native validation"
    fi
    [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid adopted $check stopped the running worker"
    [ ! -s "$dir/fake/literal" ] || fail "invalid adopted $check sent lifecycle input"
    [ ! -e "$dir/home/state/$id.control-relaunch" ] || fail "invalid adopted $check wrote a relaunch journal"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "invalid adopted $check changed the task record"
  done
  pass "fm-control relaunch: adopted profiles pass account and native-effort checks before stopping"
}

test_relaunch_preserves_explicit_default_resets() {
  local dir out rc reset id model effort literal
  local -a reset_args
  for reset in both model effort adopted; do
    id="rl-reset-$reset"
    dir=$(new_case "dispatch-reset-$reset" "$id")
    add_ship_task "$dir" "$id" grok
    printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    printf '%s\n' '{"default":[{"harness":"grok"},{"harness":"grok","effort":"xhigh"},{"harness":"grok","model":"grok-4.7"},{"harness":"grok","model":"grok-4.7","effort":"xhigh"}]}' \
      > "$dir/home/config/crew-dispatch.json"
    model=grok-4.7 effort=xhigh
    case "$reset" in
      both) reset_args=(--model default --effort default); model=default effort=default ;;
      model) reset_args=(--model=default); model=default ;;
      effort) reset_args=(--effort=default); effort=default ;;
      adopted)
        reset_args=(--model default --effort default)
        printf '%s\n' '{"default":{"harness":"grok","model":"grok-4.7","effort":"xhigh"}}' \
          > "$dir/home/config/crew-dispatch.json"
        ;;
    esac
    printf grok > "$dir/fake/command"
    printf grok > "$dir/fake/becomes"
    out=$(run_control "$dir" "$id" relaunch "${reset_args[@]}" --note "reset $reset"); rc=$?
    expect_code 0 "$rc" "a $reset reset should relaunch on the resolved pair: $out"
    [ "$(cat "$dir/fake/command")" = grok ] || fail "$reset reset left no replacement running"
    [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "$reset reset did not complete"
    [ "$(journal_field "$dir" "$id" to_model)" = "$model" ] || fail "$reset reset journal lost the model"
    [ "$(journal_field "$dir" "$id" to_effort)" = "$effort" ] || fail "$reset reset journal lost the effort"
    [ "$(meta_field "$dir" "$id" model)" = "$model" ] || fail "$reset reset restored the recorded model"
    [ "$(meta_field "$dir" "$id" effort)" = "$effort" ] || fail "$reset reset restored the recorded effort"
    assert_contains "$out" "model=$model effort=$effort" "the result must report the resolved pair"
    literal=$(cat "$dir/fake/literal")
    assert_not_contains "$literal" "'default'" "a reset token reached the launch command"
    if [ "$model" = default ]; then
      assert_not_contains "$literal" "--model " "a model reset must omit the harness flag"
    else
      assert_contains "$literal" "--model '$model'" "a reset lost the resolved model flag"
    fi
    if [ "$effort" = default ]; then
      assert_not_contains "$literal" "--reasoning-effort " "an effort reset must omit the harness flag"
    else
      assert_contains "$literal" "--reasoning-effort '$effort'" "a reset lost the resolved effort flag"
    fi
  done
  pass "fm-control relaunch: full and partial default resets preserve the resolved pair through launch"
}

test_relaunch_refuses_unmatched_partial_resets_before_stopping() {
  local dir out rc axis id
  for axis in model effort; do
    id="rl-partial-$axis"
    dir=$(new_case "dispatch-partial-$axis" "$id")
    add_ship_task "$dir" "$id" grok
    printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    printf '%s\n' '{"default":[{"harness":"grok"},{"harness":"grok","model":"grok-4.7","effort":"xhigh"}]}' \
      > "$dir/home/config/crew-dispatch.json"
    printf grok > "$dir/fake/command"
    printf grok > "$dir/fake/becomes"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    out=$(run_control "$dir" "$id" relaunch "--$axis" default --note "refuse unmatched reset"); rc=$?
    expect_code 1 "$rc" "an unmatched $axis reset must refuse: $out"
    assert_contains "$out" "matches no dispatch profile" "the partial reset must reach pair matching"
    assert_contains "$out" "default default" "the refusal must list the default pair"
    assert_contains "$out" "grok-4.7 xhigh" "the refusal must list the concrete pair"
    [ "$(cat "$dir/fake/command")" = grok ] || fail "unmatched $axis reset stopped the worker"
    [ ! -s "$dir/fake/literal" ] || fail "unmatched $axis reset sent lifecycle input"
    [ ! -e "$dir/home/state/$id.control-relaunch" ] || fail "unmatched $axis reset wrote a journal"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "unmatched $axis reset changed the record"
  done
  pass "fm-control relaunch: unmatched partial resets refuse before stopping the worker"
}

test_relaunch_default_resets_without_named_dispatch_profiles() {
  local dir out rc config id literal
  for config in absent unnamed; do
    id="rl-exempt-$config"
    dir=$(new_case "reset-$config" "$id")
    add_ship_task "$dir" "$id" grok
    printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
    if [ "$config" = unnamed ]; then
      mkdir -p "$dir/home/config"
      printf '%s\n' '{"default":{"harness":"codex","model":"gpt-6-astra","effort":"xhigh"}}' \
        > "$dir/home/config/crew-dispatch.json"
    fi
    printf grok > "$dir/fake/command"
    printf grok > "$dir/fake/becomes"
    out=$(run_control "$dir" "$id" relaunch --model default --effort default --note "reset without a named pair"); rc=$?
    expect_code 0 "$rc" "resets should work with $config dispatch profiles: $out"
    [ "$(meta_field "$dir" "$id" model)" = default ] || fail "$config dispatch reset lost the default model"
    [ "$(meta_field "$dir" "$id" effort)" = default ] || fail "$config dispatch reset lost the default effort"
    [ "$(journal_field "$dir" "$id" to_model)" = default ] || fail "$config dispatch journal lost the default model"
    [ "$(journal_field "$dir" "$id" to_effort)" = default ] || fail "$config dispatch journal lost the default effort"
    literal=$(cat "$dir/fake/literal")
    assert_not_contains "$literal" "'default'" "an exempt reset token reached the launch command"
    assert_not_contains "$literal" "--model " "an exempt model reset must omit the flag"
    assert_not_contains "$literal" "--reasoning-effort " "an exempt effort reset must omit the flag"
  done
  pass "fm-control relaunch: defaults reset with an absent dispatch file or an unnamed harness"
}

test_spawn_relaunch_without_profile_flags_inherits_the_recorded_pair() {
  local dir out rc config id literal
  for config in named absent unnamed; do
    id="rl-inherit-$config"
    dir=$(new_case "inherit-$config" "$id")
    add_ship_task "$dir" "$id" grok
    printf 'model=grok-4.7\neffort=xhigh\n' >> "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    case "$config" in
      named)
        printf '%s\n' '{"default":[{"harness":"grok"},{"harness":"grok","model":"grok-4.7","effort":"xhigh"}]}' \
          > "$dir/home/config/crew-dispatch.json"
        ;;
      unnamed)
        printf '%s\n' '{"default":{"harness":"codex","model":"gpt-6-astra","effort":"xhigh"}}' \
          > "$dir/home/config/crew-dispatch.json"
        ;;
    esac
    printf zsh > "$dir/fake/command"
    printf grok > "$dir/fake/becomes"
    out=$(run_spawn "$dir" "$id" --relaunch); rc=$?
    expect_code 0 "$rc" "an omitted profile should inherit with $config dispatch profiles: $out"
    [ "$(meta_field "$dir" "$id" model)" = grok-4.7 ] || fail "$config dispatch lost the inherited model"
    [ "$(meta_field "$dir" "$id" effort)" = xhigh ] || fail "$config dispatch lost the inherited effort"
    literal=$(cat "$dir/fake/literal")
    assert_contains "$literal" "--model 'grok-4.7'" "the launch lost the inherited model"
    assert_contains "$literal" "--reasoning-effort 'xhigh'" "the launch lost the inherited effort"
  done
  pass "fm-spawn --relaunch: omitted profile flags keep the recorded pair"
}

test_spawn_rejects_fresh_default_resets_and_empty_profile_values() {
  local dir out rc axis
  for axis in model effort; do
    dir=$(new_case "invalid-reset-$axis" "rl-invalid-$axis")
    out=$(run_spawn "$dir" "rl-invalid-$axis" "$dir/proj" --scout --harness grok "--$axis" default); rc=$?
    expect_code 1 "$rc" "a fresh --$axis default must refuse"
    assert_contains "$out" "resets require --relaunch" "a fresh default reset must name the relaunch restriction"
    out=$(run_spawn "$dir" "rl-invalid-$axis" --relaunch "--$axis" ''); rc=$?
    expect_code 1 "$rc" "an empty --$axis value must refuse"
    assert_contains "$out" "--$axis requires a non-empty value" "an empty profile value was accepted"
    out=$(run_spawn "$dir" "rl-invalid-$axis" --relaunch "--$axis="); rc=$?
    expect_code 1 "$rc" "an empty --$axis= value must refuse"
    assert_contains "$out" "--$axis requires a non-empty value" "an empty equals profile value was accepted"
    [ ! -s "$dir/fake/literal" ] || fail "an invalid $axis value sent lifecycle input"
    [ ! -e "$dir/home/state/rl-invalid-$axis.meta" ] || fail "an invalid $axis value published a task record"
  done
  pass "fm-spawn: default resets require relaunch and empty profile values remain illegal"
}

test_relaunch_refuses_an_unreadable_dispatch_file_before_the_agent_stops() {
  local dir out rc
  dir=$(new_case dispatchbad rl47)
  add_ship_task "$dir" rl47 grok
  printf 'model=grok-4.7\n' >> "$dir/home/state/rl47.meta"
  printf 'effort=xhigh\n' >> "$dir/home/state/rl47.meta"
  mkdir -p "$dir/home/config"
  printf '%s\n' '{' > "$dir/home/config/crew-dispatch.json"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl47 relaunch --note "bad file"); rc=$?
  expect_code 1 "$rc" "a malformed dispatch file must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "parse error" "the refusal must include jq's parse diagnostic"
  assert_contains "$out" "line 2" "the refusal must include the line jq names"
  assert_contains "$out" "could not read its dispatch profiles" "the refusal must name the file"
  [ "$(cat "$dir/fake/command")" = grok ] \
    || fail "a malformed dispatch file stopped the worker, command is $(cat "$dir/fake/command")"
  [ ! -s "$dir/fake/literal" ] \
    || fail "a malformed dispatch file sent lifecycle input: $(cat "$dir/fake/literal")"
  pass "fm-control relaunch: a malformed dispatch file refuses before the worker stops and shows where it is broken"
}

test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch() {
  local dir out
  dir=$(new_case promotebranch rl42)
  add_ship_task "$dir" rl42 claude
  printf 'branch=fix/rl42\n' >> "$dir/home/state/rl42.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl42 --relaunch)
  assert_contains "$out" "spawned rl42" "the relaunch should complete on the recorded branch"
  assert_contains "$out" "records no ship branch" "the brief gap should be reported, not silent"
  assert_contains "$out" "recorded branch fix/rl42" "the relaunch should name the branch it adopted"
  [ "$(meta_field "$dir" rl42 branch)" = "fix/rl42" ] \
    || fail "the recorded branch must survive the relaunch"
  pass "fm-spawn --relaunch: a promoted scout with a recorded custom branch relaunches on it instead of being refused"
}

test_promoted_scout_relaunch_receives_the_current_delivery_contract() {
  local dir home id brief launch out mode rule
  for mode in no-mistakes direct-PR local-only; do
    id="rl-promoted-${mode}"
    dir=$(new_case "promoted-scout-$mode" "$id")
    home="$dir/home"
    fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
    FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
      || fail "$mode: could not scaffold the scout brief"
    brief="$home/data/$id/brief.md"
    sed 's/{TASK}/Fix the promotion relaunch contract./; s/{FIRSTMATE_SPEC}/Preserve the current delivery mode./' \
      "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$dir/wt"
      echo "project=$dir/proj"
      echo "harness=claude"
      echo "kind=scout"
      echo "tasktmp=/tmp/fm-$id"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"

    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: scout promotion should succeed: $out"
    assert_grep 'This is a SCOUT task' "$brief" \
      "$mode: the reproduction fixture lost the original scout delivery text"
    assert_grep 'Never push to any remote and never open a PR' "$brief" \
      "$mode: the reproduction fixture lost the stale scout prohibition"

    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$mode: promoted scout relaunch should succeed: $out"
    launch="$home/data/$id/launch-brief.md"
    assert_grep "This task is now kind=ship with mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the promoted task identity"
    assert_grep 'Any earlier "Never push" or scout-only delivery language in this file is superseded' "$launch" \
      "$mode: the replacement launch left the stale scout prohibition readable at face value"
    case "$mode" in
      direct-PR)
        rule="1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR." ;;
      local-only)
        rule="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`." ;;
      *)
        rule='1. Never push to the default branch. Never merge a PR.' ;;
    esac
    assert_grep "$rule" "$launch" \
      "$mode: the replacement launch did not receive the current ship push and merge safety rule"
    assert_grep "git switch -c fm/$id" "$launch" \
      "$mode: the replacement launch did not receive its promoted branch name"
    assert_grep 'Inventory this worktree' "$launch" \
      "$mode: the replacement launch did not receive the scratch-state inventory step"
    assert_grep 'Carry over only the intended fix changes' "$launch" \
      "$mode: the replacement launch did not receive the carry-over boundary"
    assert_grep "Delivery contract: mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the actual ship delivery mode"
  done
  pass "fm-promote/fm-spawn --relaunch: the current ship contract supersedes stale scout delivery text"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# codex_limit_session <case-dir> <id>: the task's current launch, ten minutes
# ago, ran codex in its worktree and the session's last turn ended on the usage
# limit, in the rollout shape codex-cli 0.163 persists.
codex_limit_session() {
  local dir=$1 id=$2 f
  printf 'spawn_gen=s%s.1.1\n' "$(( $(date +%s) - 600 ))" >> "$dir/home/state/$id.meta"
  f="$dir/user-home/.codex/sessions/2026/10/21/rollout-2026-10-21T10-00-00-01a0c0de-0000-7000-8000-000000000001.jsonl"
  mkdir -p "${f%/*}"
  jq -nc --arg cwd "$dir/wt" '{type:"session_meta",payload:{id:"01a0c0de-0000-7000-8000-000000000001",cwd:$cwd,cli_version:"0.163.0"}}' > "$f"
  jq -nc '{type:"event_msg",payload:{type:"task_complete",turn_id:"t1",last_agent_message:null,error:{message:"You have hit your usage limit.",codex_error_info:"usage_limit_exceeded"}}}' >> "$f"
}

test_raw_relaunch_preserves_retiring_codex_limit_for_later_routes() {
  local dir out rc gen_before
  dir=$(new_case rawcodexlimit rl80)
  add_ship_task "$dir" rl80 codex-client
  codex_limit_session "$dir" rl80
  gen_before=$(meta_field "$dir" rl80 spawn_gen)
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl80 --relaunch --harness 'claude-client --model sonnet'); rc=$?
  expect_code 0 "$rc" "a raw Claude override should keep its launch command"$'\n'"$out"
  assert_contains "$out" "spawned rl80 harness=claude-client" "the raw override must keep its executable identity"
  assert_contains "$(cat "$dir/fake/literal")" "claude-client --model sonnet" "the raw command must be preserved"
  [ "$(meta_field "$dir" rl80 harness)" = claude-client ] || fail "the raw override must record its executable identity"
  [ "$(meta_field "$dir" rl80 spawn_gen)" != "$gen_before" ] || fail "the raw relaunch must replace the generation"
  [ "$(cat "$dir/home/state/rl80.codex-limit" 2>/dev/null)" = "codex run for rl80 hit its usage limit: You have hit your usage limit." ] \
    || fail "the raw override must preserve the retiring Codex limit before replacing its generation"

  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl80 --relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "a later canonical Codex relaunch should follow the preserved limit"$'\n'"$out"
  assert_contains "$out" "spawned rl80 harness=claude" "the later Codex relaunch must route to Claude"
  [ "$(meta_field "$dir" rl80 harness)" = claude ] || fail "the later relaunch must record Claude"
  [ "$(meta_field "$dir" rl80 effort)" = xhigh ] || fail "the later relaunch must use the routed effort"
  pass "fm-spawn --relaunch: a raw override preserves the retiring Codex limit for later canonical routes"
}

test_raw_relaunch_refuses_route_changes_without_replacing_generation() {
  local dir id harness route out rc before raw executable
  for raw in 'cursor-agent --trust' 'codex --model custom' 'codex-client --model custom' 'cursor --model custom'; do
    executable=${raw%% *}
    case "$executable" in
      cursor|cursor-agent) harness=cursor ;;
      *) harness=codex ;;
    esac
    id="rl81-$executable"
    dir=$(new_case "rawroute-$harness" "$id")
    add_ship_task "$dir" "$id" "$harness"
    printf 'spawn_gen=s%s.1.1\n' "$(( $(date +%s) - 600 ))" >> "$dir/home/state/$id.meta"
    if [ "$harness" = codex ]; then
      route=claude
      printf 'codex run hit its usage limit\n' > "$dir/home/state/$id.codex-limit"
    else
      route=codex
      mkdir -p "$dir/user-home/.agent-state/a3ov3/cursor-usage"
      printf 'cursor_models_pct=90\n' > "$dir/user-home/.agent-state/a3ov3/cursor-usage/test-spending.txt"
    fi
    before=$(cat "$dir/home/state/$id.meta")
    printf 'zsh' > "$dir/fake/command"
    out=$(FM_CURSOR_USAGE_DIR="$dir/user-home/.agent-state/a3ov3/cursor-usage" \
      run_spawn "$dir" "$id" --relaunch --harness "$raw"); rc=$?
    expect_code 1 "$rc" "a raw $harness command must refuse a route to $route"$'\n'"$out"
    assert_contains "$out" "route to $route" "the refusal must name the selected harness"
    assert_contains "$out" "canonical --harness $harness" "the refusal must request a canonical launch"
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "a raw route refusal must preserve the record and generation"
    [ ! -s "$dir/fake/literal" ] || fail "a raw route refusal must not send a launch command"
    [ ! -s "$dir/fake/keys" ] || fail "a raw route refusal must not prepare the endpoint"
    [ "$(cat "$dir/fake/command")" = zsh ] || fail "a raw route refusal must not start an agent"
  done
  pass "fm-spawn --relaunch: raw Codex and Cursor commands refuse changed routes without replacing the task generation"
}

test_raw_cursor_family_is_kept_when_usage_is_healthy() {
  local dir out rc
  dir=$(new_case rawcursorhealthy rl83)
  add_ship_task "$dir" rl83 cursor
  mkdir -p "$dir/user-home/.agent-state/a3ov3/cursor-usage"
  printf 'cursor_models_pct=10\n' > "$dir/user-home/.agent-state/a3ov3/cursor-usage/test-spending.txt"
  printf 'zsh' > "$dir/fake/command"
  out=$(FM_CURSOR_USAGE_DIR="$dir/user-home/.agent-state/a3ov3/cursor-usage" \
    run_spawn "$dir" rl83 --relaunch --harness 'cursor-agent --trust'); rc=$?
  expect_code 0 "$rc" "a healthy raw Cursor command must keep its family"$'\n'"$out"
  assert_contains "$out" "spawned rl83 harness=cursor-agent" "the raw executable identity must be preserved"
  assert_contains "$(cat "$dir/fake/literal")" "cursor-agent --trust" "the raw Cursor command must be preserved"
  [ "$(meta_field "$dir" rl83 harness)" = cursor-agent ] || fail "the record must keep the raw executable identity"
  [ ! -e "$dir/home/state/rl83.cursor-fallback" ] || fail "keeping the Cursor family must not record an override"
  pass "fm-spawn --relaunch: healthy raw Cursor keeps its command and executable identity without an override"
}

test_raw_cursor_override_is_recorded() {
  local dir out rc
  dir=$(new_case rawcursoroverride rl82)
  add_ship_task "$dir" rl82 cursor
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl82 --relaunch --harness 'claude --model sonnet'); rc=$?
  expect_code 0 "$rc" "a raw override of Cursor should keep its launch command"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "claude --model sonnet" "the raw override must be preserved"
  [ "$(meta_field "$dir" rl82 harness)" = claude ] || fail "the raw override must record Claude"
  [ "$(cat "$dir/home/state/rl82.cursor-fallback" 2>/dev/null)" = "explicit --harness claude override of a recorded cursor task" ] \
    || fail "a raw override must record the Cursor replacement"
  pass "fm-spawn --relaunch: a raw Cursor override records its replacement harness"
}

test_control_relaunch_of_a_usage_limited_codex_task_lands_on_claude() {
  local dir out rc
  dir=$(new_case codexlimit rl73)
  add_ship_task "$dir" rl73 codex
  codex_limit_session "$dir" rl73
  printf 'codex' > "$dir/fake/command"
  out=$(run_control "$dir" rl73 relaunch --note "codex hit its usage limit"); rc=$?
  expect_code 0 "$rc" "relaunching a usage-limited codex task should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl73 harness=claude from=codex" "the outcome should name the claude replacement"
  [ "$(meta_field "$dir" rl73 harness)" = claude ] || fail "the record should name claude, got '$(meta_field "$dir" rl73 harness)'"
  [ "$(meta_field "$dir" rl73 effort)" = xhigh ] || fail "the claude replacement should run at xhigh, got '$(meta_field "$dir" rl73 effort)'"
  [ "$(journal_field "$dir" rl73 to_harness)" = claude ] || fail "the journal should name claude as the target"
  [ "$(cat "$dir/home/state/rl73.codex-limit" 2>/dev/null)" = "codex run for rl73 hit its usage limit: You have hit your usage limit." ] \
    || fail "the usage-limit stop must be recorded in state/<id>.codex-limit: $(cat "$dir/home/state/rl73.codex-limit" 2>&1)"
  pass "fm-control relaunch: a codex task whose session ended on its usage limit is relaunched on claude and marked"
}

test_usage_limit_route_to_claude_is_exempt_from_the_claude_dispatch_pairs() {
  local dir out rc route_fallback
  dir=$(new_case codexlimitpairs rl79)
  add_ship_task "$dir" rl79 codex
  codex_limit_session "$dir" rl79
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"review","use":{"harness":"claude","model":"opus","effort":"high"}}],"default":[{"harness":"codex"},{"harness":"claude","model":"sonnet","effort":"medium"}]}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'codex' > "$dir/fake/command"
  out=$(run_control "$dir" rl79 relaunch --note "codex hit its usage limit"); rc=$?
  expect_code 0 "$rc" "a usage-limit route to claude must not be refused by the claude dispatch pairs"$'\n'"$out"
  assert_contains "$out" "relaunched rl79 harness=claude from=codex" "the outcome should name the claude replacement"
  [ "$(meta_field "$dir" rl79 model)" = default ] || fail "the claude replacement should run the default model, got '$(meta_field "$dir" rl79 model)'"
  [ "$(meta_field "$dir" rl79 effort)" = xhigh ] || fail "the claude replacement should run at xhigh, got '$(meta_field "$dir" rl79 effort)'"
  route_fallback=$(meta_field "$dir" rl79 route_fallback)
  out=$(run_control "$dir" rl79 relaunch --note "continue on the fallback profile"); rc=$?
  expect_code 0 "$rc" "an ordinary relaunch must keep the recorded fallback pair"$'\n'"$out"
  assert_contains "$out" "relaunched rl79 harness=claude from=claude model=default effort=xhigh" "the next relaunch must keep the fallback profile"
  [ "$route_fallback" = 1 ] || fail "the first routed launch must record its fallback profile"
  [ "$(meta_field "$dir" rl79 harness)" = claude ] || fail "the next relaunch must keep claude"
  [ "$(meta_field "$dir" rl79 model)" = default ] || fail "the next relaunch must keep the default model"
  [ "$(meta_field "$dir" rl79 effort)" = xhigh ] || fail "the next relaunch must keep xhigh"
  [ "$(meta_field "$dir" rl79 route_fallback)" = 1 ] || fail "keeping the fallback pair must carry its provenance"

  out=$(run_control "$dir" rl79 relaunch --effort high --note "request an unmatched pair"); rc=$?
  expect_code 1 "$rc" "fallback provenance must not exempt a different pair"$'\n'"$out"
  assert_contains "$out" "matches no dispatch profile" "an unmatched change must still refuse"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the unmatched change must not stop the agent"
  [ "$(meta_field "$dir" rl79 effort)" = xhigh ] || fail "a refusal must keep the recorded fallback pair"

  out=$(run_control "$dir" rl79 relaunch --model opus --effort high --note "choose a named profile"); rc=$?
  expect_code 0 "$rc" "an explicit named pair must still relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" rl79 model)" = opus ] || fail "the explicit model must be recorded"
  [ "$(meta_field "$dir" rl79 effort)" = high ] || fail "the explicit effort must be recorded"
  [ -z "$(meta_field "$dir" rl79 route_fallback)" ] || fail "choosing another pair must clear fallback provenance"
  pass "fm-control relaunch: a routed fallback pair survives the next relaunch and only that pair is exempt"
}

test_spawn_relaunch_of_a_marked_codex_task_lands_on_claude() {
  local dir out rc
  dir=$(new_case codexmarked rl74)
  add_ship_task "$dir" rl74 codex
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"default":[{"harness":"codex"},{"harness":"claude","model":"sonnet","effort":"medium"}]}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'codex run for rl74 hit its usage limit\n' > "$dir/home/state/rl74.codex-limit"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl74 --relaunch)
  assert_contains "$out" "spawned rl74 harness=claude" "a marked codex task must relaunch on claude"$'\n'"$out"
  [ "$(meta_field "$dir" rl74 harness)" = claude ] || fail "the record should name claude, got '$(meta_field "$dir" rl74 harness)'"
  [ "$(meta_field "$dir" rl74 effort)" = xhigh ] || fail "the claude replacement should run at xhigh"
  [ "$(meta_field "$dir" rl74 route_fallback)" = 1 ] || fail "the direct fallback must record its provenance"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl74 --relaunch); rc=$?
  expect_code 0 "$rc" "the direct relaunch must keep its fallback pair"$'\n'"$out"
  [ "$(meta_field "$dir" rl74 model)" = default ] || fail "a fallback pair must not adopt the file's single model"
  [ "$(meta_field "$dir" rl74 effort)" = xhigh ] || fail "a fallback pair must not adopt the file's single effort"
  [ "$(meta_field "$dir" rl74 route_fallback)" = 1 ] || fail "the direct relaunch must carry fallback provenance"

  printf 'zsh' > "$dir/fake/command"
  out=$(FM_CONTROL_ROUTE_FALLBACK=1 run_spawn "$dir" rl74 --relaunch --effort high); rc=$?
  expect_code 0 "$rc" "a changed pair must still adopt the single file pair"$'\n'"$out"
  [ "$(meta_field "$dir" rl74 model)" = sonnet ] || fail "the fallback must not count as another adoption candidate"
  [ "$(meta_field "$dir" rl74 effort)" = medium ] || fail "the adopted effort must be recorded"
  [ -z "$(meta_field "$dir" rl74 route_fallback)" ] || fail "adopting another pair must clear provenance and ignore an untrusted control handoff"
  pass "fm-spawn --relaunch: fallback pairs survive relaunch and do not change single-pair adoption"
}

test_control_relaunch_of_a_cursor_task_records_the_harness_it_launched() {
  local dir out rc
  dir=$(new_case cursorroute rl75)
  add_ship_task "$dir" rl75 cursor
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"review","use":{"harness":"codex","model":"gpt-5","effort":"high"}}],"default":[{"harness":"cursor"},{"harness":"codex","model":"gpt-5","effort":"medium"}]}' \
    > "$dir/home/config/crew-dispatch.json"
  printf 'cursor-agent' > "$dir/fake/command"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl75 relaunch --note "cursor pool unknown"); rc=$?
  expect_code 0 "$rc" "relaunching a cursor task with no usage evidence should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl75 harness=codex from=cursor" "the outcome should name the harness actually launched"
  [ "$(meta_field "$dir" rl75 harness)" = codex ] || fail "the record should name codex, got '$(meta_field "$dir" rl75 harness)'"
  [ "$(journal_field "$dir" rl75 to_harness)" = codex ] || fail "the journal should name the harness actually launched, got '$(journal_field "$dir" rl75 to_harness)'"
  assert_contains "$(cat "$dir/home/state/rl75.cursor-fallback" 2>/dev/null)" "no Cursor spending file" "the fallback reason should be recorded"
  [ "$(meta_field "$dir" rl75 route_fallback)" = 1 ] || fail "the Cursor fallback must record its provenance"
  out=$(run_control "$dir" rl75 relaunch --note "continue on codex"); rc=$?
  expect_code 0 "$rc" "a Cursor fallback pair must remain eligible on codex"$'\n'"$out"
  assert_contains "$out" "relaunched rl75 harness=codex from=codex model=default effort=xhigh" "the next relaunch must keep the Cursor fallback pair"
  [ "$(meta_field "$dir" rl75 route_fallback)" = 1 ] || fail "the next relaunch must carry Cursor fallback provenance"
  pass "fm-control relaunch: a cursor fallback records the actual harness and keeps its pair on the next relaunch"
}

test_explicit_override_of_a_cursor_task_is_recorded() {
  local dir out rc
  dir=$(new_case cursoroverride rl76)
  add_ship_task "$dir" rl76 cursor
  printf 'cursor-agent' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl76 relaunch --harness grok --note "operator moved it"); rc=$?
  expect_code 0 "$rc" "an explicit override relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl76 harness)" = grok ] || fail "the explicit harness must be kept"
  [ "$(cat "$dir/home/state/rl76.cursor-fallback" 2>/dev/null)" = "explicit --harness grok override of a recorded cursor task" ] \
    || fail "fm-control relaunch must record an explicit override of a cursor task: $(cat "$dir/home/state/rl76.cursor-fallback" 2>&1)"

  dir=$(new_case cursoroverridespawn rl77)
  add_ship_task "$dir" rl77 cursor
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl77 --relaunch --harness grok)
  assert_contains "$out" "spawned rl77 harness=grok" "the explicit harness must be kept"$'\n'"$out"
  [ "$(cat "$dir/home/state/rl77.cursor-fallback" 2>/dev/null)" = "explicit --harness grok override of a recorded cursor task" ] \
    || fail "fm-spawn --relaunch must record an explicit override of a cursor task: $(cat "$dir/home/state/rl77.cursor-fallback" 2>&1)"
  pass "an explicit --harness relaunch of a cursor task is kept and recorded in state/<id>.cursor-fallback"
}

test_spawn_relaunch_keeps_the_recorded_profile_axes() {
  local dir out
  dir=$(new_case spawnprofile rl78)
  add_ship_task "$dir" rl78 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl78.meta" > "$dir/home/state/rl78.meta.tmp"
  mv "$dir/home/state/rl78.meta.tmp" "$dir/home/state/rl78.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl78 --relaunch)
  assert_contains "$out" "spawned rl78 harness=claude" "the relaunch should keep the recorded harness"$'\n'"$out"
  [ "$(meta_field "$dir" rl78 model)" = opus ] || fail "an omitted --model must keep the recorded model, got '$(meta_field "$dir" rl78 model)'"
  [ "$(meta_field "$dir" rl78 effort)" = high ] || fail "an omitted --effort must keep the recorded effort, got '$(meta_field "$dir" rl78 effort)'"
  pass "fm-spawn --relaunch: omitted --model and --effort keep the recorded axes"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable child records fail checkpoint"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-control relaunch: unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  rmdir "$dir/smhome/state/bad.meta"
  printf 'window=x:c1\n' > "$dir/smhome/state/c1.meta"
  chmod 000 "$dir/smhome/state"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  chmod 755 "$dir/smhome/state"
  expect_code 1 "$rc" "an unlistable state directory should refuse"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "unlistable child state must not stop the secondmate"
  pass "fm-control relaunch: unlistable state fails checkpoint"
}

test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk() {
  local dir home out rc real_find
  dir=$(new_case smfindrace sm6)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  : > "$dir/smhome/state/.hash-0"
  : > "$dir/smhome/state/.count-0"
  : > "$dir/smhome/state/.last-0"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smhome/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched sm6" "readable child metas must still allow the replacement launch"
  [ "$(journal_field "$dir" sm6 children)" = 2 ] \
    || fail "readable child metas must still be counted, got '$(journal_field "$dir" sm6 children)'"
  pass "fm-control relaunch: a vanished watcher scratch file does not fail the child-record checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  printf 'held\n' > "$dir/home/state/rl19.composer-dialog"
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  [ "$(cat "$dir/home/state/rl19.composer-dialog" 2>/dev/null)" = held ] \
    || fail "a refused concurrent relaunch must not remove the lock holder's dialog file"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the lifecycle lock"
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the promotion lifecycle lock"
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  [ ! -s "$dir/fake/keys" ] || fail "a refused tmux relaunch must send nothing to the pane"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding its work"
}

# --- 7. reclaiming a task whose endpoint is gone ----------------------------
#
# Before this, `missing` was a terminal state: fm-spawn --relaunch accepted only
# `dead` and told the caller to stop the agent first, while fm-control exit
# refused `missing` outright and told the caller to reconcile the task first -
# and there is no reconcile verb. Each command named the other as its
# prerequisite, so a task whose pane or workspace was destroyed could not be
# reclaimed by anything, and any no-mistakes approval it was parked on had no
# seat left to answer it.

# strand_endpoint <case-dir> <id>: make a tmux endpoint read `missing` the way
# a destroyed window does - a successful session inventory that omits the exact
# window.
strand_endpoint() {  # <case-dir> <id>
  : > "$1/fake/windows"
}

# Every tmux `missing` refuses on BOTH verbs, whatever produced it. tmux is the
# one verified backend whose absence cannot be proven from a task record: the
# record carries no socket identity for the endpoint, and any inventory
# describes only the server this process happens to address. So a window that
# is merely on a server this seat cannot reach is indistinguishable from one
# that was destroyed, and neither verb will guess.
assert_tmux_missing_refuses() {  # <case-dir> <id> <what-was-staged>
  local dir=$1 id=$2 what=$3 out rc brief_before

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_absent "$dir/fake/created-windows" "a refused relaunch must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused relaunch must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must send nothing into any pane ($what)"

  brief_before=$(cat "$dir/home/data/$id/brief.md")
  out=$(run_control "$dir" "$id" exit); rc=$?
  expect_code 1 "$rc" "exit must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_not_contains "$out" "endpoint-gone" \
    "exit must not report a stop it cannot see ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused exit must send nothing into any pane ($what)"

  out=$(run_control "$dir" "$id" relaunch --note "this note must never reach a live agent"); rc=$?
  expect_code 1 "$rc" "the relaunch transaction must fail closed ($what)"$'\n'"$out"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused relaunch edited instructions an agent that may still be running is reading ($what)"
  assert_absent "$dir/fake/created-windows" "a refused transaction must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused transaction must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused transaction must launch nothing ($what)"
}

test_tmux_refuses_a_window_missing_from_its_session() {
  local dir
  dir=$(new_case tmux-gone rl60)
  add_ship_task "$dir" rl60 claude
  strand_endpoint "$dir" rl60
  assert_tmux_missing_refuses "$dir" rl60 "window absent from a readable session inventory"
  pass "tmux: a window absent from its session refuses both verbs rather than being assumed gone"
}

test_tmux_refuses_a_session_that_cannot_be_found() {
  local dir
  dir=$(new_case tmux-nosession rl61)
  add_ship_task "$dir" rl61 claude
  # Real tmux's answer to a renamed session, and to a different
  # TMUX_TMPDIR/socket: definitive about the SESSION, silent about whether the
  # window and its agent survived elsewhere.
  : > "$dir/fake/session-missing"
  assert_tmux_missing_refuses "$dir" rl61 "recorded session not found"
  pass "tmux: an unfindable session refuses both verbs, so a live agent is never duplicated"
}

test_tmux_refuses_when_the_server_is_gone() {
  local dir
  dir=$(new_case tmux-noserver rl62)
  add_ship_task "$dir" rl62 claude
  # No server on the socket this process addresses. Another server may still be
  # running the task's window, and the record cannot say which socket is its.
  : > "$dir/fake/server-dead"
  assert_tmux_missing_refuses "$dir" rl62 "no tmux server on this socket"
  pass "tmux: a dead server on this socket refuses both verbs rather than proving absence"
}

test_reclaim_refuses_an_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case gone-unreadable rl63)
  add_ship_task "$dir" rl63 claude
  # The inventory itself fails non-definitively. That is not evidence of
  # absence, and reading it as one is exactly how two agents end up in one
  # endpoint.
  : > "$dir/fake/inventory-broken"

  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint must still refuse"
  assert_contains "$out" "positively agent-free endpoint" \
    "only a POSITIVELY proven agent-free endpoint may be relaunched into"
  assert_absent "$dir/fake/created-windows" \
    "a refused relaunch must not create an endpoint"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must launch nothing"
  pass "reclaim: an unclassifiable endpoint is still refused, so two agents cannot share one"
}

# --- herdr: a stopped server is not a destroyed endpoint --------------------
#
# Stopping and restarting a named Herdr server preserves workspace, tab, pane
# and label ids; only the harness processes and their registrations die
# (docs/herdr-backend.md "Restart and liveness behavior"). The recovery-grade
# classifier still reads a stopped server as `missing`, so a reclaim that
# believed that verdict would abandon a pane that was about to come back and
# open a second tab beside it.
#
# Canned/stateful fake only - never a real herdr session.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # The herdr server-ensure poll must actually wait between reads, so this case
  # keeps the real sleep rather than the tmux cases' instant stub.
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then
  rm -f "$D/herdr-stopped"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  # Every operational call against a stopped server fails at the transport,
  # with no JSON body to classify.
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
        "${3:-}" "$(cat "$D/cwd")"
    else
      # Only the pane this case says survived can be read back. Any other pane
      # id is structurally gone, which is herdr's `pane_not_found`.
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-registration" ]; then
      cat "$D/herdr-agent-registration"
    elif [ -f "$D/herdr-agent-live" ]; then
      # The agent came back with its server. Nothing here is reclaimable.
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      # A pane that comes back holding no agent is the adoptable state.
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session.
    if [ -f "$D/herdr-agent-registration" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "$(cat "$D/herdr-pane")"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
        "$(cat "$D/herdr-pane")"
    fi
    exit 0 ;;
  'pane send-text')
    # Mirrors the tmux fake's `becomes`: delivering the launch brief is what
    # makes an agent exist on this pane, so the control plane's alive-wait can
    # observe the replacement come up. A launch arrives as a short line sourcing
    # the staged launch file rather than the literal command, so read that file
    # back before deciding what was delivered - exactly as the tmux fake above
    # and tests/fixtures.sh do.
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[]}}\n'
    exit 0 ;;
  'workspace create')
    if [ -f "$D/herdr-workspace-create-fails" ]; then
      echo 'error: workspace create failed' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # The re-created endpoint. Recording it lets a case prove the pane the
    # record ends up naming is the one this call minted.
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    # From here on the new pane is the one that reads back.
    printf '%s' '%9' > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_DIR/herdr-agent-registration" ]; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
    '-p 4242 -o args=') printf 'bash\n' ;;
    *) exec /bin/ps "$@" ;;
  esac
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$fb/ps"
}

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a herdr reclaim safely.

## Firstmate spec
Keep the recorded endpoint when it outlives its server.
EOF
  {
    echo "window=$ses:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$ses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$survivor" > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
  TASK_TMPS+=("/tmp/fm-$id")
}

# Sets HERDR_CASE_DIR rather than echoing it, so callers invoke it as a plain
# statement. A `dir=$(herdr_case_or_skip ...)` would run add_herdr_ship_task in
# a command-substitution subshell, where its TASK_TMPS registration would
# mutate a discarded copy and the EXIT trap would never remove the
# out-of-tmproot /tmp/fm-<id> root the spawn creates.
HERDR_CASE_DIR=
herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

test_herdr_relaunch_resumes_only_the_registered_pi_session() {
  local dir out rc=0 command registered
  for registered in pi claude; do
    herdr_case_or_skip "resume-$registered" "resume-$registered" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    sed -i 's/^harness=claude$/harness=pi/' "$dir/home/state/resume-$registered.meta"
    # Keep the pane's status authority registered to an existing Pi session,
    # while process-info proves that its previous agent has exited.
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      "$registered" > "$dir/fake/herdr-agent-registration"
    out=$(run_spawn "$dir" "resume-$registered" --relaunch --harness pi) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete ($registered registration)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    if [ "$registered" = pi ]; then
      assert_contains "$command" "--session '/tmp/pi-bound-session.jsonl'" \
        "the replacement Pi must resume the session that owns Herdr status authority"
    else
      assert_not_contains "$command" "--session" \
        "a Pi replacement must not resume a foreign adapter's conversation"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: resumes the bound Pi session only for a Pi registration"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir out rc=0 log stray
  herdr_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl68 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" rl68 herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" rl68 herdr_pane_id)"
  [ "$(meta_field "$dir" rl68 herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" rl68 herdr_tab_id)"
  [ "$(meta_field "$dir" rl68 window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" rl68 window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir out rc=0
  herdr_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  herdr_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl73 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" rl73 herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" rl73 herdr_session)"
  [ "$(meta_field "$dir" rl73 window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" rl73 window)"
  [ "$(meta_field "$dir" rl73 herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" rl73 herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" rl74 --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" rl74 herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir out rc=0 head_before
  herdr_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/rl75.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/rl75.check.sh"
  chmod 0700 "$dir/home/state/rl75.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" rl75 >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/rl75.status"

  out=$(run_control "$dir" rl75 relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-rl75" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" rl75 worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" rl75 pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/rl75.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/rl75.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/rl75.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/rl75/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" rl75 exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  herdr_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" rl77 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_herdr_reclaim_of_a_secondmate_names_its_own_owner() {
  local dir out rc
  herdr_case_or_skip gone-herdr-secondmate rl76 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf '%s\n' "kind=secondmate" "home=$dir/wt" >> "$dir/home/state/rl76.meta"

  out=$(run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a secondmate reclaim belongs to the secondmate respawn path"
  assert_contains "$out" "--secondmate" "the refusal should name the path that owns this recovery"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" \
    "the refusal must happen before any endpoint is created"
  pass "reclaim: a herdr secondmate whose endpoint is gone is sent to its own respawn owner"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

test_exit_and_relaunch_remove_the_dialog_file() {
  local dir out rc
  dir=$(new_case dialog-file-exit rl70)
  add_ship_task "$dir" rl70 claude
  out=$(run_control "$dir" rl70 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl70.composer-dialog" ] \
    || fail "exit should remove the dialog file"

  dir=$(new_case dialog-file-relaunch rl71)
  add_ship_task "$dir" rl71 claude
  out=$(run_control "$dir" rl71 relaunch --note "replace the agent"); rc=$?
  expect_code 0 "$rc" "relaunch should replace the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl71.composer-dialog" ] \
    || fail "relaunch should remove the dialog file"
  pass "fm-control removes the dialog file after exit and after relaunch"
}

# The lock release removes paths at or under the control lock with rm, so a
# recording rm sees the state directory at the moment of release without a
# second overlapping command.
test_exit_removes_the_dialog_file_before_releasing_the_lock() {
  local dir out rc lock sink trace
  dir=$(new_case dialog-file-order rl72)
  add_ship_task "$dir" rl72 claude
  lock="$dir/home/state/.control-rl72.lock"
  sink="$dir/home/state/rl72.composer-dialog"
  trace="$dir/fake/rm-trace"
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$lock"|"$lock"/*)
      if [ -e "$sink" ]; then echo present; else echo absent; fi >> "$trace"
      break
      ;;
  esac
done
exec "$(command -v rm)" "\$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(run_control "$dir" rl72 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$lock" ] || fail "exit should release the control lock"
  [ "$(tail -n 1 "$trace" 2>/dev/null)" = absent ] \
    || fail "the dialog file must be gone when the control lock is released, got: $(cat "$trace" 2>/dev/null)"
  pass "fm-control exit removes the dialog file before it releases the control lock"
}

# --- Claude "Background work is running" exit picker -------------------------
#
# A Claude agent that still has live subagents answers /exit with a picker whose
# selected row stops them. The shell-stopping recovery cannot clear it (it lists
# no shell), so relaunch used to refuse with no way forward. The way forward is
# an explicit --stop-background, and nothing else may press a key into it.

background_picker_screen() {  # <agent-row>...
  printf '%s\n' \
    'Background work is running' \
    '' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:'
  printf '%s\n' "$@"
  printf '%s\n' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    '' \
    'Enter to confirm · Esc to cancel'
}

enter_count() {  # <case-dir>
  grep -c '^Enter$' "$1/fake/keys" || true
}

# The Enters the picker itself received, apart from the ones that submit
# commands and the ones the replacement launch sends later.
picker_enters() {  # <case-dir>
  grep -c '^Enter$' "$1/fake/picker-enters" 2>/dev/null || true
}

launched() {  # <case-dir>: whether the replacement launch was typed
  grep -Fq 'Firstmate operational input waiting: read' "$1/fake/literal"
}

test_relaunch_without_stop_background_refuses_the_picker_the_exit_opens() {
  local dir out rc before
  dir=$(new_case bgpicker-refuse rl80)
  add_ship_task "$dir" rl80 claude
  background_picker_screen '  agent · Explore the relaunch path' > "$dir/fake/picker-on-exit"
  before=$(cat "$dir/home/data/rl80/brief.md")

  out=$(run_control "$dir" rl80 relaunch --note "context ran out"); rc=$?

  expect_code 1 "$rc" "a relaunch must not choose for the caller at the picker"$'\n'"$out"
  assert_contains "$out" "Claude background-task exit picker" "the refusal should name the dialog"
  assert_contains "$out" "--stop-background" "the refusal should name the flag that proceeds"
  assert_contains "$out" "original instructions were restored" "the refusal should restore the brief"
  [ "$(enter_count "$dir")" -eq 1 ] \
    || fail "only the Enter that submitted /exit may be sent, got $(enter_count "$dir")"
  [ ! -e "$dir/fake/picker-confirmed" ] && [ ! -e "$dir/fake/picker-other-row" ] \
    || fail "no row of the picker may be chosen without the flag"
  [ ! -e "$dir/fake/picker-escaped" ] || fail "nothing may dismiss a picker that lists no shell"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running"
  [ "$(cat "$dir/home/data/rl80/brief.md")" = "$before" ] || fail "the brief must be restored byte-exact"
  ! launched "$dir" || fail "no replacement may be launched"
  pass "fm-control relaunch: the background picker refuses without --stop-background, names the flag, and restores the brief"
}

test_relaunch_without_stop_background_refuses_a_picker_that_is_already_open() {
  local dir out rc before
  dir=$(new_case bgpicker-open rl81)
  add_ship_task "$dir" rl81 claude
  background_picker_screen '  agent · Explore the relaunch path' > "$dir/fake/picker"
  before=$(cat "$dir/home/data/rl81/brief.md")

  out=$(run_control "$dir" rl81 relaunch --note "context ran out"); rc=$?

  expect_code 1 "$rc" "an open picker must refuse"$'\n'"$out"
  assert_contains "$out" "--stop-background" "the refusal should name the flag that proceeds"
  [ ! -s "$dir/fake/keys" ] || fail "an open picker must receive no key, got: $(cat "$dir/fake/keys")"
  [ ! -s "$dir/fake/literal" ] || fail "an open picker must not be typed into"
  [ "$(cat "$dir/home/data/rl81/brief.md")" = "$before" ] || fail "the brief must be restored byte-exact"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running"
  pass "fm-control relaunch: a picker already on screen refuses at once with no key, naming the flag"
}

test_relaunch_stop_background_confirms_exit_and_stop_tasks() {
  local dir out rc
  dir=$(new_case bgpicker-confirm rl82)
  add_ship_task "$dir" rl82 claude
  background_picker_screen '  agent · Explore the relaunch path' '  shell · sleep 300' \
    > "$dir/fake/picker-on-exit"

  out=$(run_control "$dir" rl82 relaunch --stop-background --note "context ran out"); rc=$?

  expect_code 0 "$rc" "--stop-background should carry the relaunch through the picker"$'\n'"$out"
  assert_contains "$out" "relaunched rl82 harness=claude" "the relaunch should complete"
  [ -e "$dir/fake/picker-confirmed" ] || fail "Exit and stop tasks should have been confirmed"
  [ ! -e "$dir/fake/picker-other-row" ] || fail "no other row may be chosen"
  [ ! -e "$dir/fake/picker-escaped" ] || fail "the flag confirms the picker; it must not be escaped"
  [ "$(picker_enters "$dir")" -eq 1 ] \
    || fail "the picker should receive exactly one Enter, got $(picker_enters "$dir")"
  [ "$(grep -c '^/exit$' "$dir/fake/literal")" -eq 1 ] || fail "/exit should be typed once"
  launched "$dir" || fail "the replacement should have been launched"
  [ "$(journal_field "$dir" rl82 phase)" = complete ] || fail "the transaction journal should end complete"
  pass "fm-control relaunch: --stop-background confirms Exit and stop tasks and the relaunch continues"
}

test_relaunch_stop_background_confirms_a_picker_that_is_already_open() {
  local dir out rc
  dir=$(new_case bgpicker-open-confirm rl83)
  add_ship_task "$dir" rl83 claude
  background_picker_screen '  agent · Explore the relaunch path' > "$dir/fake/picker"

  out=$(run_control "$dir" rl83 relaunch --stop-background --note "context ran out"); rc=$?

  expect_code 0 "$rc" "--stop-background should carry the relaunch through an open picker"$'\n'"$out"
  [ -e "$dir/fake/picker-confirmed" ] || fail "Exit and stop tasks should have been confirmed"
  [ "$(picker_enters "$dir")" -eq 1 ] || fail "the picker should receive exactly one Enter, got $(picker_enters "$dir")"
  assert_no_grep "/exit" "$dir/fake/literal" "nothing is typed into a picker that is already open"
  launched "$dir" || fail "the replacement should have been launched"
  pass "fm-control relaunch: --stop-background confirms a picker that was already open"
}

test_relaunch_stop_background_never_presses_enter_on_another_row() {
  local dir out rc before
  dir=$(new_case bgpicker-other-row rl84)
  add_ship_task "$dir" rl84 claude
  # The selected row is not "Exit and stop tasks": the picker's own text no
  # longer matches the recorded structure, so no key is pressed blind.
  printf '%s\n' \
    'Background work is running' \
    '' \
    '  1. Exit and stop tasks' \
    '❯ 2. Move to background and exit' \
    '  3. Stay' \
    '' \
    'Enter to confirm · Esc to cancel' > "$dir/fake/picker"
  before=$(cat "$dir/home/data/rl84/brief.md")

  out=$(run_control "$dir" rl84 relaunch --stop-background --note "context ran out"); rc=$?

  expect_code 1 "$rc" "an unrecognised selection must refuse even with the flag"$'\n'"$out"
  [ ! -s "$dir/fake/keys" ] || fail "no key may be pressed into an unrecognised picker, got: $(cat "$dir/fake/keys")"
  [ ! -e "$dir/fake/picker-other-row" ] || fail "Move to background must never be chosen"
  [ "$(cat "$dir/home/data/rl84/brief.md")" = "$before" ] || fail "the brief must be restored byte-exact"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running"
  pass "fm-control relaunch: --stop-background presses nothing when the selected row is not Exit and stop tasks"
}

test_relaunch_stop_background_does_nothing_when_there_is_no_picker() {
  local dir out rc
  dir=$(new_case bgpicker-none rl85)
  add_ship_task "$dir" rl85 claude

  out=$(run_control "$dir" rl85 relaunch --stop-background --note "ordinary relaunch"); rc=$?

  expect_code 0 "$rc" "the flag is harmless when no picker shows"$'\n'"$out"
  [ ! -e "$dir/fake/picker-confirmed" ] || fail "no picker was shown, so none may be confirmed"
  [ ! -e "$dir/fake/picker-enters" ] || fail "no picker was shown, so none may receive an Enter"
  pass "fm-control relaunch: --stop-background adds no key when the agent exits without a picker"
}


test_relaunch_without_stop_background_refuses_the_picker_the_exit_opens
test_relaunch_without_stop_background_refuses_a_picker_that_is_already_open
test_relaunch_stop_background_confirms_exit_and_stop_tasks
test_relaunch_stop_background_confirms_a_picker_that_is_already_open
test_relaunch_stop_background_never_presses_enter_on_another_row
test_relaunch_stop_background_does_nothing_when_there_is_no_picker
test_usage_limit_route_to_claude_is_exempt_from_the_claude_dispatch_pairs
test_exit_and_relaunch_remove_the_dialog_file
test_exit_removes_the_dialog_file_before_releasing_the_lock
# --- restore a task closed before its done -----------------------------------
# bin/fm-teardown.sh archives every ship or scout record at
# data/<id>/record/closed-task.meta. These cases build that archive the way
# teardown writes it, in a spawn-world home (tests/fixtures.sh) where a fresh
# dispatch can run against a fake tmux pane.

# restore_case <name> <id> [branch-prefix] -> "<case>|<home>|<proj>|<wt>|<fakebin>"
restore_case() {
  local name=$1 id=$2 prefix=${3-fm/} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/restore-$name-$RANDOM"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "purge the test episode and post the timed result for $id"
  printf '\nShip branch: %s%s\n' "$prefix" "$id" >> "$home/data/$id/brief.md"
  mkdir -p "$home/data/$id/record"
  fm_write_meta "$home/data/$id/record/closed-task.meta" \
    "archived_at=1792786336" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/returned-slot" \
    "project=$proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "branch=$prefix$id" \
    "tasktmp=/tmp/fm-$id" \
    "model=default" \
    "effort=default" \
    "spawn_gen=s1792786336.1.1" \
    "pr=https://github.com/example/repo/pull/4497"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

# A closed row, as teardown leaves it: added, started, then done with its PR.
restore_seed_closed_row() {  # <home> <id>
  local file="$1/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$2" "restore fixture task" --kind ship --repo project --file "$file" >/dev/null
  tasks-axi start "$2" --file "$file" >/dev/null
  tasks-axi "done" "$2" --pr https://github.com/example/repo/pull/4497 --file "$file" >/dev/null
}

restore_row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

run_restore_control() {  # <home> <wt> <fakebin> <control args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  mkdir -p "$home/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR='' CODEX_HOME='' GROK_HOME="$home/grok-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX=fake,1,0 \
    PATH="$fakebin:$PATH" "$CONTROL" "$@" 2>&1
}

test_relaunch_of_a_closed_task_names_its_archive_and_restores_it() {
  local rec case_dir home proj wt fakebin id=rs-closed1 out rc=0 meta
  rec=$(restore_case closed "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<<"$rec"
  restore_seed_closed_row "$home" "$id"

  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --note "finish the purge") || rc=$?
  expect_code 1 "$rc" "a relaunch of a closed task without --restore should refuse"$'\n'"$out"
  assert_contains "$out" "no task '$id'" "the refusal lost its ordinary wording"
  assert_contains "$out" "it was closed, and its record is archived at $home/data/$id/record/closed-task.meta" \
    "the refusal did not name the archived record"
  assert_contains "$out" "relaunch --restore" "the refusal did not name the way back"
  assert_absent "$home/state/$id.meta" "a refused relaunch published a record"

  rc=0
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore \
    --note "T19 is measured; purge the test MEETING episode, then post the result") || rc=$?
  expect_code 0 "$rc" "restoring a closed task from its archive should succeed"$'\n'"$out"
  assert_contains "$out" "restored $id from $home/data/$id/record/closed-task.meta harness=claude kind=ship" \
    "the restore did not report what it brought back"
  meta="$home/state/$id.meta"
  assert_present "$meta" "the restore published no task record"
  assert_grep "harness=claude" "$meta" "the restored task lost its harness"
  assert_grep "kind=ship" "$meta" "the restored task lost its kind"
  assert_grep "mode=no-mistakes" "$meta" "the restored task lost its delivery mode"
  assert_grep "yolo=off" "$meta" "the restored task lost its merge posture"
  assert_grep "project=$proj" "$meta" "the restored task lost its project"
  assert_grep "branch=fm/$id" "$meta" "the restored task lost its branch"
  assert_no_grep "worktree=$case_dir/returned-slot" "$meta" "the restore reused the returned slot"
  [ "$(restore_row_state "$home" "$id")" = in_flight ] \
    || fail "the restored task's backlog item is $(restore_row_state "$home" "$id"), not in flight"
  assert_grep "## Restore note" "$home/data/$id/brief.md" "the brief does not say the task was restored"
  assert_grep "purge the test MEETING episode, then post the result" "$home/data/$id/brief.md" \
    "the restore note did not reach the brief"

  rc=0
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore --note "again") || rc=$?
  expect_code 1 "$rc" "a restore of a live task should refuse"$'\n'"$out"
  assert_contains "$out" "still has a live record" "the refusal did not say the task is live"
  pass "fm-control relaunch: a task closed before its done names its archive, and --restore brings it back"
}

test_restore_preserves_an_empty_branch_prefix() {
  local rec case_dir home proj wt fakebin id=rs-bare4 out rc=0
  rec=$(restore_case bare "$id" '')
  IFS='|' read -r case_dir home proj wt fakebin <<<"$rec"
  restore_seed_closed_row "$home" "$id"
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore \
    --note "finish the task on its original branch") || rc=$?
  expect_code 0 "$rc" "restoring a task with an empty branch prefix should succeed"$'\n'"$out"
  grep -Fxq "branch=$id" "$home/state/$id.meta" || fail "the restore replaced the empty branch prefix"
  grep -Fxq "Ship branch: $id" "$home/data/$id/brief.md" || fail "the restore changed the branch contract"
  [ "$(restore_row_state "$home" "$id")" = in_flight ] \
    || fail "the restored bare-branch task is not in flight"
  pass "fm-control relaunch --restore: an empty branch prefix survives the real dispatch and brief check"
}

test_restore_re_adds_a_row_that_was_archived_away() {
  local rec case_dir home proj wt fakebin id=rs-archived2 out rc=0
  rec=$(restore_case archived "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<<"$rec"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' '' '## Archived 2026-10-23' \
    "- [x] $id - restore fixture task https://github.com/example/repo/pull/4497 (repo: project) (kind: ship) (merged 2026-10-23)" \
    > "$home/data/done-archive.md"
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore --note "post the result") || rc=$?
  expect_code 0 "$rc" "restoring a task whose closed row was archived away should succeed"$'\n'"$out"
  [ "$(restore_row_state "$home" "$id")" = in_flight ] \
    || fail "the re-added backlog item is $(restore_row_state "$home" "$id"), not in flight"
  assert_grep "restored after it was closed before its done" "$home/data/backlog.md" \
    "the re-added row does not say why it is back"
  pass "fm-control relaunch --restore: a closed row already archived away is added back, then dispatched"
}

test_restore_that_cannot_dispatch_changes_no_instructions() {
  local rec case_dir home proj wt fakebin id=rs-refused3 out rc=0 before archive
  rec=$(restore_case refused "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<<"$rec"
  restore_seed_closed_row "$home" "$id"
  archive="$home/data/$id/record/closed-task.meta"
  before=$(cksum < "$home/data/$id/brief.md")
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore --harness no-such-harness \
    --note "post the result") || rc=$?
  [ "$rc" -ne 0 ] || fail "a restore whose dispatch refused reported success"$'\n'"$out"
  assert_contains "$out" "could not be restored" "the refusal did not say the restore failed"
  [ "$(cksum < "$home/data/$id/brief.md")" = "$before" ] \
    || fail "a refused restore left the restore note in the brief"
  assert_absent "$home/state/$id.meta" "a refused restore published a task record"
  assert_present "$archive" "a refused restore lost the archive"
  [ "$(restore_row_state "$home" "$id")" = queued ] \
    || fail "a refused restore left the backlog item $(restore_row_state "$home" "$id"), not queued for a retry"

  rc=0
  mv "$archive" "$archive.moved-aside"
  out=$(run_restore_control "$home" "$wt" "$fakebin" "$id" relaunch --restore --note "x") || rc=$?
  expect_code 1 "$rc" "a restore with no archive should refuse"$'\n'"$out"
  assert_contains "$out" "has no archived record" "the refusal did not say the archive is missing"
  pass "fm-control relaunch --restore: a dispatch refusal or a missing archive changes no instructions"
}

if [ "${FM_CONTROL_RELAUNCH_TEST_GROUP:-}" = restore ]; then
  test_relaunch_of_a_closed_task_names_its_archive_and_restores_it
  test_restore_preserves_an_empty_branch_prefix
  test_restore_re_adds_a_row_that_was_archived_away
  test_restore_that_cannot_dispatch_changes_no_instructions
  exit 0
fi

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop
test_signed_out_worker_account_pin_refuses_before_stop
test_worker_account_pin_follows_the_relaunch
test_pi_exclude_tools_follow_the_relaunch
test_exclude_tools_refusals_happen_before_the_agent_stops
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_claude_relaunch_keeps_local_settings
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_spawn_relaunch_adopts_the_single_dispatch_pair
test_spawn_relaunch_refuses_when_the_file_offers_two_pairs
test_relaunch_refuses_an_ambiguous_dispatch_pair_before_the_agent_stops
test_relaunch_journal_records_the_adopted_dispatch_pair
test_relaunch_refuses_an_unknown_adopted_effort_before_the_agent_stops
test_spawn_relaunch_refuses_an_unknown_adopted_effort
test_relaunch_keeps_the_prestop_pair_when_dispatch_changes
test_spawn_relaunch_with_explicit_axes_still_adopts_the_file_pair
test_relaunch_validates_the_adopted_profile_before_the_agent_stops
test_relaunch_preserves_explicit_default_resets
test_relaunch_refuses_unmatched_partial_resets_before_stopping
test_relaunch_default_resets_without_named_dispatch_profiles
test_spawn_relaunch_without_profile_flags_inherits_the_recorded_pair
test_spawn_rejects_fresh_default_resets_and_empty_profile_values
test_relaunch_refuses_an_unreadable_dispatch_file_before_the_agent_stops
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch
test_promoted_scout_relaunch_receives_the_current_delivery_contract
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_raw_relaunch_preserves_retiring_codex_limit_for_later_routes
test_raw_relaunch_refuses_route_changes_without_replacing_generation
test_raw_cursor_family_is_kept_when_usage_is_healthy
test_raw_cursor_override_is_recorded
test_control_relaunch_of_a_usage_limited_codex_task_lands_on_claude
test_spawn_relaunch_of_a_marked_codex_task_lands_on_claude
test_control_relaunch_of_a_cursor_task_records_the_harness_it_launched
test_explicit_override_of_a_cursor_task_is_recorded
test_spawn_relaunch_keeps_the_recorded_profile_axes
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_tmux_refuses_a_window_missing_from_its_session
test_tmux_refuses_a_session_that_cannot_be_found
test_tmux_refuses_when_the_server_is_gone
test_reclaim_refuses_an_unreadable_endpoint
test_herdr_relaunch_resumes_only_the_registered_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
test_herdr_rebind_stays_in_the_recorded_session
test_herdr_reclaim_refuses_an_agent_that_came_back
test_herdr_reclaim_keeps_the_task_whole
test_herdr_reclaim_of_a_secondmate_names_its_own_owner
test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
test_relaunch_of_a_closed_task_names_its_archive_and_restores_it
test_restore_preserves_an_empty_branch_prefix
test_restore_re_adds_a_row_that_was_archived_away
test_restore_that_cannot_dispatch_changes_no_instructions
