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

echo "######## Part B': one slow hold: cut off, one full attempt, too large, skipped and named, expired by hand"
lab_new || exit 1; echo "$LAB" >> "$(dirname "$0")/labs.txt"
mkdir -p "$LHOME/.config/dcg"; printf '[general]\nhook_timeout_ms = 5000\n' > "$LHOME/.config/dcg/config.toml"
echo "lab dcg config mirrors the operator's hook_timeout_ms = 5000"
NBEADS=200 make_beads
hold lab-slow 202001010000 1
H="$LAB/data/lab-slow"
lab_task lab-live
run_t() { # <id> <budget> <full>
  local t0; lab_task "$1"
  [ "$1" != lab-tb ] || { mkdir -p "$LAB/data/lab-tb"; printf 'g scratch\n' > "$LAB/data/lab-tb/scratch.bin"; }
  t0=$(now); lab_teardown "$1" FM_TEARDOWN_DATA_EXPIRE_TIMEOUT="$2" FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT="$3" > "$LAB/$1.out" 2> "$LAB/$1.err"; RC=$?
  show "$1"; echo "  timing: $1 teardown $(since "$t0")s (budget $2s, full $3s)"
}
echo "== Ta: budget 3s cuts H off"
run_t lab-ta 3 5
check "Ta exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "H marked cut-off, scratch held" jq -e '.expiry == "cut-off" and .expired == false' "$H/record/data-cleanup.json" >/dev/null
check "warning promises one full 5s attempt" grep -qF "task data lab-slow expiry stopped after 3s; deletions it made stay done and the rest stays held; the next teardown that reaches it gives it one full 5s attempt" "$LAB/lab-ta.err"
echo "== Tb: H gets exactly one full 5s attempt (past the 3s budget) and is marked too large"
run_t lab-tb 3 5
check "Tb exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "H marked too-large, scratch held" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "warning names the one full 5s attempt and the exact by-hand command" grep -qF "task data lab-slow expiry stopped after its one full 5s attempt; deletions it made stay done and the rest stays held; it is too large to expire automatically, so later teardowns skip it and name it; expire it by hand with bash $WT/bin/fm-task-data-lib.sh expire $LAB/data $LAB/state lab-slow" "$LAB/lab-tb.err"
echo "== Tc: 3000 expired records dated 2020 plus Tb's live hold; H is skipped and named without using the budget"
python3 - "$LAB/data" <<'PY'
import json, os, sys
data = sys.argv[1]
for n in range(3000):
    d = os.path.join(data, f"old-{n:04}", "record"); os.makedirs(d)
    p = os.path.join(d, "data-cleanup.json")
    json.dump({"version": 1, "task": f"old-{n:04}", "sources": [], "complete": True, "expired": True}, open(p, "w"))
    os.utime(p, (1577836800, 1577836800))
PY
run_t lab-tc 20 5
check "Tc exit 0 (rc=$RC)" [ "$RC" = 0 ]
check "H skipped and named as too large" grep -qF "task data holds too large to expire automatically, skipped and kept for expiry by hand: lab-slow" "$LAB/lab-tc.err"
check "H untouched: still too-large, scratch held" [ -f "$H/.cleanup-hold/scratch.bin" ] && jq -e '.expiry == "too-large"' "$H/record/data-cleanup.json" >/dev/null
check "Tb's live hold expired despite 3000 older expired records" [ ! -e "$LAB/data/lab-tb/.cleanup-hold" ] && jq -e '.expired == true' "$LAB/data/lab-tb/record/data-cleanup.json" >/dev/null
check "no expiry attempt on H in Tc (no stopped warning)" sh -c "! grep -q 'lab-slow expiry stopped' '$LAB/lab-tc.err'"
echo "== Td: H is skipped and named again"
run_t lab-td 3 5
check "Td names H again" grep -qF "skipped and kept for expiry by hand: lab-slow" "$LAB/lab-td.err"
echo "== by hand: the advertised command expires H with no time limit under its lock"
t0=$(now)
( cd "$WT" && lab_env bash "$WT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" lab-slow ) > "$LAB/bh.out" 2> "$LAB/bh.err" & bpid=$!
locked=0
for _ in $(seq 400); do [ -e "$LAB/state/.meta-lab-slow.lock" ] && { locked=1; break; }; kill -0 "$bpid" 2>/dev/null || break; sleep 0.05; done
wait "$bpid"; rc=$?; bhs=$(since "$t0")
show bh; echo "  timing: by-hand expiry ${bhs}s"
check "by-hand exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "held H's task lock while running" [ "$locked" = 1 ]
check "lock released after" [ ! -e "$LAB/state/.meta-lab-slow.lock" ]
check "ran past the 5s full attempt (${bhs}s)" python3 -c "import sys; sys.exit(0 if $bhs > 5 else 1)"
check "H expired and its mark cleared" [ ! -e "$H/.cleanup-hold" ] && jq -e '.expired == true and (has("expiry") | not)' "$H/record/data-cleanup.json" >/dev/null
check "H's kept brief survives" [ -f "$H/brief.md" ]
echo "== external calls the stubs absorbed:"; sort "$LAB/external-calls.log" 2>/dev/null | uniq -c | sed 's/^/  /' | head
lab_end
echo "FAILS=$FAILS"
