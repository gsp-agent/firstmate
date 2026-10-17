#!/usr/bin/env bash
# Live scenario in a second, clean lab:
#  (a) 3,000 already-expired cleanup records older than the one live hold do
#      not use up the expiry budget: the live hold expires on the next teardown.
#  (b) a hold the 2s budget cuts off is marked cut-off; the next teardown gives
#      it one full attempt (default 60s cap) which completes, expires the hold
#      and clears the mark.
# Continuation of s6 (run after it). Usage: s6b-full-attempt.sh <worktree> <lab2>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
quiet() { grep -v "watcher still down\|WATCHER DOWN\|●\|fm-gate-refuse\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g" | sed -E 's/(dcg refused cleanup: ).*/\1<dcg evaluation-timeout JSON elided>/'; }
rec() { printf '%s %s' "$1" "$(jq -c '{expired, expiry}' "$LAB/data/$1/record/data-cleanup.json")"; }

mkdir -p "$LAB/data/zz-live"
printf '# Task\n' > "$LAB/data/zz-live/brief.md"
echo
echo "=================== (b, continued) next teardowns with the same 2s budget give each cut-off hold its one full attempt"
for t in t-b3 t-b4; do
  bash "$E/lab-task.sh" "$LAB" "$t"
  started=$SECONDS
  bash "$E/lab-teardown.sh" "$WT" "$LAB" "$t" FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 2>&1 | stamp | quiet
  echo "$t took $((SECONDS - started))s; $(rec zz-live); $(rec cc-medium); cc-medium hold: $(ls -A "$LAB/data/cc-medium/.cleanup-hold" 2>/dev/null | tr '\n' ' ')"
  echo "pending now: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"
done
