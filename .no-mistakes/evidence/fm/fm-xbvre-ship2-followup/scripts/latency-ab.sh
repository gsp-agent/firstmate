#!/usr/bin/env bash
# A/B the waker's append-to-exit latency (tests/fm-claude-wake.test.sh
# test_0706z_replay, bound: under one second) on the base and head bin/,
# interleaved so both see the same host load. The test body is unchanged;
# only its within_second assertion is redefined to report each measured
# _ELAPSED instead of aborting, so every run yields its timings.
# Usage: latency-ab.sh <worktree> <base-dir> <head-dir> <reps>
# (<base-dir>/<head-dir> are empty throwaway dirs the caller removes.)
set -u
wt=$1 based=$2 headd=$3 reps=$4
cd "$wt" || exit 1
git archive --format=tar 1991ea087f00ad2313d170d6c0b69123905ca484 bin tests | tar -x -C "$based"
git archive --format=tar 527b9c60 bin tests | tar -x -C "$headd"
for d in "$based" "$headd"; do
  {
    git show 527b9c60:tests/fm-claude-wake.test.sh | awk '/^test_[a-z0-9_]+$/ { next } { print }'
    cat <<'DRIVER'
within_second() {
  local v
  v=$(printf '%s\n' "$1" | sed -n "s/^$2_ELAPSED=//p")
  printf '%s_ELAPSED=%s %s\n' "$2" "$v" "$(awk -v x="$v" 'BEGIN { print (x != "" && x < 1) ? "under-1s" : "OVER-1s" }')"
}
test_0706z_replay
DRIVER
  } > "$d/tests/latency.test.sh"
done
r=1
while [ "$r" -le "$reps" ]; do
  for side in base head; do
    d=$based; [ "$side" = head ] && d=$headd
    printf '=== %s run %s, load %s\n' "$side" "$r" "$(uptime | sed 's/.*load averages*: //')"
    bash "$d/tests/latency.test.sh" 2>&1
  done
  r=$((r + 1))
done
