#!/usr/bin/env bash
# Live scenario 3: expiring other tasks' holds runs after teardown releases its
# locks, within its budget; a cut-off hold gets one full attempt, then is marked
# too large, skipped and named; the advertised by-hand command takes the task
# lock. Expired records never use the budget. Slowness comes from real br reads.
set -u
. "$(dirname "$0")/lab-lib.sh"
FAILS=0
NBEADS=${NBEADS:-400}
lab_new || exit 1
echo "$LAB" >> "$(dirname "$0")/labs.txt"
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
since() { python3 -c "import time; print(round(time.time() - $1, 1))"; }
show() { sed 's/^/  out| /' "$LAB/$1.out"; grep -v -e 'WATCHER\|watcher\|━\|^●' -e '^Backlog\|Run bin/fm-tasks-axi' "$LAB/$1.err" | sed 's/^/  err| /'; }

lab_br "$PROJ" init --prefix tst -q
python3 -c "print('\n'.join(f'## slow bead {i}\n\nbody {i}\n' for i in range($NBEADS)))" > "$LAB/bulk.md"
lab_br "$PROJ" create -f "$LAB/bulk.md" --silent >/dev/null 2>&1
lab_br "$PROJ" list --json --limit 0 2>/dev/null | jq -r '.issues[].id' > "$LAB/bead-ids"
echo "real project beads: $(wc -l < "$LAB/bead-ids" | tr -d ' ') in $PROJ/.beads"

echo "== setup H: a real teardown of a task naming every bead, stage limit raised so it stages (one br read per bead)"
lab_task lab-slow
H="$LAB/data/lab-slow"; mkdir -p "$H"
sed 's/^/Bead /' "$LAB/bead-ids" > "$H/brief.md"; printf 'held scratch\n' > "$H/scratch.bin"
t0=$(now); lab_teardown lab-slow FM_TEARDOWN_DATA_STAGE_TIMEOUT=600 > "$LAB/h.out" 2> "$LAB/h.err"; rc=$?
show h; echo "  timing: ${NBEADS}-bead task teardown $(since "$t0")s"
check "H staged (complete hold)" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.complete == true' "$H/record/data-cleanup.json" >/dev/null

echo "== setup F: a small task torn down while another process holds H's task lock (a concurrent teardown); H is skipped untouched"
"$(dirname "$0")/hold-lock.sh" "$WT" "$LAB/state/.meta-lab-slow.lock" "$LAB/holder-ready" & holder=$!
for _ in $(seq 100); do [ -e "$LAB/holder-ready" ] && break; sleep 0.1; done
lab_task lab-fast
F="$LAB/data/lab-fast"; mkdir -p "$F"; printf 'fast scratch\n' > "$F/scratch.bin"
sleep 1
lab_teardown lab-fast > "$LAB/f.out" 2> "$LAB/f.err"; rc=$?
kill -TERM "$holder"; wait "$holder" 2>/dev/null
show f
check "F staged" [ -f "$F/.cleanup-hold/scratch.bin" ]
check "H skipped while its lock was held: no mark, hold intact" jq -e '(has("expiry") | not) and .expired == false' "$H/record/data-cleanup.json"
check "H's lock released by holder" [ ! -e "$LAB/state/.meta-lab-slow.lock" ]

echo "== T1: teardown with an 8s budget; H (oldest) is slow; fm-send to a live task runs during the expiry"
lab_task lab-live
lab_task lab-t1
t0=$(now)
( cd "$WT" && lab_env FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 "$WT/bin/fm-teardown.sh" lab-t1 ) > "$LAB/t1.out" 2> "$LAB/t1.err" & tpid=$!
seen=0
for _ in $(seq 600); do
  if pgrep -f "fm-task-data.py expire $LAB/data $LAB/state lab-slow" >/dev/null; then seen=1; break; fi
  kill -0 "$tpid" 2>/dev/null || break; sleep 0.1
done
check "teardown reached H's expiry" [ "$seen" = 1 ]
sleep 1
echo "  during expiry: lease lock entries: $(ls -d "$LAB"/state/.fm-lease-command.lock* 2>/dev/null | wc -l | tr -d ' '); lab-t1 meta lock: $(ls -d "$LAB"/state/.meta-lab-t1.lock 2>/dev/null | wc -l | tr -d ' '); lab-t1 record present: $([ -e "$LAB/state/lab-t1.meta" ] && echo yes || echo no); lab-t1 row: $(row_state lab-t1); br reads running: $(pgrep -f "br show tst-" | wc -l | tr -d ' ')"
check "task's own meta lock already released during expiry" [ ! -e "$LAB/state/.meta-lab-t1.lock" ]
check "task record already retired and row closed before expiry ends" [ ! -e "$LAB/state/lab-t1.meta" ] && [ "$(row_state lab-t1)" = done ]
s0=$(now)
( cd "$WT" && lab_env FM_SEND_SETTLE=0 "$WT/bin/fm-send.sh" lab-live "steer during expiry" ) > "$LAB/send.out" 2> "$LAB/send.err"; src=$?
send_s=$(since "$s0")
alive=no; kill -0 "$tpid" 2>/dev/null && alive=yes
echo "  fm-send rc=$src in ${send_s}s; teardown still expiring when it returned: $alive"
sed 's/^/  send-out| /' "$LAB/send.out"; grep -v -e 'WATCHER\|watcher\|━\|^●' "$LAB/send.err" | sed 's/^/  send-err| /'
check "concurrent fm-send finished in under 5s (${send_s}s)" python3 -c "import sys; sys.exit(0 if $send_s < 5 else 1)"
check "teardown was still expiring when fm-send returned" [ "$alive" = yes ]
check "fm-send delivered the steer (pane or inbox)" sh -c "TMUX_TMPDIR='$LAB/tmux' tmux -L fm-lab capture-pane -p -t firstmate:fm-lab-live | grep -q 'steer during expiry' || ls '$LAB/state/lab-live.inbox/'*.msg >/dev/null 2>&1"
wait "$tpid"; rc=$?; t1s=$(since "$t0")
show t1; echo "  timing: T1 teardown ${t1s}s"
check "T1 exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "H cut off: hold intact and marked cut-off" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "cut-off" and .expired == false' "$H/record/data-cleanup.json" >/dev/null
check "cut-off warning promises one full attempt" grep -qF "task data lab-slow expiry stopped after" "$LAB/t1.err"
check "budget warning names the unvisited F" grep -qF "holds left for a later teardown: lab-fast" "$LAB/t1.err"
check "F untouched" [ -f "$F/.cleanup-hold/scratch.bin" ]

echo "== T2: budget 5s, full attempt 8s: F (now least recently tried) expires, then H gets exactly one full 8s attempt and is marked too large"
lab_task lab-t2
G="$LAB/data/lab-t2"; mkdir -p "$G"; printf 'g scratch\n' > "$G/scratch.bin"
t0=$(now); lab_teardown lab-t2 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=8 > "$LAB/t2.out" 2> "$LAB/t2.err"; rc=$?; t2s=$(since "$t0")
show t2; echo "  timing: T2 teardown ${t2s}s"
check "T2 exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "F expired first" [ ! -e "$F/.cleanup-hold" ] && jq -e '.expired == true' "$F/record/data-cleanup.json" >/dev/null
check "H marked too-large, rest of hold kept" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "warning says one full 8s attempt and advertises the by-hand command" grep -qF "expiry stopped after its one full 8s attempt" "$LAB/t2.err"
check "advertised command names fm-task-data-lib.sh expire with this home" grep -qF "expire it by hand with bash $WT/bin/fm-task-data-lib.sh expire $LAB/data $LAB/state lab-slow" "$LAB/t2.err"

echo "== T3: 3000 expired records dated 2020 plus G's live hold; H is skipped and named without using the budget"
python3 - "$LAB/data" <<'PY'
import json, os, sys
data = sys.argv[1]
for n in range(3000):
    d = os.path.join(data, f"old-{n:04}", "record"); os.makedirs(d)
    p = os.path.join(d, "data-cleanup.json")
    json.dump({"version": 1, "task": f"old-{n:04}", "sources": [], "complete": True, "expired": True}, open(p, "w"))
    os.utime(p, (1577836800, 1577836800))
PY
lab_task lab-t3
t0=$(now); lab_teardown lab-t3 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5 > "$LAB/t3.out" 2> "$LAB/t3.err"; rc=$?; t3s=$(since "$t0")
show t3; echo "  timing: T3 teardown ${t3s}s"
check "T3 exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "G's live hold expired despite 3000 older expired records" [ ! -e "$G/.cleanup-hold" ]
check "H skipped and named as too large" grep -qF "task data holds too large to expire automatically, skipped and kept for expiry by hand: lab-slow" "$LAB/t3.err"
check "H still held and still too-large" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "no budget-ran-out warning" sh -c "! grep -q 'expiry budget ran out' '$LAB/t3.err'"

echo "== by hand: refused while another process holds H's lock"
rm -f "$LAB/holder-ready"
"$(dirname "$0")/hold-lock.sh" "$WT" "$LAB/state/.meta-lab-slow.lock" "$LAB/holder-ready" & holder=$!
for _ in $(seq 100); do [ -e "$LAB/holder-ready" ] && break; sleep 0.1; done
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-slow ) > "$LAB/bh1.out" 2> "$LAB/bh1.err"; rc=$?
kill -TERM "$holder"; wait "$holder" 2>/dev/null
show bh1
check "refused with exit 1 (rc=$rc)" [ "$rc" = 1 ]
check "refusal says locked by another process" grep -qF "task lab-slow is locked by another process; nothing was expired" "$LAB/bh1.err"
check "nothing expired" [ -f "$H/.cleanup-hold/scratch.bin" ]

echo "== by hand: refused for a live task"
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-live ) > "$LAB/bh2.out" 2> "$LAB/bh2.err"; rc=$?
show bh2
check "refused with exit 1 (rc=$rc)" [ "$rc" = 1 ]
check "refusal says the task is live" grep -qF "task lab-live is live; nothing was expired" "$LAB/bh2.err"
check "live task's lock released after refusal" [ ! -e "$LAB/state/.meta-lab-live.lock" ]

echo "== by hand: expires H with no time limit under its lock"
t0=$(now)
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-slow ) > "$LAB/bh3.out" 2> "$LAB/bh3.err" & bpid=$!
locked=0
for _ in $(seq 300); do [ -e "$LAB/state/.meta-lab-slow.lock" ] && { locked=1; break; }; kill -0 "$bpid" 2>/dev/null || break; sleep 0.05; done
wait "$bpid"; rc=$?; bhs=$(since "$t0")
show bh3; echo "  timing: by-hand expiry ${bhs}s (longer than the 8s full attempt)"
check "by-hand exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "by-hand held H's meta lock while running" [ "$locked" = 1 ]
check "lock released after" [ ! -e "$LAB/state/.meta-lab-slow.lock" ]
check "H expired, mark cleared" [ ! -e "$H/.cleanup-hold" ] && jq -e '.expired == true and (has("expiry") | not)' "$H/record/data-cleanup.json" >/dev/null
check "H's kept brief survives" [ -f "$H/brief.md" ]
echo "== external calls the stubs absorbed:"; sort "$LAB/external-calls.log" 2>/dev/null | uniq -c | sed 's/^/  /' | head
lab_end
echo "FAILS=$FAILS"
