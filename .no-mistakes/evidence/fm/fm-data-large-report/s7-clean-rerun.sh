#!/usr/bin/env bash
# Clean re-run of s6 in the same second lab with DCG_HOOK_TIMEOUT_MS=5000 in the
# teardown environment, because dcg's default 200ms evaluation budget timed out
# on this heavily loaded machine and refused the deletions (a safe refusal that
# kept the holds, but it hid whether expiry itself finished).
# Usage: s7-clean-rerun.sh <worktree> <lab2>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
quiet() { grep -v "watcher still down\|WATCHER DOWN\|●\|fm-gate-refuse\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g" | sed -E 's/(dcg refused cleanup: ).*/\1<dcg evaluation-timeout JSON elided>/'; }
rec() { printf '%s %s' "$1" "$(jq -c '{expired, expiry}' "$LAB/data/$1/record/data-cleanup.json")"; }
hold() { ls -A "$LAB/data/$1/.cleanup-hold" 2>/dev/null | tr '\n' ' '; }
pending() { (cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': '); }
teardown() { # <id> [env...]
  local id=$1 started=$SECONDS
  shift
  bash "$E/lab-task.sh" "$LAB" "$id"
  bash "$E/lab-teardown.sh" "$WT" "$LAB" "$id" DCG_HOOK_TIMEOUT_MS=5000 "$@" 2>&1 | stamp | quiet
  echo "$id took $((SECONDS - started))s"
}
medium_hold() { # <id>: a staged hold whose kept brief names 15 readable beads
  local beads
  beads=$(for i in $(seq 1 15); do (cd "$proj" && br create "$1 bead $i" -d "nothing linked" --json | jq -r .id); done | sed 's/^/Bead: /')
  mkdir -p "$LAB/data/$1"
  printf '# Task\n' > "$LAB/data/$1/brief.md"
  printf 'held scratch\n' > "$LAB/data/$1/scratch.bin"
  (cd "$WT" && python3 bin/fm-task-data.py stage "$LAB/data" "$LAB/state" "$1" "$proj" '') >/dev/null
  printf '# Task\n%s\n' "$beads" > "$LAB/data/$1/brief.md"
}

echo "=================== settle the leftover cc-medium hold with a 60s budget"
echo "pending: $(pending)"
teardown t-c0 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=60
echo "after t-c0: $(rec cc-medium); hold: $(hold cc-medium); pending: $(pending)"

echo
echo "=================== (a) one live hold dated 2021 behind 3,000 expired records dated 2020, default 10s budget"
mkdir -p "$LAB/data/yy-live"
printf '# Task\n' > "$LAB/data/yy-live/brief.md"
printf 'held scratch\n' > "$LAB/data/yy-live/scratch.bin"
(cd "$WT" && python3 bin/fm-task-data.py stage "$LAB/data" "$LAB/state" yy-live "$proj" '') >/dev/null
touch -t 202101010000 "$LAB/data/yy-live/record/data-cleanup.json"
echo "expired records dated 2020: $(find "$LAB/data" -path '*/record/data-cleanup.json' -newermt 2019-12-31 ! -newermt 2020-01-02 | wc -l | tr -d ' '); pending: $(pending)"
s0=$(perl -MTime::HiRes=time -e 'print time'); (cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" >/dev/null); s1=$(perl -MTime::HiRes=time -e 'print time')
printf 'listing pending holds across %s records took %.2fs\n' "$(ls "$LAB/data" | wc -l | tr -d ' ')" "$(echo "$s1 - $s0" | bc)"
teardown t-c1
echo "after t-c1: $(rec yy-live); hold left: $(hold yy-live)"

echo
echo "=================== (b) ee-medium needs longer than a 2s budget: cut off once, then one full attempt finishes it"
medium_hold ee-medium
teardown t-c2 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2
echo "after t-c2: $(rec ee-medium); hold: $(hold ee-medium)"
teardown t-c3 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2
echo "after t-c3: $(rec ee-medium); hold: $(hold ee-medium); brief kept: $(test -f "$LAB/data/ee-medium/brief.md" && echo yes); pending: $(pending)"
