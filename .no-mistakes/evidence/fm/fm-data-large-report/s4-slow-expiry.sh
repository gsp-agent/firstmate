#!/usr/bin/env bash
# Live scenario: a teardown whose expiry of ANOTHER task's hold is slow must
# not hold the home-wide lease lock or its own meta lock while it expires, must
# stop at FM_TEARDOWN_DATA_EXPIRE_TIMEOUT, must name the holds it never reached,
# and the next teardown must visit the hold it skipped before the slow one.
# Usage: s4-slow-expiry.sh <worktree> <lab> [bin-dir-to-run]
set -uo pipefail
WT=${1:?} LAB=${2:?} RUN_BIN=${3:-$1/bin}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
state_locks() { for l in "$LAB"/state/.fm-lease-command.lock "$LAB"/state/.meta-*.lock; do [ -d "$l" ] && echo "    held: ${l##*/} (pid $(cat "$l/pid" 2>/dev/null))"; done; true; }

# Two finished tasks' holds, made by the product's own stage command:
# aa-slow (older) whose kept brief names 40 beads, bb-young (newer) naming none.
beads=$(for i in $(seq 1 40); do (cd "$proj" && br create "slow bead $i" -d "nothing linked" --json | jq -r .id); done | sed 's/^/Bead: /')
for held in aa-slow bb-young; do
  mkdir -p "$LAB/data/$held"
  printf '# Task\n' > "$LAB/data/$held/brief.md"
  printf 'held scratch\n' > "$LAB/data/$held/scratch.bin"
  (cd "$WT" && python3 bin/fm-task-data.py stage "$LAB/data" "$LAB/state" "$held" "$proj" '') >/dev/null
done
printf '# Task\n%s\n' "$beads" > "$LAB/data/aa-slow/brief.md"
touch -t 202001010000 "$LAB/data/aa-slow/record/data-cleanup.json"
touch -t 202101010000 "$LAB/data/bb-young/record/data-cleanup.json"
echo "holds before: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | cut -f1 | tr '\n' ' ')"
echo "aa-slow brief names $(grep -c '^Bead:' "$LAB/data/aa-slow/brief.md") beads"

# A live task to steer while the teardown is expiring.
bash "$E/lab-task.sh" "$LAB" live-y
printf 'harness=claude\n' >> "$LAB/state/live-y.meta"
bash "$E/lab-task.sh" "$LAB" t-main
printf '# Task\n' > "$LAB/data/t-main/brief.md"

echo "=================== teardown t-main as the main supervision actor, expiry budget 8s"
: > "$E/s4-teardown.out"
started=$SECONDS
FM_SUPERVISION_ACTOR=main bash "$E/lab-teardown.sh" "$WT" "$LAB" t-main FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 \
  > >(stamp > "$E/s4-teardown.out") 2>&1 &
td=$!
for ((i = 0; i < 1200; i++)); do grep -q "teardown t-main complete" "$E/s4-teardown.out" 2>/dev/null && break; sleep 0.1; done
sleep 1
echo "t-main printed 'complete' after $((SECONDS - started))s; teardown process still running: $(kill -0 $td 2>/dev/null && echo yes || echo no)"
echo "locks held in state/ while t-main expires other holds:"; state_locks
echo "children of the teardown now:"; pgrep -fl "fm-task-data.py expire" | sed 's/^/    /' | sed "s#$LAB#<lab>#g"
s0=$(perl -MTime::HiRes=time -e 'print time')
(cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" HOME="$LAB/home" FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 \
  TMUX_TMPDIR="$LAB/tmux" TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}'),0" \
  "$RUN_BIN/fm-send.sh" live-y "steer during expiry") > "$E/s4-send.out" 2>&1
send_rc=$?
s1=$(perl -MTime::HiRes=time -e 'print time')
printf 'concurrent fm-send exit %s in %.2fs; teardown still running when it returned: %s\n' "$send_rc" "$(echo "$s1 - $s0" | bc)" "$(kill -0 $td 2>/dev/null && echo yes || echo no)"
ls "$LAB/state/live-y.inbox/" 2>/dev/null | sed 's/^/    inbox: /'
wait $td; rc=$?
echo "t-main teardown exit $rc after $((SECONDS - started))s total"
echo "--- t-main output (elapsed since start):"; grep -v "watcher still down\|WATCHER DOWN\|●\|Run bin/fm-tasks-axi.sh ready" "$E/s4-teardown.out" | sed "s#$LAB#<lab>#g"
echo "--- aa-slow: $(ls -A "$LAB/data/aa-slow/.cleanup-hold" 2>/dev/null | tr '\n' ' ') record $(jq -c '{expired, expiry}' "$LAB/data/aa-slow/record/data-cleanup.json")"
echo "--- bb-young: $(ls -A "$LAB/data/bb-young/.cleanup-hold" 2>/dev/null | tr '\n' ' ') record $(jq -c '{expired, expiry}' "$LAB/data/bb-young/record/data-cleanup.json")"
echo "--- pending order now: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"

echo
echo "=================== next teardown t-next (default budgets): the skipped young hold goes first"
bash "$E/lab-task.sh" "$LAB" t-next
started=$SECONDS
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-next 2>&1 | stamp | grep -v "watcher still down\|fm-gate-refuse\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g"
echo "t-next teardown took $((SECONDS - started))s"
echo "--- aa-slow: hold $(ls -A "$LAB/data/aa-slow/.cleanup-hold" 2>/dev/null | tr '\n' ' ') record $(jq -c '{expired, expiry}' "$LAB/data/aa-slow/record/data-cleanup.json")"
echo "--- bb-young: hold $(ls -A "$LAB/data/bb-young/.cleanup-hold" 2>/dev/null | tr '\n' ' ') record $(jq -c '{expired, expiry}' "$LAB/data/bb-young/record/data-cleanup.json")"
echo "--- pending order now: $(cd "$WT" && python3 bin/fm-task-data.py pending "$LAB/data" | tr '\t\n' ': ')"
