#!/usr/bin/env bash
# Live scenario 4 (redo of 3 with the lease lock engaged and calibrated holds).
# Part A: with FM_SUPERVISION_ACTOR=main, fm-send waits on a held lease lock
# (control), yet completes while a teardown is still expiring other holds.
# Part B: cut-off -> one full attempt -> too-large -> skipped/named -> by hand.
# Hold records use the shape stage writes; expiry reads 150 real beads with br.
set -u
. "$(dirname "$0")/lab-lib.sh"
FAILS=0
NBEADS=${NBEADS:-150}
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
since() { python3 -c "import time; print(round(time.time() - $1, 1))"; }
show() { sed 's/^/  out| /' "$LAB/$1.out" | grep -v 'Run bin/fm-tasks-axi'; grep -v -e 'WATCHER\|watcher\|━\|^●' "$LAB/$1.err" | sed 's/^/  err| /'; }
make_beads() {
  lab_br "$PROJ" init --prefix tst -q
  python3 -c "print('\n'.join(f'## slow bead {i}\n\nbody {i}\n' for i in range($NBEADS)))" > "$LAB/bulk.md"
  lab_br "$PROJ" create -f "$LAB/bulk.md" --silent >/dev/null 2>&1
  lab_br "$PROJ" list --json --limit 0 2>/dev/null | jq -r '.issues[].id' > "$LAB/bead-ids"
  echo "real project beads: $(wc -l < "$LAB/bead-ids" | tr -d ' ') in $PROJ/.beads"
}
hold() { # <task> <stamp> <with-beads 0|1>
  local d="$LAB/data/$1" beads='[]'
  mkdir -p "$d/record" "$d/.cleanup-hold"
  printf 'held scratch\n' > "$d/.cleanup-hold/scratch.bin"; printf 'brief\n' > "$d/brief.md"
  [ "$3" = 0 ] || beads=$(jq -R . "$LAB/bead-ids" | jq -s .)
  jq -n --arg task "$1" --arg project "$PROJ" --arg data "$LAB/data" --argjson beads "$beads" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: $beads, backlog: {data: $data, task: null}}]}' > "$d/record/data-cleanup.json"
  touch -t "$2" "$d/record/data-cleanup.json"
}
send_live() { ( cd "$WT" && lab_env FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 "$WT/bin/fm-send.sh" lab-live "$1" ); }

echo "######## Part A: lease lock engaged (FM_SUPERVISION_ACTOR=main)"
lab_new || exit 1; echo "$LAB" >> "$(dirname "$0")/labs.txt"
make_beads
hold lab-h1 202001010000 1; hold lab-h2 202101010000 1
lab_task lab-live
s0=$(now); send_live "idle baseline" > "$LAB/send0.out" 2> "$LAB/send0.err"; src=$?; base=$(since "$s0")
echo "  idle fm-send baseline: rc=$src in ${base}s"
echo "== control: fm-send waits while another process holds the lease lock"
rm -f "$LAB/holder-ready"
"$(dirname "$0")/hold-lock.sh" "$WT" "$LAB/state/.fm-lease-command.lock" "$LAB/holder-ready" & holder=$!
for _ in $(seq 100); do [ -e "$LAB/holder-ready" ] && break; sleep 0.1; done
s0=$(now); send_live "behind a held lease lock" > "$LAB/sendc.out" 2> "$LAB/sendc.err" & spid=$!
sleep $(python3 -c "print(max(6, round($base * 2 + 2)))")
blocked=no; kill -0 "$spid" 2>/dev/null && blocked=yes
kill -TERM "$holder"; wait "$holder" 2>/dev/null
wait "$spid"; src=$?
echo "  control fm-send still waiting after $(python3 -c "print(max(6, round($base * 2 + 2)))")s: $blocked; finished rc=$src after $(since "$s0")s once the lock was released"
check "control: fm-send blocks on a held lease lock" [ "$blocked" = yes ]
echo "== T1: teardown (actor main, budget 30s) expires two 150-bead holds after releasing its locks; fm-send runs meanwhile"
lab_task lab-t1
t0=$(now)
( cd "$WT" && lab_env FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=30 "$WT/bin/fm-teardown.sh" lab-t1 ) > "$LAB/t1.out" 2> "$LAB/t1.err" & tpid=$!
seen=0
for _ in $(seq 1200); do
  pgrep -f "fm-task-data.py expire $LAB/data $LAB/state lab-h" >/dev/null && { seen=1; break; }
  kill -0 "$tpid" 2>/dev/null || break; sleep 0.1
done
check "teardown reached expiry of another task's hold" [ "$seen" = 1 ]
lease_held=no; { [ -e "$LAB/state/.fm-lease-command.lock" ] || [ -L "$LAB/state/.fm-lease-command.lock" ]; } && lease_held=yes
meta_held=no; [ -e "$LAB/state/.meta-lab-t1.lock" ] && meta_held=yes
echo "  at expiry start (+$(since "$t0")s): lease lock present: $lease_held; lab-t1 meta lock present: $meta_held; lab-t1 record present: $([ -e "$LAB/state/lab-t1.meta" ] && echo yes || echo no); row: $(row_state lab-t1)"
check "home-wide lease lock not held during expiry" [ "$lease_held" = no ]
check "task meta lock not held during expiry" [ "$meta_held" = no ]
s0=$(now); send_live "steer during expiry" > "$LAB/send.out" 2> "$LAB/send.err"; src=$?; sent=$(since "$s0")
alive=no; kill -0 "$tpid" 2>/dev/null && alive=yes
echo "  fm-send during expiry: rc=$src in ${sent}s (idle baseline ${base}s); teardown still expiring when it returned: $alive"
check "fm-send during expiry succeeded" [ "$src" = 0 ]
check "teardown was still expiring when fm-send returned (no wait on teardown)" [ "$alive" = yes ]
check "fm-send during expiry within baseline + 5s" python3 -c "import sys; sys.exit(0 if $sent <= $base + 5 else 1)"
wait "$tpid"; rc=$?
show t1; echo "  timing: T1 teardown $(since "$t0")s"
check "T1 exit 0 (rc=$rc)" [ "$rc" = 0 ]
for h in lab-h1 lab-h2; do echo "  $h after T1: $(jq -c '{expired, expiry}' "$LAB/data/$h/record/data-cleanup.json"); hold present: $([ -e "$LAB/data/$h/.cleanup-hold" ] && echo yes || echo no)"; done
check "both lab tmux deliveries recorded (pane or inbox)" sh -c "TMUX_TMPDIR='$LAB/tmux' tmux -L fm-lab capture-pane -p -t firstmate:fm-lab-live -S -200 | grep -q 'steer during expiry' || grep -rqs 'steer during expiry' '$LAB/state/lab-live.inbox'"
lab_end

echo "######## Part B: one full attempt, then too large, skipped, by hand"
lab_new || exit 1; echo "$LAB" >> "$(dirname "$0")/labs.txt"
make_beads
hold lab-slow 202001010000 1; hold lab-fast 202101010000 0
H="$LAB/data/lab-slow"; F="$LAB/data/lab-fast"
lab_task lab-live
echo "== Ta: budget 4s: H (least recently tried) is cut off; F is left and named"
lab_task lab-ta
t0=$(now); lab_teardown lab-ta FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6 > "$LAB/ta.out" 2> "$LAB/ta.err"; rc=$?
show ta; echo "  timing: Ta teardown $(since "$t0")s"
check "Ta exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "H marked cut-off, hold intact" jq -e '.expiry == "cut-off" and .expired == false' "$H/record/data-cleanup.json"
check "H scratch still held" [ -f "$H/.cleanup-hold/scratch.bin" ]
check "cut-off warning promises one full 6s attempt" grep -qF "task data lab-slow expiry stopped after 4s; deletions it made stay done and the rest stays held; the next teardown that reaches it gives it one full 6s attempt" "$LAB/ta.err"
check "F named as left for a later teardown" grep -qF "holds left for a later teardown: lab-fast" "$LAB/ta.err"
echo "== Tb: F (now least recently tried) expires; H gets exactly one full 6s attempt and is marked too large"
lab_task lab-tb
G="$LAB/data/lab-tb"; mkdir -p "$G"; printf 'g scratch\n' > "$G/scratch.bin"
t0=$(now); lab_teardown lab-tb FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6 > "$LAB/tb.out" 2> "$LAB/tb.err"; rc=$?
show tb; echo "  timing: Tb teardown $(since "$t0")s"
check "Tb exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "F expired first" [ ! -e "$F/.cleanup-hold" ] && jq -e '.expired == true' "$F/record/data-cleanup.json" >/dev/null
check "H marked too-large, scratch still held" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "too-large warning names the full 6s attempt and the by-hand command for this home" grep -qF "task data lab-slow expiry stopped after its one full 6s attempt; deletions it made stay done and the rest stays held; it is too large to expire automatically, so later teardowns skip it and name it; expire it by hand with bash $WT/bin/fm-task-data-lib.sh expire $LAB/data $LAB/state lab-slow" "$LAB/tb.err"
echo "== Tc: 3000 expired records dated 2020 plus G's live hold; H skipped and named without using budget"
python3 - "$LAB/data" <<'PY'
import json, os, sys
data = sys.argv[1]
for n in range(3000):
    d = os.path.join(data, f"old-{n:04}", "record"); os.makedirs(d)
    p = os.path.join(d, "data-cleanup.json")
    json.dump({"version": 1, "task": f"old-{n:04}", "sources": [], "complete": True, "expired": True}, open(p, "w"))
    os.utime(p, (1577836800, 1577836800))
PY
lab_task lab-tc
t0=$(now); lab_teardown lab-tc FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=4 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=6 > "$LAB/tc.out" 2> "$LAB/tc.err"; rc=$?
show tc; echo "  timing: Tc teardown $(since "$t0")s"
check "Tc exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "G's live hold expired despite 3000 older expired records" [ ! -e "$G/.cleanup-hold" ] && [ -f "$G/record/data-cleanup.json" ]
check "H skipped and named as too large" grep -qF "task data holds too large to expire automatically, skipped and kept for expiry by hand: lab-slow" "$LAB/tc.err"
check "H untouched: still too-large, scratch held" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "no budget-ran-out warning" sh -c "! grep -q 'expiry budget ran out' '$LAB/tc.err'"
echo "== by hand: refused while another process holds H's task lock"
rm -f "$LAB/holder-ready"
"$(dirname "$0")/hold-lock.sh" "$WT" "$LAB/state/.meta-lab-slow.lock" "$LAB/holder-ready" & holder=$!
for _ in $(seq 100); do [ -e "$LAB/holder-ready" ] && break; sleep 0.1; done
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-slow ) > "$LAB/bh1.out" 2> "$LAB/bh1.err"; rc=$?
kill -TERM "$holder"; wait "$holder" 2>/dev/null
show bh1
check "refused, exit 1 (rc=$rc)" [ "$rc" = 1 ]
check "says locked by another process" grep -qF "task lab-slow is locked by another process; nothing was expired, retry later" "$LAB/bh1.err"
check "nothing expired" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
echo "== by hand: refused for a live task"
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-live ) > "$LAB/bh2.out" 2> "$LAB/bh2.err"; rc=$?
show bh2
check "refused, exit 1 (rc=$rc)" [ "$rc" = 1 ]
check "says the task is live" grep -qF "task lab-live is live; nothing was expired" "$LAB/bh2.err"
check "live task's lock released" [ ! -e "$LAB/state/.meta-lab-live.lock" ]
echo "== by hand: expires H with no time limit under its lock"
t0=$(now)
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-slow ) > "$LAB/bh3.out" 2> "$LAB/bh3.err" & bpid=$!
locked=0
for _ in $(seq 400); do [ -e "$LAB/state/.meta-lab-slow.lock" ] && { locked=1; break; }; kill -0 "$bpid" 2>/dev/null || break; sleep 0.05; done
wait "$bpid"; rc=$?; bhs=$(since "$t0")
show bh3; echo "  timing: by-hand expiry ${bhs}s"
check "by-hand exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "held H's task lock while running" [ "$locked" = 1 ]
check "lock released after" [ ! -e "$LAB/state/.meta-lab-slow.lock" ]
check "ran past the 6s full attempt (${bhs}s)" python3 -c "import sys; sys.exit(0 if $bhs > 6 else 1)"
check "H expired and its mark cleared" [ ! -e "$H/.cleanup-hold" ] && jq -e '.expired == true and (has("expiry") | not)' "$H/record/data-cleanup.json" >/dev/null
check "H's kept brief survives" [ -f "$H/brief.md" ]
echo "== external calls the stubs absorbed:"; sort "$LAB/external-calls.log" 2>/dev/null | uniq -c | sed 's/^/  /' | head
lab_end
echo "FAILS=$FAILS"
