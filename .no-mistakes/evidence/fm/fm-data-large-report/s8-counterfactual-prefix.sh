#!/usr/bin/env bash
# Counterfactual: the same two defect scenarios driven against the PRE-FIX code
# (upstream-lean 4470e616, extracted with git archive into a third lab), to show
# what this branch changes.
#  (1) a kept 1.4 MB report.md
#  (2) a concurrent fm-send while teardown expires a slow hold of another task
# Usage: s8-counterfactual-prefix.sh <worktree> <lab3> <old-tree>
set -uo pipefail
WT=${1:?} LAB=${2:?} OLD=${3:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"
stamp() { perl -MTime::HiRes=time -ne 'BEGIN{$t0=time} printf "[%5.1fs] %s", time-$t0, $_; $|=1'; }
quiet() { grep -v "watcher still down\|WATCHER DOWN\|●\|Run bin/fm-tasks-axi.sh ready" | sed "s#$LAB#<lab>#g;s#$OLD#<pre-fix>#g"; }
row() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
state_locks() { for l in "$LAB"/state/.fm-lease-command.lock "$LAB"/state/.meta-*.lock; do [ -d "$l" ] && echo "    held: ${l##*/}"; done; true; }
tmux_env() { printf 'TMUX=%s,%s,0' "$LAB/tmux/tmux-$(id -u)/fm-lab" "$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}')"; }
old_teardown() { # <id> [env...]
  local id=$1
  shift
  (cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u BEADS_DIR -u BEADS_DB -u BR_DB \
    FM_HOME="$LAB" HOME="$LAB/home" TMUX_TMPDIR="$LAB/tmux" "$(tmux_env)" "$@" "$OLD/bin/fm-teardown.sh" "$id")
}

echo "=================== (1) pre-fix: teardown of a task with a 1.4 MB report.md"
bash "$E/lab-task.sh" "$LAB" t-bigreport
d="$LAB/data/t-bigreport"
mkdir -p "$d/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$d/report.md"
printf 'image\n' > "$d/proof/capture.png"
printf 'scratch\n' > "$d/scratch.bin"
old_teardown t-bigreport 2>&1 | quiet
echo "--- exit ${PIPESTATUS[0]}; backlog row: $(row t-bigreport); pending close: $( [ -e "$LAB/state/t-bigreport.backlog-close" ] && tr '\n' ' ' < "$LAB/state/t-bigreport.backlog-close" || echo none); task record: $( [ -e "$LAB/state/t-bigreport.meta" ] && echo present || echo retired)"

echo
echo "=================== (2) pre-fix: concurrent fm-send while teardown expires another task's slow hold"
beads=$(for i in $(seq 1 40); do (cd "$proj" && br create "slow bead $i" -d "nothing linked" --json | jq -r .id); done | sed 's/^/Bead: /')
mkdir -p "$LAB/data/aa-slow"
printf '# Task\n' > "$LAB/data/aa-slow/brief.md"
printf 'held scratch\n' > "$LAB/data/aa-slow/scratch.bin"
(cd "$WT" && python3 "$OLD/bin/fm-task-data.py" stage "$LAB/data" "$LAB/state" aa-slow "$proj" '') >/dev/null
printf '# Task\n%s\n' "$beads" > "$LAB/data/aa-slow/brief.md"
bash "$E/lab-task.sh" "$LAB" live-y
printf 'harness=claude\n' >> "$LAB/state/live-y.meta"
bash "$E/lab-task.sh" "$LAB" t-main
started=$SECONDS
old_teardown t-main FM_SUPERVISION_ACTOR=main > >(stamp > "$E/s8-old-teardown.out") 2>&1 &
td=$!
for ((i = 0; i < 3000; i++)); do pgrep -f "fm-task-data.py expire .* aa-slow$" >/dev/null && break; sleep 0.1; done
echo "pre-fix teardown began expiring aa-slow after $((SECONDS - started))s; printed 'complete' yet: $(grep -q 'teardown t-main complete' "$E/s8-old-teardown.out" && echo yes || echo no)"
echo "locks held in state/ while the pre-fix teardown expires aa-slow:"; state_locks
s0=$(perl -MTime::HiRes=time -e 'print time')
(cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" HOME="$LAB/home" FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 \
  TMUX_TMPDIR="$LAB/tmux" "$(tmux_env)" "$OLD/bin/fm-send.sh" live-y "steer during expiry") > "$E/s8-old-send.out" 2>&1
send_rc=$?
s1=$(perl -MTime::HiRes=time -e 'print time')
printf 'pre-fix concurrent fm-send exit %s in %.2fs; expire of aa-slow still running when it returned: %s\n' "$send_rc" "$(echo "$s1 - $s0" | bc)" \
  "$(pgrep -f "fm-task-data.py expire .* aa-slow$" >/dev/null && echo yes || echo no)"
wait "$td"
echo "pre-fix t-main teardown exit $? after $((SECONDS - started))s"
echo "--- pre-fix t-main output:"; quiet < "$E/s8-old-teardown.out"
