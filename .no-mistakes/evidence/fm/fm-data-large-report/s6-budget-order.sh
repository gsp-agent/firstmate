#!/usr/bin/env bash
# Live scenario in a second, clean lab:
#  (a) 3,000 already-expired cleanup records older than the one live hold do
#      not use up the expiry budget: the live hold expires on the next teardown.
#  (b) a hold the 2s budget cuts off is marked cut-off; the next teardown gives
#      it one full attempt (default 60s cap) which completes, expires the hold
#      and clears the mark.
# Usage: s6-budget-order.sh <worktree> <lab2>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
quiet() { grep -v "watcher still down\|WATCHER DOWN\|●\|fm-gate-refuse\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g" | sed -E 's/(dcg refused cleanup: ).*/\1<dcg evaluation-timeout JSON elided>/'; }
rec() { printf '%s %s' "$1" "$(jq -c '{expired, expiry}' "$LAB/data/$1/record/data-cleanup.json")"; }

echo "=================== (a) 3,000 expired records dated 2020 plus one live hold dated 2021"
mkdir -p "$LAB/data/zz-live"
printf '# Task\n' > "$LAB/data/zz-live/brief.md"
printf 'held scratch\n' > "$LAB/data/zz-live/scratch.bin"
(cd "$WT" && python3 bin/fm-task-data.py stage "$LAB/data" "$LAB/state" zz-live "$proj" '') >/dev/null
touch -t 202101010000 "$LAB/data/zz-live/record/data-cleanup.json"
python3 - "$LAB/data" <<'PY'
import json, os, sys
for number in range(3000):
    task = f"done-{number}"
    record = os.path.join(sys.argv[1], task, "record")
    os.makedirs(record)
    path = os.path.join(record, "data-cleanup.json")
    with open(path, "w") as stream:
        json.dump({"version": 1, "task": task, "complete": True, "expired": True,
                   "sources": [{"project": "", "pr": "", "beads": []}]}, stream)
    os.utime(path, (1577836800, 1577836800))
PY
echo "records in data/: $(ls "$LAB/data" | wc -l | tr -d ' ') folders; pending listing: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"
bash "$E/lab-task.sh" "$LAB" t-a
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-a 2>&1 | stamp | quiet
echo "after t-a: $(rec zz-live); hold left: $(ls -A "$LAB/data/zz-live/.cleanup-hold" 2>/dev/null | tr '\n' ' ')"

echo
echo "=================== (b) a hold whose expiry needs longer than the 2s budget"
beads=$(for i in $(seq 1 15); do (cd "$proj" && br create "medium bead $i" -d "nothing linked" --json | jq -r .id); done | sed 's/^/Bead: /')
mkdir -p "$LAB/data/cc-medium"
printf '# Task\n' > "$LAB/data/cc-medium/brief.md"
printf 'held scratch\n' > "$LAB/data/cc-medium/scratch.bin"
(cd "$WT" && python3 bin/fm-task-data.py stage "$LAB/data" "$LAB/state" cc-medium "$proj" '') >/dev/null
printf '# Task\n%s\n' "$beads" > "$LAB/data/cc-medium/brief.md"
echo "cc-medium brief names $(grep -c '^Bead:' "$LAB/data/cc-medium/brief.md") beads"
bash "$E/lab-task.sh" "$LAB" t-b1
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-b1 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 2>&1 | stamp | quiet
echo "after t-b1: $(rec cc-medium); hold: $(ls -A "$LAB/data/cc-medium/.cleanup-hold" 2>/dev/null | tr '\n' ' ')"
bash "$E/lab-task.sh" "$LAB" t-b2
started=$SECONDS
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-b2 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 2>&1 | stamp | quiet
echo "t-b2 took $((SECONDS - started))s"
echo "after t-b2: $(rec cc-medium); hold: $(ls -A "$LAB/data/cc-medium/.cleanup-hold" 2>/dev/null | tr '\n' ' '); brief kept: $(test -f "$LAB/data/cc-medium/brief.md" && echo yes)"
echo "pending now: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"
# continued in s6b-full-attempt.sh
