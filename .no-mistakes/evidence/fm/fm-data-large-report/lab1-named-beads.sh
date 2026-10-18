#!/usr/bin/env bash
# Lab 1: named beads resolve in the database that owns them (.agent-config-*
# from ~/.agent-config, gsp-* from ~/dev/gsp-beads, others from the task's
# project), and an unreadable bead keeps the folder whole while the backlog
# close goes through, then a later pass retries it.
# HOME points at the lab's own home so the real br reads lab databases only.
. "$(dirname "$0")/lab-lib.sh"
new_lab
trap end_lab EXIT
H="$LAB/home"
mkdir -p "$H/.agent-config" "$H/dev/gsp-beads"
(cd "$H/.agent-config" && HOME="$H" br init --prefix .agent-config -q)
(cd "$H/dev/gsp-beads" && HOME="$H" br init --prefix gsp -q)
(cd "$PROJ" && HOME="$H" br init --prefix lab -q)
AC=$(cd "$H/.agent-config" && HOME="$H" br create "agent-config bead" --description "evidence [capture](agent-proof.png)" --silent)
GSP=$(cd "$H/dev/gsp-beads" && HOME="$H" br create "gsp bead" --description "evidence [capture](gsp-proof.png)" --silent)
PB=$(cd "$PROJ" && HOME="$H" br create "project bead" --description "evidence [capture](proj-proof.png)" --silent)
PB2=$(cd "$PROJ" && HOME="$H" br create "project bead two" --description "evidence [capture](retry-proof.png)" --silent)
echo "beads: $AC $GSP $PB $PB2"
start=$(date +%s.%N 2>/dev/null || date +%s); (cd "$H/.agent-config" && HOME="$H" br show "$AC" --json >/dev/null); echo "one real br show took about $(python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$start")s"

say "S1: a task naming a dotted .agent-config bead, a gsp bead and a project bead"
add_task task-beads
T="$LAB/data/task-beads"
printf 'Bead %s\nBead %s\nBead %s\n' "$AC" "$GSP" "$PB" > "$T/brief.md"
for f in agent-proof.png gsp-proof.png proj-proof.png; do printf 'linked evidence\n' > "$T/$f"; done
printf 'scratch\n' > "$T/discard.bin"
lab_teardown task-beads HOME="$H" FM_TEARDOWN_DATA_STAGE_TIMEOUT=600; rc=$?
show "$LAB/task-beads.out"; show "$LAB/task-beads.err"
check "teardown exits 0" [ "$rc" = 0 ]
check "backlog row closed (done)" [ "$(row_state task-beads)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/task-beads.backlog-close" ]
check "task record retired" [ ! -e "$LAB/state/task-beads.meta" ]
check "no 'Invalid id' or 'not found' in teardown output" bash -c '! grep -Eq "Invalid id|not found|unread" "$1"' _ "$LAB/task-beads.err"
for f in agent-proof.png gsp-proof.png proj-proof.png; do check "$f linked from its bead stays in place" [ -f "$T/$f" ]; done
check "unlinked scratch staged into .cleanup-hold" [ -f "$T/.cleanup-hold/discard.bin" ]
record task-beads | jq -c '{complete, expired, beads: .sources[-1].beads, unread: .sources[-1].unread}'
check "record names all three beads and none unread" \
  jq -e --arg a "$AC" --arg g "$GSP" --arg p "$PB" '.complete == true and (.sources[-1].beads | index($a) and index($g) and index($p)) and (.sources[-1].unread // [] | length == 0)' "$T/record/data-cleanup.json"

say "S2: a task naming beads that cannot be read (dotted missing, unknown prefix, project database unavailable)"
add_task task-unread
T2="$LAB/data/task-unread"
printf 'Bead .agent-config-zzzzz\nBead nope-qq1x\n' > "$T2/brief.md"
printf 'linked evidence\n' > "$T2/proof.png"; printf 'scratch\n' > "$T2/discard.bin"
add_task task-retry
T3="$LAB/data/task-retry"
printf 'Bead %s\n' "$PB2" > "$T3/brief.md"
printf 'linked evidence\n' > "$T3/retry-proof.png"; printf 'scratch\n' > "$T3/discard.bin"
lab_teardown task-unread HOME="$H" FM_TEARDOWN_DATA_STAGE_TIMEOUT=600; rc=$?
show "$LAB/task-unread.out"; show "$LAB/task-unread.err"
check "teardown exits 0 with unreadable beads" [ "$rc" = 0 ]
check "backlog row closed (done) despite unread beads" [ "$(row_state task-unread)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/task-unread.backlog-close" ]
check "scratch not moved (folder whole)" [ "$(cat "$T2/discard.bin")" = scratch ]
check "nothing staged" [ ! -e "$T2/.cleanup-hold" ]
check "teardown output names .agent-config-zzzzz" grep -q -- '.agent-config-zzzzz' "$LAB/task-unread.err"
check "teardown output names nope-qq1x" grep -q -- 'nope-qq1x' "$LAB/task-unread.err"
record task-unread | jq -c '{complete, expired, unread: .sources[-1].unread}'
check "record complete=false and lists both unread ids" \
  jq -e '.complete == false and (.sources[-1].unread | index(".agent-config-zzzzz") and index("nope-qq1x"))' "$T2/record/data-cleanup.json"
mv "$PROJ/.beads" "$PROJ/.beads.away"
lab_teardown task-retry HOME="$H" FM_TEARDOWN_DATA_STAGE_TIMEOUT=600 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=120; rc=$?
show "$LAB/task-retry.err"
check "teardown exits 0 while the project bead database is unavailable" [ "$rc" = 0 ]
check "backlog row closed (done)" [ "$(row_state task-retry)" = done ]
check "folder kept whole: scratch in place" [ "$(cat "$T3/discard.bin")" = scratch ]
check "folder kept whole: nothing staged" [ ! -e "$T3/.cleanup-hold" ]
check "record names $PB2 unread" jq -e --arg p "$PB2" '.complete == false and (.sources[-1].unread | index($p))' "$T3/record/data-cleanup.json"
mv "$PROJ/.beads.away" "$PROJ/.beads"

say "S2 retry: the next teardown of a different task retries every unread hold"
add_task task-next
lab_teardown task-next HOME="$H" FM_TEARDOWN_DATA_STAGE_TIMEOUT=600 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=120; rc=$?
show "$LAB/task-next.out"; show "$LAB/task-next.err"
check "next teardown exits 0" [ "$rc" = 0 ]
check "retried hold now readable: scratch staged" [ -f "$T3/.cleanup-hold/discard.bin" ]
check "retried hold keeps its bead-linked evidence" [ -f "$T3/retry-proof.png" ]
check "retried hold's record clears its unread list" jq -e '.sources[-1].unread == []' "$T3/record/data-cleanup.json"
check "still-unreadable hold still whole: scratch in place" [ "$(cat "$T2/discard.bin")" = scratch ]
check "still-unreadable hold still whole: nothing staged" [ ! -e "$T2/.cleanup-hold" ]
check "S1 hold expired by the next different task (real dcg-guarded rm)" [ ! -e "$T/.cleanup-hold" ]
for f in agent-proof.png gsp-proof.png proj-proof.png; do check "S1 $f survives expiry" [ -f "$T/$f" ]; done
check "S1 record expired" jq -e '.expired == true' "$T/record/data-cleanup.json"
echo "lab1 failures: $FAILS"
