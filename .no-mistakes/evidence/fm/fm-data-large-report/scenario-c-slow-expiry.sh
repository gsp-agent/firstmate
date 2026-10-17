#!/usr/bin/env bash
# Scenario C: expiring another task's slow hold (real br reads of many named
# beads) runs after teardown releases its locks, so a concurrent fm-send to a
# live task finishes while expiry is still reading; expiry stops at
# FM_TEARDOWN_DATA_EXPIRE_TIMEOUT and keeps the unfinished hold's data; the
# next teardown visits the least recently tried hold first, so a fast hold the
# slow one starved is expired.
# Usage: scenario-c-slow-expiry.sh <fresh-empty-lab-dir> <fresh-empty-home-dir>
# ROOT=<code root> selects the code under test (default: the run worktree).
. "$(dirname "$0")/lab-common.sh"
trap lab_down EXIT
lab_up
NB=${NB:-100}
B2=${B2:-15}
B3=${B3:-8}
since() { awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }'; }
mtime() { stat -f %m "$LAB/data/$1/record/data-cleanup.json"; }
say "code under test: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo archive))"

say "creating $NB beads in the project's real br database"
BEADS=()
for ((i = 1; i <= NB; i++)); do
  BEADS+=("$(cd "$P" && hbr create "slow ref $i" -d "reference $i" --json | jq -r .id)")
done
say "    first=${BEADS[0]} last=${BEADS[$((NB - 1))]}"

say ""
say "=== C-setup: task old-slow names $NB beads; its own teardown stages a hold ==="
add_task old-slow
for b in "${BEADS[@]}"; do printf 'Bead %s\n' "$b"; done > "$LAB/data/old-slow/brief.md"
printf 'held scratch\n' > "$LAB/data/old-slow/scratch.bin"
t0=$EPOCHREALTIME
teardown old-slow; rc=$?
say "    old-slow's own teardown took $(since "$t0")s (its prepare and stage read every bead under its own lock; unchanged by this PR)"
check "C-setup old-slow teardown exits 0" [ "$rc" = 0 ]
check "C-setup old-slow hold staged" [ -f "$LAB/data/old-slow/.cleanup-hold/scratch.bin" ]

say ""
say "=== C-lock: teardown young-fast (budget ${B2}s) expires old-slow's hold while fm-send steers live task live-y ==="
add_task young-fast
printf 'scratch\n' > "$LAB/data/young-fast/scratch.bin"
fm tasks-axi add live-y 'live task' --kind ship --file "$LAB/data/backlog.md" >/dev/null
fm tasks-axi start live-y --file "$LAB/data/backlog.md" >/dev/null
ltmux new-window -d -t firstmate -n fm-live-y 'cat'
printf '%s\n' "window=firstmate:fm-live-y" "endpoint_task_id=live-y" "worktree=$LAB/gone-live-y" \
  "project=$P" "kind=ship" "mode=local-only" "spawn_gen=lab-live-y" "harness=claude" > "$LAB/state/live-y.meta"
old_mtime=$(mtime old-slow)
sleep 1.2
mkdir -p "$H/out"
t0=$EPOCHREALTIME
fm FM_TEARDOWN_DATA_EXPIRE_TIMEOUT="$B2" "$ROOT/bin/fm-teardown.sh" young-fast \
  > "$H/out/young-fast.out" 2> "$H/out/young-fast.err" &
tpid=$!
# Expiry of old-slow has begun once its record is rewritten (each attempt
# rewrites the record before reading references).
for ((i = 0; i < 3000; i++)); do
  [ "$(mtime old-slow)" != "$old_mtime" ] && break
  kill -0 "$tpid" 2>/dev/null || break
  sleep 0.1
done
say "    expiry of old-slow began $(since "$t0")s after teardown start"
t_exp=$EPOCHREALTIME
s0=$EPOCHREALTIME
fm FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" live-y "steer during expiry" > "$H/out/send.out" 2> "$H/out/send.err"
src=$?
send_secs=$(since "$s0")
alive=no
kill -0 "$tpid" 2>/dev/null && alive=yes
say "\$ FM_HOME=<lab> bin/fm-send.sh live-y 'steer during expiry'   -> exit $src after ${send_secs}s; teardown still running: $alive"
sed 's/^/    send-out| /' "$H/out/send.out"
sed 's/^/    send-err| /' "$H/out/send.err"
check "C-lock fm-send exits 0" [ "$src" = 0 ]
check "C-lock steer recorded in live-y's inbox" [ -f "$LAB/state/live-y.inbox/001.msg" ]
check "C-lock fm-send returned while teardown was still expiring" [ "$alive" = yes ]
check "C-lock fm-send took under 10s (${send_secs}s)" awk -v s="$send_secs" 'BEGIN { exit !(s < 10) }'
wait "$tpid"; trc=$?
exp_secs=$(since "$t_exp")
say "\$ FM_HOME=<lab> FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=$B2 bin/fm-teardown.sh young-fast   -> exit $trc; expiry phase ${exp_secs}s"
sed 's/^/    out| /' "$H/out/young-fast.out"
sed 's/^/    err| /' "$H/out/young-fast.err"
check "C-lock teardown exits 0" [ "$trc" = 0 ]
check "C-lock backlog row closed (state=$(row_state young-fast))" [ "$(row_state young-fast)" = done ]
check "C-lock expiry phase bounded by the ${B2}s budget plus overhead (${exp_secs}s)" awk -v s="$exp_secs" -v b="$B2" 'BEGIN { exit !(s <= b + 6) }'
check "C-lock warning names the budget and the retry" grep -q "task data old-slow expiry stopped at the ${B2}s teardown budget; a later teardown retries it" "$H/out/young-fast.err"
check "C-lock unfinished hold keeps its data" [ -f "$LAB/data/old-slow/.cleanup-hold/scratch.bin" ]
check "C-lock old-slow record not marked expired" jq -e '.expired != true' "$LAB/data/old-slow/record/data-cleanup.json"
check "C-lock young-fast's own scratch staged" [ -f "$LAB/data/young-fast/.cleanup-hold/scratch.bin" ]
sleep 1
left=$(pgrep -fl "fm-task-data.*$LAB" || true)
say "    processes still naming the lab after teardown: ${left:-none}"
check "C-lock no expiry reader left running after the budget stop" [ -z "$left" ]

say ""
say "=== C-order: next teardown t-third (budget ${B3}s) visits the least recently tried hold first ==="
say "    record mtimes: young-fast=$(mtime young-fast) old-slow=$(mtime old-slow) (glob order would visit old-slow first)"
add_task t-third
t0=$EPOCHREALTIME
teardown t-third FM_TEARDOWN_DATA_EXPIRE_TIMEOUT="$B3"; rc=$?
say "    t-third teardown took $(since "$t0")s"
check "C-order teardown exits 0" [ "$rc" = 0 ]
check "C-order young-fast's hold expired (not starved by old-slow)" jq -e '.expired == true' "$LAB/data/young-fast/record/data-cleanup.json"
check "C-order young-fast held scratch removed" [ ! -e "$LAB/data/young-fast/.cleanup-hold" ]
check "C-order old-slow hold still keeps its data" [ -f "$LAB/data/old-slow/.cleanup-hold/scratch.bin" ]

say ""
say "RESULT: $FAILS failing check(s)"
exit "$FAILS"
