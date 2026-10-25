#!/usr/bin/env bash
# tests/fm-watch-scan-fork-budget.test.sh - the watcher's signal scan reads
# every status log with one stat(1) per poll, so an idle poll in a settled
# home starts no more processes with 22 status logs than with 2
# (.agent-config-ks05d.4). The scan used to start about 15 processes per log
# per poll (three stats, od, tr, and their subshells, twice over), which on a
# home with hundreds of logs was most of the captain's process starts.
# Every process a poll starts is counted: an inherited DEBUG trap logs each
# Bash process once (a subshell, a script, or a command a subshell became),
# and PATH shims log each external command. The counter needs Bash 4+ for
# BASHPID; the scan itself still runs on Bash 3.2.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'skip: fork counting requires BASHPID (Bash 4+)'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watch-scan-fork-budget)
REAL_PATH=$PATH

COUNTER="$TMP_ROOT/count.sh"
cat > "$COUNTER" <<'SH'
set -T
fm_budget_pid=
trap 'if [ "${fm_budget_pid:-}" != "${BASHPID:-}" ]; then
  fm_budget_pid=${BASHPID:-}
  printf "p %s\n" "${BASHPID:-}" >> "$FM_FORK_LOG"
fi
if [ -n "${FM_FORK_MARK:-}" ] && [ "${BASH_COMMAND:-}" = "$FM_FORK_MARK" ] \
  && [ "${FUNCNAME[0]:-main}" = main ]; then
  printf "m %s\n" "${BASHPID:-}" >> "$FM_FORK_LOG"
fi' DEBUG
SH

SHIMS="$TMP_ROOT/shims"
mkdir -p "$SHIMS"
for tool in sleep stat cat tail head od tr cut sort sed awk grep wc date touch \
  mktemp rm mv ln readlink dirname basename uname ps mkdir rmdir chmod timeout gtimeout perl jq; do
  real=$(PATH=$REAL_PATH command -v "$tool" 2>/dev/null) || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/sh\nprintf "x %%s %s\\n" "$$" >> "$FM_FORK_LOG"\nexec %s "$@"\n' "$tool" "$real" > "$SHIMS/$tool"
  chmod +x "$SHIMS/$tool"
done

# Distinct processes started from poll <skip>+1 through poll <skip>+<polls>;
# "short" when the watcher ran fewer polls.
count_polls() {  # <log> <skip> <polls>
  awk -v skip="$2" -v n="$3" '
    $1 == "m" {
      if (loop == "") loop = $2
      if ($2 != loop) next
      m++
      if (m == skip + 1) on = 1
      else if (m == skip + n + 1) { on = 0; done = 1 }
      next
    }
    on && ($1 == "p" || $1 == "x") && $2 != "" && $2 != loop && !seen[$2]++ { c++ }
    END { if (!done) { print "short"; exit 1 } print c + 0 }' "$1"
}

# A settled main home: <statuses> logs already reported and classified, no
# window, and no cadence due.
make_home() {  # <name> <statuses>
  local home="$TMP_ROOT/$1" i
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$2" ]; do
    printf 'working: step %s\n' "$i" > "$home/state/task$i.status"
    i=$((i + 1))
  done
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-wake-lib.sh" || exit 1
    for f in "$2"/state/*.status; do
      [ -e "$f" ] || continue
      fm_wake_status_mark_current "$2/state" "$f" || exit 1
    done' _ "$ROOT" "$home" || fail "could not settle the fixture status logs"
  touch "$home/state/.last-heartbeat" "$home/state/.last-check"
  fm_test_track_watcher_state "$home/state"
  printf '%s\n' "$home"
}

# Processes started across polls 2-5 of a watcher on <home>.
watch_polls() {  # <home>
  local home=$1 log="$1/forks" pid i=0
  : > "$log"
  ( unset TMUX FM_TASK_ID
    export PATH="$SHIMS:$REAL_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_HEARTBEAT_MAX=999999 BASH_ENV="$COUNTER" FM_FORK_LOG="$log" FM_FORK_MARK=watcher_world_gone
    exec bash "$ROOT/bin/fm-watch.sh" ) > "$home/watch.out" 2>&1 &
  pid=$!
  while [ "$(awk '$1 == "m" { n++ } END { print n + 0 }' "$log")" -lt 6 ] && [ "$i" -lt 900 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  count_polls "$log" 1 4 || fail "the watcher on $home did not reach six polls: $(head -c 400 "$home/watch.out")"
}

few=$(watch_polls "$(make_home few 2)")
many=$(watch_polls "$(make_home many 22)")
printf 'scan: 4 idle polls start %s processes with 2 status logs, %s with 22\n' "$few" "$many"
# Twenty more logs may not add a process per poll; allow one in total for noise.
[ $((many - few)) -le 1 ] \
  || fail "20 more status logs added $((many - few)) processes over 4 idle polls (the scan must read them with one stat)"
pass "scan: an idle poll reads any number of status logs with the same processes"
