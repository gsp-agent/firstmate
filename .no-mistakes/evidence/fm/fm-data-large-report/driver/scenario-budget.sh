#!/usr/bin/env bash
# Live: the expiry budget and the one full attempt, against real slow holds
# (each names 40 beads in the project's br db), plus already-expired records.
#   C2 cut-off -> one full attempt -> too-large -> skipped and named -> by hand
#   C3 the full attempt lasts exactly FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT
#   C4 thousands of expired records do not use up the budget
. "$(dirname "$0")/lab-env.sh"
DRIVER=$(cd "$(dirname "$0")" && pwd)
FAILS=0
check() {
  local what=$1; shift
  if "$@"; then echo "PASS: $what"; else echo "FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
now() { python3 -c 'import time; print("%.2f" % time.time())'; }
since() { python3 -c "print('%.1f' % ($(now) - $1))"; }
pending_hold() { # <task> <beads-json> [touch-stamp]
  mkdir -p "$LAB/data/$1/record" "$LAB/data/$1/.cleanup-hold"
  printf 'held scratch\n' > "$LAB/data/$1/.cleanup-hold/scratch.bin"
  jq -n --arg task "$1" --arg project "$LAB/projects/demo" --arg data "$LAB/data" --argjson beads "$2" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: $beads, backlog: {data: $data, task: null}}]}' \
    > "$LAB/data/$1/record/data-cleanup.json"
  [ -z "${3:-}" ] || touch -t "$3" "$LAB/data/$1/record/data-cleanup.json"
}
slow_beads() { # prints a JSON list of 40 new project beads
  local n out=()
  for ((n = 0; n < 40; n++)); do out+=("$(lab_bead "$LAB/projects/demo" "slow $n" "slow bead $n")"); done
  printf '%s\n' "${out[@]}" | jq -R . | jq -sc .
}
# Run a teardown and time how long an expire process for <hold> lives.
timed_teardown() { # <task> <hold> [env...]
  local id=$1 hold=$2 start='' seen=0 i
  shift 2
  lab_task "$LAB" "$id"
  env "$@" "$ROOT/bin/fm-teardown.sh" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err" &
  local td=$!
  while kill -0 "$td" 2>/dev/null; do
    if pgrep -f "fm-task-data.py expire $LAB/data $LAB/state $hold" >/dev/null 2>&1; then
      [ -n "$start" ] || start=$(now)
      seen=1
    elif [ -n "$start" ]; then
      ATTEMPT_SECS=$(since "$start"); start=''
    fi
    sleep 0.1
  done
  wait "$td"; RC=$?
  [ -z "$start" ] || ATTEMPT_SECS=$(since "$start")
  SEEN=$seen
  echo "teardown $id exit=$RC; expire process for $hold seen=$seen lifetime=${ATTEMPT_SECS:-n/a}s"
  echo "-- stderr"; cat "$LAB/$id.err"
  echo "-- $hold record"; cat "$LAB/data/$hold/record/data-cleanup.json"; echo
}

echo "######## C2: cut-off, one full attempt, too large, skipped, by hand ########"
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "lab home: $LAB"
lab_project "$LAB"
pending_hold aa-huge "$(slow_beads)"
REC="$LAB/data/aa-huge/record/data-cleanup.json"
echo; echo "== teardown t1 (budget 2s, full attempt 4s) =="
ATTEMPT_SECS=''; timed_teardown t1 aa-huge FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4
check "t1 exits 0" [ "$RC" = 0 ]
check "t1 attempted aa-huge" [ "$SEEN" = 1 ]
check "t1 names the cut-off and promises one full 4s attempt" grep -qF "task data aa-huge expiry stopped after" "$LAB/t1.err"
check "t1 warning promises one full 4s attempt" grep -qF "the next teardown that reaches it gives it one full 4s attempt" "$LAB/t1.err"
check "t1 warning says deletions stay done and the rest stays held" grep -qF "deletions it made stay done and the rest stays held" "$LAB/t1.err"
check "aa-huge record is marked cut-off" [ "$(jq -r '.expiry // ""' "$REC")" = cut-off ]
check "aa-huge still holds its scratch" [ -e "$LAB/data/aa-huge/.cleanup-hold/scratch.bin" ]

echo; echo "== teardown t2 (budget 2s, full attempt 4s) =="
ATTEMPT_SECS=''; timed_teardown t2 aa-huge FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4
check "t2 exits 0" [ "$RC" = 0 ]
check "t2 attempted aa-huge" [ "$SEEN" = 1 ]
check "the full attempt ran about 4s (3-7s observed)" python3 -c "import sys; sys.exit(0 if 3 <= float('${ATTEMPT_SECS:-0}') <= 7 else 1)"
check "t2 names the one full 4s attempt" grep -qF "task data aa-huge expiry stopped after its one full 4s attempt" "$LAB/t2.err"
check "t2 says later teardowns skip it" grep -qF "too large to expire automatically, so later teardowns skip it and name it" "$LAB/t2.err"
check "aa-huge record is marked too-large" [ "$(jq -r '.expiry // ""' "$REC")" = too-large ]
check "aa-huge still holds its scratch" [ -e "$LAB/data/aa-huge/.cleanup-hold/scratch.bin" ]

echo; echo "== teardown t3 (budget 2s, full attempt 4s) =="
ATTEMPT_SECS=''; timed_teardown t3 aa-huge FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4
check "t3 exits 0" [ "$RC" = 0 ]
check "t3 did not attempt the too-large hold" [ "$SEEN" = 0 ]
check "t3 names the skipped hold" grep -qF "holds too large to expire automatically, skipped and kept for expiry by hand: aa-huge" "$LAB/t3.err"
check "aa-huge stays marked too-large" [ "$(jq -r '.expiry // ""' "$REC")" = too-large ]
check "aa-huge still holds its scratch" [ -e "$LAB/data/aa-huge/.cleanup-hold/scratch.bin" ]

ADVERTISED=$(sed -n 's/.*expire it by hand with //p' "$LAB/t2.err")
echo; echo "advertised by-hand command: $ADVERTISED"
read -r -a BY_HAND <<< "$ADVERTISED"
shape="${BY_HAND[0]:-} ${BY_HAND[1]##*/} ${BY_HAND[2]:-} ${BY_HAND[3]:-} ${BY_HAND[4]:-} ${BY_HAND[5]:-}"
check "the advertised command is bash fm-task-data-lib.sh expire DATA STATE aa-huge" [ "$shape" = "bash fm-task-data-lib.sh expire $LAB/data $LAB/state aa-huge" ]

echo; echo "== by hand while another live process holds aa-huge's task lock =="
FLAG="$LAB/holder"
bash "$DRIVER/hold-lock.sh" "$LAB/state" aa-huge "$FLAG" &
HOLDER=$!
for ((i = 0; i < 100; i++)); do [ -e "$FLAG.ready" ] && break; sleep 0.1; done
"${BY_HAND[@]}" > "$LAB/byhand1.out" 2> "$LAB/byhand1.err"; BH=$?
echo "exit=$BH"; cat "$LAB/byhand1.err"
check "the lock holder was running" [ -e "$FLAG.ready" ]
check "by hand refuses while the lock is held" [ "$BH" != 0 ]
check "by hand says the task is locked by another process" grep -qF "locked by another process; nothing was expired" "$LAB/byhand1.err"
check "the refused run left the hold in place" [ -e "$LAB/data/aa-huge/.cleanup-hold/scratch.bin" ]
: > "$FLAG.release"; wait "$HOLDER"

echo; echo "== by hand against a live task =="
pending_hold live-z '[]'
printf '%s\n' kind=ship spawn_gen=live-z > "$LAB/state/live-z.meta"
bash "$ROOT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" live-z > "$LAB/byhand-live.out" 2> "$LAB/byhand-live.err"; BH=$?
echo "exit=$BH"; cat "$LAB/byhand-live.err"
check "by hand refuses a live task" [ "$BH" != 0 ]
check "by hand says the task is live" grep -qF "task live-z is live; nothing was expired" "$LAB/byhand-live.err"
check "the live task's hold is untouched" [ -e "$LAB/data/live-z/.cleanup-hold/scratch.bin" ]
check "the refusal released the live task's lock" [ ! -e "$LAB/state/.meta-live-z.lock" ]

echo; echo "== by hand, lock free (no time limit) =="
t0=$(now)
"${BY_HAND[@]}" > "$LAB/byhand2.out" 2> "$LAB/byhand2.err" &
BHP=$!
lock_seen=0
while kill -0 "$BHP" 2>/dev/null; do [ -e "$LAB/state/.meta-aa-huge.lock" ] && lock_seen=1; sleep 0.1; done
wait "$BHP"; BH=$?
echo "exit=$BH after $(since "$t0")s; task lock seen held during the run: $lock_seen"
echo "-- stdout"; cat "$LAB/byhand2.out"; echo "-- stderr"; cat "$LAB/byhand2.err"
echo "-- aa-huge record"; cat "$REC"; echo
check "by hand exits 0" [ "$BH" = 0 ]
check "by hand held aa-huge's task lock while it ran" [ "$lock_seen" = 1 ]
check "by hand released the task lock" [ ! -e "$LAB/state/.meta-aa-huge.lock" ]
check "by hand expired the hold" [ ! -e "$LAB/data/aa-huge/.cleanup-hold" ]
check "by hand cleared the mark and recorded expiry" jq -e '.expired == true and (has("expiry") | not)' "$REC"
echo "lab home to remove: $LAB"
LAB_C2=$LAB

echo; echo "######## C3: the one full attempt lasts exactly its own limit ########"
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "lab home: $LAB"
lab_project "$LAB"
pending_hold aa-slow "$(slow_beads)"
REC="$LAB/data/aa-slow/record/data-cleanup.json"
jq '.expiry = "cut-off"' "$REC" > "$REC.next" && mv "$REC.next" "$REC"
echo; echo "== teardown c3 (budget 3s, full attempt 1s; aa-slow already marked cut-off) =="
ATTEMPT_SECS=''; timed_teardown c3 aa-slow FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=3 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=1
check "c3 exits 0" [ "$RC" = 0 ]
check "c3 attempted aa-slow" [ "$SEEN" = 1 ]
check "the full attempt stopped near 1s, not the 3s budget (<2.5s observed)" python3 -c "import sys; sys.exit(0 if float('${ATTEMPT_SECS:-99}') < 2.5 else 1)"
check "c3 names the one full 1s attempt" grep -qF "task data aa-slow expiry stopped after its one full 1s attempt" "$LAB/c3.err"
check "aa-slow record is marked too-large" [ "$(jq -r '.expiry // ""' "$REC")" = too-large ]
echo "lab home to remove: $LAB"
LAB_C3=$LAB

echo; echo "######## C4: expired records do not use up the budget ########"
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "lab home: $LAB"
lab_project "$LAB"
pending_hold zz-live '[]' 202101010000
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
t0=$(now); python3 "$ROOT/bin/fm-task-data.py" pending "$LAB/data" > "$LAB/pending.txt"; echo "pending listing over 3001 records: $(since "$t0")s -> $(tr '\t' ' ' < "$LAB/pending.txt")"
echo; echo "== teardown c4 (default budget) with 3000 expired records dated 2020 and one live hold dated 2021 =="
ATTEMPT_SECS=''; timed_teardown c4 zz-live
check "c4 exits 0" [ "$RC" = 0 ]
check "the listing names only the live hold" [ "$(cut -f1 "$LAB/pending.txt")" = zz-live ]
check "the live hold expired" [ ! -e "$LAB/data/zz-live/.cleanup-hold" ]
check "no budget warning" ! grep -qF "expiry budget ran out" "$LAB/c4.err"
echo "lab home to remove: $LAB"
LAB_C4=$LAB

echo
echo "labs to remove: $LAB_C2 $LAB_C3 $LAB_C4"
echo "FAILS=$FAILS"
