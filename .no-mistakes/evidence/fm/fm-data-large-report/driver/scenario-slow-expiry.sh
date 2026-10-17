#!/usr/bin/env bash
# Live: expiring another task's slow hold runs after teardown releases its locks,
# so a concurrent fm-send is not blocked; the budget bounds the tail; unvisited
# holds are named; the next teardown reaches the hold the slow one starved.
# The slow hold is real: it names 40 beads that live in the project's br db.
# Usage: scenario-slow-expiry.sh [code-root]   (default: the run worktree)
. "$(dirname "$0")/lab-env.sh"
CODE=${1:-$ROOT}
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "code root: $CODE"
echo "lab home: $LAB"
lab_project "$LAB"
FAILS=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS: $what"; else echo "FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
now() { python3 -c 'import time; print("%.2f" % time.time())'; }
since() { python3 -c "print('%.1f' % ($(now) - $1))"; }

beads=()
for ((n = 0; n < 40; n++)); do
  beads+=("$(lab_bead "$LAB/projects/demo" "slow $n" "slow bead $n")")
done
pending_hold() { # <task> <beads-json> <touch-stamp>
  mkdir -p "$LAB/data/$1/record" "$LAB/data/$1/.cleanup-hold"
  printf 'held scratch\n' > "$LAB/data/$1/.cleanup-hold/scratch.bin"
  jq -n --arg task "$1" --arg project "$LAB/projects/demo" --arg data "$LAB/data" --argjson beads "$2" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: $beads, backlog: {data: $data, task: null}}]}' \
    > "$LAB/data/$1/record/data-cleanup.json"
  touch -t "$3" "$LAB/data/$1/record/data-cleanup.json"
}
pending_hold old-slow "$(printf '%s\n' "${beads[@]}" | jq -R . | jq -sc .)" 202001010000
pending_hold young-fast '[]' 202101010000

# A live task whose endpoint is a real pane on the lab's private tmux socket.
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s sess -n fm-live-y -x 120 -y 30
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
SERVER_PID=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}')
printf '%s\n' "window=sess:fm-live-y" "endpoint_task_id=live-y" kind=ship harness=claude \
  "project=$LAB/projects/demo" "worktree=$LAB/live-y-wt" spawn_gen=live-y > "$LAB/state/live-y.meta"

lab_task "$LAB" t-main
echo; echo "== teardown t-main (FM_SUPERVISION_ACTOR=main, budget 8s) with holds old-slow (40 beads, oldest) and young-fast =="
t0=$(now)
env FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 "$CODE/bin/fm-teardown.sh" t-main > "$LAB/t-main.out" 2> "$LAB/t-main.err" &
TD=$!
expiring=0
for ((i = 0; i < 1200; i++)); do
  if pgrep -f "fm-task-data.py expire $LAB/data $LAB/state old-slow" >/dev/null 2>&1; then expiring=1; break; fi
  kill -0 "$TD" 2>/dev/null || break
  sleep 0.1
done
echo "old-slow expiry running: $expiring (after $(since "$t0")s)"
echo "-- lock files while old-slow expires:"; ls -d "$LAB"/state/.fm-lease-command.lock "$LAB"/state/.meta-*.lock 2>&1
lease_held=1; [ -e "$LAB/state/.fm-lease-command.lock" ] || lease_held=0
own_held=1; [ -e "$LAB/state/.meta-t-main.lock" ] || own_held=0
ts=$(now)
env TMUX="$SOCK,$SERVER_PID,0" FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 \
  "$CODE/bin/fm-send.sh" live-y "steer during expiry" > "$LAB/send.out" 2> "$LAB/send.err"
SEND_RC=$?
send_secs=$(since "$ts")
td_alive=0; kill -0 "$TD" 2>/dev/null && td_alive=1
echo "fm-send exit=$SEND_RC after ${send_secs}s; teardown still running: $td_alive"
echo "-- fm-send stdout"; cat "$LAB/send.out"; echo "-- fm-send stderr"; cat "$LAB/send.err"
echo "-- live-y inbox"; ls "$LAB/state/live-y.inbox" 2>&1
echo "-- live-y pane"; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t sess:fm-live-y | sed '/^$/d' | tail -5
wait "$TD"; RC=$?
total=$(since "$t0")
tb=$(now)
env TMUX="$SOCK,$SERVER_PID,0" FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 \
  "$CODE/bin/fm-send.sh" live-y "uncontended baseline steer" > "$LAB/send2.out" 2> "$LAB/send2.err"
echo "uncontended baseline fm-send exit=$? after $(since "$tb")s (contended send took ${send_secs}s)"
echo "teardown exit=$RC total ${total}s"
echo "-- stdout"; cat "$LAB/t-main.out"; echo "-- stderr"; cut -c1-400 "$LAB/t-main.err"
echo "-- old-slow record"; cat "$LAB/data/old-slow/record/data-cleanup.json"; echo
check "old-slow expiry was observed running" [ "$expiring" = 1 ]
check "the home-wide lease lock is free while another task's hold expires" [ "$lease_held" = 0 ]
check "t-main's own meta lock is free while another task's hold expires" [ "$own_held" = 0 ]
check "concurrent fm-send exits 0" [ "$SEND_RC" = 0 ]
check "teardown was still expiring when fm-send finished" [ "$td_alive" = 1 ]
check "fm-send recorded its steer" [ -e "$LAB/state/live-y.inbox/001.msg" ]
check "teardown exits 0" [ "$RC" = 0 ]
check "t-main backlog row is done" [ "$(row_state "$LAB" t-main)" = done ]
check "old-slow keeps its held data after the cut-off" [ -e "$LAB/data/old-slow/.cleanup-hold/scratch.bin" ]
check "young-fast was not visited past the budget" [ -e "$LAB/data/young-fast/.cleanup-hold/scratch.bin" ]
check "teardown names the unvisited hold" grep -qF "holds left for a later teardown: young-fast" "$LAB/t-main.err"
check "teardown says the cut-off hold gets one full attempt" grep -qF "task data old-slow expiry stopped after" "$LAB/t-main.err"
check "old-slow record is marked cut-off" [ "$(jq -r '.expiry // ""' "$LAB/data/old-slow/record/data-cleanup.json")" = cut-off ]

lab_task "$LAB" t-next
echo; echo "== teardown t-next (default budget 10s, full attempt 60s) =="
t1=$(now)
lab_teardown "$LAB" t-next > "$LAB/t-next.out" 2> "$LAB/t-next.err"; RC=$?
echo "teardown exit=$RC total $(since "$t1")s"
echo "-- stderr"; cut -c1-400 "$LAB/t-next.err"
echo "-- old-slow record"; cat "$LAB/data/old-slow/record/data-cleanup.json"; echo
check "t-next exits 0" [ "$RC" = 0 ]
check "the next teardown reached and expired young-fast first" [ ! -e "$LAB/data/young-fast/.cleanup-hold" ]
check "old-slow's one full attempt expired it" [ ! -e "$LAB/data/old-slow/.cleanup-hold" ]
check "old-slow's completed attempt cleared its mark" jq -e '.expired == true and (has("expiry") | not)' "$LAB/data/old-slow/record/data-cleanup.json"

TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server
echo
echo "lab home to remove: $LAB"
echo "FAILS=$FAILS"
