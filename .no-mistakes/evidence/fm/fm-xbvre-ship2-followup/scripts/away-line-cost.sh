#!/usr/bin/env bash
# Measure what fm_claude_away_wake_line adds to one waker process, on a
# host-off home (the common case: the gate returns before the afk library
# loads) and on a host-on home with a live away record (the costly case: the
# afk + classify libraries load). Each sample is a fresh bash that sources
# bin/fm-wake-lib.sh as the waker does, with and without the call.
# Usage: away-line-cost.sh <worktree> <scratch-home> <samples>
set -u
wt=$1 home=$2 n=$3
mkdir -p "$home/state" "$home/config-off" "$home/config-on"
probe=$home/probe.sh
cat > "$probe" <<'SH'
. "$1/bin/fm-wake-lib.sh"
[ "$4" = call ] || exit 0
fm_claude_away_wake_line "$2" "$3" >/dev/null || true
SH
avg() {  # <label> <config> <mode>
  local t0 t1 i=0
  t0=$EPOCHREALTIME
  while [ "$i" -lt "$n" ]; do
    bash "$probe" "$wt" "$home/state" "$2" "$3"
    i=$((i + 1))
  done
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" -v n="$n" -v l="$1" 'BEGIN { printf "%-34s %.1f ms per waker process\n", l, (b - a) * 1000 / n }'
}
printf '# load %s, %s samples each\n' "$(uptime | sed 's/.*load averages*: //')" "$n"
: > "$home/config-off/supervision-host-off"
avg 'host off: source only' "$home/config-off" none
avg 'host off: source + away line' "$home/config-off" call
FM_HOME=$home "$wt/bin/fm-afk-contract.sh" enter --words 'cost probe' >/dev/null 2>&1
avg 'host on + away: source only' "$home/config-on" none
avg 'host on + away: source + away line' "$home/config-on" call
