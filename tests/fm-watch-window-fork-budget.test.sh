#!/usr/bin/env bash
# Per-window process budget for the real watcher loop (.agent-config-ks05d.4).
# Counts distinct process IDs from inherited DEBUG traps and PATH command shims,
# including Bash substitutions, without counting an exec twice.
# Bash 4+ is required only by the counter; production retains Bash 3.2 support.
# shellcheck disable=SC2016 # Quoted fixture scripts expand in their own shells.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'skip: fork counting requires BASHPID (Bash 4+)'; exit 0; }
command -v awk >/dev/null 2>&1 || { echo 'skip: awk not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watch-window-fork-budget)
REAL_PATH=$PATH

BUDGET_WATCHER_PID=
cleanup() {
  if [ -n "$BUDGET_WATCHER_PID" ]; then
    kill -TERM "$BUDGET_WATCHER_PID" 2>/dev/null || true
    wait "$BUDGET_WATCHER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP


COUNTER="$TMP_ROOT/count.sh"
cat > "$COUNTER" <<'SH'
set -T
fm_budget_pid=
trap 'if [ "${fm_budget_pid:-}" != "${BASHPID:-}" ]; then
  fm_budget_pid=${BASHPID:-}
  printf "p %s\n" "${BASHPID:-}" >> "$FM_FORK_LOG"
fi
if [ -n "${FM_FORK_MARK:-}" ] && [ "${BASH_COMMAND:-}" = "$FM_FORK_MARK" ] \
  && [ "${FUNCNAME[0]:-main}" = "${FM_FORK_MARK_FUNC:-main}" ]; then
  printf "m %s\n" "${BASHPID:-}" >> "$FM_FORK_LOG"
fi' DEBUG
SH

# Logging stand-ins for the external commands these loops have used.
SHIMS="$TMP_ROOT/shims"
mkdir -p "$SHIMS"
for tool in sleep stat cat tail head od tr cut sort sed awk grep wc date touch \
  mktemp rm mv ln readlink dirname basename uname ps md5 md5sum cksum mkdir \
  rmdir chmod mkfifo timeout gtimeout perl jq id; do
  real=$(PATH=$REAL_PATH command -v "$tool" 2>/dev/null) || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/sh\nprintf "x %%s %s\\n" "$$" >> "$FM_FORK_LOG"\nexec %s "$@"\n' "$tool" "$real" > "$SHIMS/$tool"
  chmod +x "$SHIMS/$tool"
done

# Distinct processes started from pass <skip>+1 through pass <skip>+<passes>
# of the loop whose markers the log carries, or only those running <command>
# when one is named; "short" when the loop ran fewer passes.
count_passes() {  # <log> <skip> <passes> [command]
  awk -v skip="$2" -v n="$3" -v only="${4:-}" '
    $1 == "m" {
      if (loop == "") loop = $2
      if ($2 != loop) next
      m++
      if (m == skip + 1) on = 1
      else if (m == skip + n + 1) { on = 0; done = 1 }
      next
    }
    only != "" && !($1 == "x" && $3 == only) { next }
    on && ($1 == "p" || $1 == "x") && $2 != "" && $2 != loop && !seen[$2]++ { c++ }
    END { if (!done) { print "short"; exit 1 } print c + 0 }' "$1"
}

markers_in() {  # <log>
  awk '$1 == "m" { n++ } END { print n + 0 }' "$1" 2>/dev/null || echo 0
}

wait_markers() {  # <log> <count> <seconds>
  local limit=$(( $3 * 10 )) i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(markers_in "$1")" -ge "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

make_watch_home() {  # <name> <statuses> <windows>
  local home="$TMP_ROOT/$1" i
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/fakebin"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # An unreachable backend: a capture fails, so a window's whole pre-capture
  # path and the capture attempt run on every poll and nothing ever wakes.
  cat > "$home/fakebin/tmux" <<'SH'
#!/bin/sh
printf 'x %s tmux\n' "$$" >> "$FM_FORK_LOG"
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  i=1
  while [ "$i" -le "$2" ]; do
    printf 'working: step %s\n' "$i" > "$home/state/task$i.status"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$3" ]; do
    printf 'window=fm:fm-task%s\nharness=claude\nkind=ship\nbackend=tmux\n' "$i" > "$home/state/task$i.meta"
    i=$((i + 1))
  done
  cat > "$home/settle.sh" <<'SH'
. "$1/bin/fm-wake-lib.sh" || exit 1
for f in "$2"/state/*.status; do
  [ -e "$f" ] || continue
  fm_wake_status_mark_current "$2/state" "$f" || exit 1
done
SH
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$home/settle.sh" "$ROOT" "$home" \
    || fail "watch: could not settle the fixture status logs"
  touch "$home/state/.last-heartbeat" "$home/state/.last-check"
  fm_test_track_watcher_state "$home/state"
  printf '%s\n' "$home"
}

# Processes started across polls 2-5 of a watcher on <home>.
watch_polls() {  # <home> <log>
  local home=$1 log=$2 pid
  : > "$log"
  ( unset TMUX FM_TASK_ID
    export PATH="$home/fakebin:$SHIMS:$REAL_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_HEARTBEAT_MAX=999999 BASH_ENV="$COUNTER" FM_FORK_LOG="$log" \
      FM_FORK_MARK=watcher_world_gone FM_FORK_MARK_FUNC=main
    exec bash "$ROOT/bin/fm-watch.sh" ) > "$home/watch.out" 2>&1 &
  pid=$!
  BUDGET_WATCHER_PID=$pid
  if ! wait_markers "$log" 6 90; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    BUDGET_WATCHER_PID=
    fail "watch: the watcher did not reach six polls: $(head -c 400 "$home/watch.out")"
  fi
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  BUDGET_WATCHER_PID=
  WATCH_POLLS=$(count_passes "$log" 1 4) || fail "watch: incomplete poll count"
}

# Fixed poll overhead cancels: both homes have four settled status logs,
# identical cadence and no due checks; only the recorded windows differ.
# A failed capture intentionally exercises all per-window preparation while
# keeping the fixture independent of any installed backend or agent.
WATCH_POLLS=0
empty_home=$(make_watch_home no-windows 4 0)
watch_polls "$empty_home" "$TMP_ROOT/no-windows.forks"
fixed=$WATCH_POLLS
window_home=$(make_watch_home four-windows 4 4)
watch_polls "$window_home" "$TMP_ROOT/four-windows.forks"
windows=$WATCH_POLLS
added=$((windows - fixed))
printf 'window budget: %s fixed processes; %s with four windows, over four polls; %s added processes = %s per window per poll\n' \
  "$fixed" "$windows" "$added" "$((added / 16))"
[ "$added" -ge 16 ] || fail "window counter did not observe capture processes"
[ "$added" -le 80 ] || fail "window reads added $added processes; budget is 5 per window per poll (80 total)"
pass "window preparation starts no processes beyond the five needed by each failed capture"
