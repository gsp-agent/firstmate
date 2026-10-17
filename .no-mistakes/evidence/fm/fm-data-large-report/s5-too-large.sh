#!/usr/bin/env bash
# Live scenario: aa-slow was cut off by the budget (s4). Its next visit gets one
# full attempt (FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT, 5s here); when that is cut
# off too, it is marked too-large, and the following teardown skips it without
# an attempt, keeps its data and names it.
# Usage: s5-too-large.sh <worktree> <lab>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
quiet() { grep -v "watcher still down\|fm-gate-refuse\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g" | sed -E 's/(dcg refused cleanup: ).*/\1<dcg evaluation-timeout JSON elided>/'; }
rec() { printf '%s mtime %s %s' "$1" "$(stat -f %m "$LAB/data/$1/record/data-cleanup.json")" "$(jq -c '{expired, expiry}' "$LAB/data/$1/record/data-cleanup.json")"; }
watch_attempts() { # log every expire process for aa-slow while the teardown runs
  while kill -0 "$1" 2>/dev/null; do
    pgrep -f "fm-task-data.py expire .* aa-slow$" >/dev/null && echo seen
    sleep 0.2
  done | sort -u
}

echo "before: $(rec aa-slow); pending: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"
echo "=================== teardown t-full1 (budget 2s, full attempt 5s)"
bash "$E/lab-task.sh" "$LAB" t-full1
started=$SECONDS
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-full1 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=5 2>&1 | stamp | quiet
echo "t-full1 took $((SECONDS - started))s"
echo "after t-full1: $(rec aa-slow); hold: $(ls -A "$LAB/data/aa-slow/.cleanup-hold" | tr '\n' ' ')"

echo
echo "=================== teardown t-skip (same budgets): aa-slow must be skipped, not attempted"
before_mtime=$(stat -f %m "$LAB/data/aa-slow/record/data-cleanup.json")
bash "$E/lab-task.sh" "$LAB" t-skip
started=$SECONDS
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-skip FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=5 > >(stamp | quiet > "$E/s5-t-skip.out") 2>&1 &
td=$!
attempts=$(watch_attempts "$td")
wait "$td"; rc=$?
sleep 0.5
cat "$E/s5-t-skip.out"
echo "t-skip exit $rc, took $((SECONDS - started))s; expire process for aa-slow observed during t-skip: ${attempts:-never}"
echo "after t-skip: $(rec aa-slow) (mtime before t-skip $before_mtime); hold: $(ls -A "$LAB/data/aa-slow/.cleanup-hold" | tr '\n' ' ')"

echo
echo "=================== expire it by hand with the command the warning names (full time, no cap)"
started=$SECONDS
(cd "$WT" && env -u NO_MISTAKES_GATE HOME="$LAB/home" python3 bin/fm-task-data.py expire "$LAB/data" "$LAB/state" aa-slow) 2>&1 | quiet
echo "manual expire exit ${PIPESTATUS[0]} after $((SECONDS - started))s: $(rec aa-slow); hold: $(ls -A "$LAB/data/aa-slow/.cleanup-hold" 2>/dev/null | tr '\n' ' ')"
