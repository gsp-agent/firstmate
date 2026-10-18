#!/usr/bin/env bash
# Live scenario 1: named beads resolve in the database that owns them; an
# unreadable reference keeps the folder whole, lets the close through, is named,
# and is retried by later teardowns until it reads.
set -u
. "$(dirname "$0")/lab-lib.sh"
FAILS=0
lab_new || exit 1
echo "$LAB" >> "$(dirname "$0")/labs.txt"

lab_br "$LHOME/.agent-config" init --prefix .agent-config -q
AC=$(lab_br "$LHOME/.agent-config" create "agent-config evidence" -d "see [capture](ac-proof.png)" --silent | tail -1)
AC2=$(lab_br "$LHOME/.agent-config" create "agent-config evidence two" -d "see [capture](c-proof.png)" --silent | tail -1)
lab_br "$LHOME/dev/gsp-beads" init --prefix gsp -q
GSP=$(lab_br "$LHOME/dev/gsp-beads" create "gsp evidence" -d "see [capture](gsp-proof.png)" --silent | tail -1)
lab_br "$PROJ" init --prefix proj -q
echo "real beads: $AC and $AC2 in $LHOME/.agent-config; $GSP in $LHOME/dev/gsp-beads; project db $PROJ/.beads has none of them"

seed() { # <task> <brief-line> <proof-name>
  local d="$LAB/data/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/brief.md"
  printf 'linked evidence\n' > "$d/$3"
  printf 'scratch\n' > "$d/discard.bin"
}

echo "== A: dotted .agent-config id ($AC), with BEADS_DIR/BEADS_DB/BR_DB pointing elsewhere"
lab_task lab-ac
seed lab-ac "Bead $AC" ac-proof.png
lab_teardown lab-ac BEADS_DIR=/wrong BEADS_DB=/wrong BR_DB=/wrong > "$LAB/a.out" 2> "$LAB/a.err"; rc=$?
sed 's/^/  out| /' "$LAB/a.out"; sed 's/^/  err| /' "$LAB/a.err"
A="$LAB/data/lab-ac"
check "teardown exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "backlog row closed (state=$(row_state lab-ac))" [ "$(row_state lab-ac)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/lab-ac.backlog-close" ]
check "task record retired" [ ! -e "$LAB/state/lab-ac.meta" ]
check "lab tmux window fm-lab-ac killed" sh -c "! TMUX_TMPDIR='$LAB/tmux' tmux -L fm-lab list-windows -t firstmate -F '#{window_name}' | grep -qx fm-lab-ac"
check "file linked only from the bead stays in place" [ "$(cat "$A/ac-proof.png")" = 'linked evidence' ]
check "scratch staged into the recovery hold" [ -f "$A/.cleanup-hold/discard.bin" ] && [ ! -e "$A/discard.bin" ]
check "record names the bead and nothing unread" jq -e --arg b "$AC" '(.sources[0].beads | index($b)) != null and .sources[0].unread == [] and .complete == true' "$A/record/data-cleanup.json"
echo "  record: $(jq -c '{complete, expired, sources: [.sources[] | {beads, unread}]}' "$A/record/data-cleanup.json")"

echo "== B: gsp-beads id ($GSP); this teardown also expires A's hold"
lab_task lab-gsp
seed lab-gsp "Bead $GSP" gsp-proof.png
lab_teardown lab-gsp > "$LAB/b.out" 2> "$LAB/b.err"; rc=$?
sed 's/^/  out| /' "$LAB/b.out"; sed 's/^/  err| /' "$LAB/b.err"
B="$LAB/data/lab-gsp"
check "teardown exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "backlog row closed (state=$(row_state lab-gsp))" [ "$(row_state lab-gsp)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/lab-gsp.backlog-close" ]
check "file linked only from the gsp bead stays in place" [ "$(cat "$B/gsp-proof.png")" = 'linked evidence' ]
check "scratch staged into the recovery hold" [ -f "$B/.cleanup-hold/discard.bin" ] && [ ! -e "$B/discard.bin" ]
check "record names the gsp bead and nothing unread" jq -e --arg b "$GSP" '(.sources[0].beads | index($b)) != null and .sources[0].unread == []' "$B/record/data-cleanup.json"
check "A's hold expired by B's teardown, bead-linked file kept" [ ! -e "$A/.cleanup-hold" ] && [ -f "$A/ac-proof.png" ]
check "A's record says expired" jq -e '.expired == true' "$A/record/data-cleanup.json"

echo "== C: unreadable references: $AC2 while its database is away, and lostid-zz9 that no database has"
lab_task lab-unread
seed lab-unread "Bead $AC2 and Bead lostid-zz9" c-proof.png
mv "$LHOME/.agent-config" "$LHOME/.agent-config.away"
lab_teardown lab-unread > "$LAB/c.out" 2> "$LAB/c.err"; rc=$?
mv "$LHOME/.agent-config.away" "$LHOME/.agent-config"
sed 's/^/  out| /' "$LAB/c.out"; sed 's/^/  err| /' "$LAB/c.err"
C="$LAB/data/lab-unread"
check "teardown exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "backlog row closed (state=$(row_state lab-unread))" [ "$(row_state lab-unread)" = done ]
check "no pending backlog close left" [ ! -e "$LAB/state/lab-unread.backlog-close" ]
check "task record retired" [ ! -e "$LAB/state/lab-unread.meta" ]
check "folder kept whole: scratch not moved" [ "$(cat "$C/discard.bin")" = scratch ]
check "folder kept whole: nothing staged" [ ! -e "$C/.cleanup-hold" ]
check "teardown output names $AC2" grep -qF -- "$AC2" "$LAB/c.err"
check "teardown output names lostid-zz9" grep -qF -- lostid-zz9 "$LAB/c.err"
check "record lists both unread and stays incomplete" jq -e --arg b "$AC2" '.complete == false and (.sources[0].unread | index($b)) != null and (.sources[0].unread | index("lostid-zz9")) != null' "$C/record/data-cleanup.json"
echo "  record: $(jq -c '{complete, sources: [.sources[] | {beads, unread}]}' "$C/record/data-cleanup.json")"

echo "== D: next teardown retries C with the .agent-config database back; lostid-zz9 still unread"
lab_task lab-next1
lab_teardown lab-next1 > "$LAB/d.out" 2> "$LAB/d.err"; rc=$?
sed 's/^/  out| /' "$LAB/d.out"; sed 's/^/  err| /' "$LAB/d.err"
check "teardown exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "retry read $AC2; only lostid-zz9 stays unread" jq -e '.complete == false and .sources[0].unread == ["lostid-zz9"]' "$C/record/data-cleanup.json"
check "C still whole while one reference is unread" [ -f "$C/discard.bin" ] && [ ! -e "$C/.cleanup-hold" ]
check "retry warning names lostid-zz9 again" grep -qF -- lostid-zz9 "$LAB/d.err"

echo "== E: lostid-zz9 now exists as a row in Firstmate's backlog; the next teardown stages C"
tasks-axi add lostid-zz9 "now readable" --body 'nothing linked' --file "$LAB/data/backlog.md" >/dev/null
lab_task lab-next2
lab_teardown lab-next2 > "$LAB/e.out" 2> "$LAB/e.err"; rc=$?
sed 's/^/  out| /' "$LAB/e.out"; sed 's/^/  err| /' "$LAB/e.err"
check "teardown exit 0 (rc=$rc)" [ "$rc" = 0 ]
check "C has no unread references left" jq -e '.sources[0].unread == []' "$C/record/data-cleanup.json"
check "C's scratch staged on the retry" [ -f "$C/.cleanup-hold/discard.bin" ] && [ ! -e "$C/discard.bin" ]
check "C's bead-linked file kept" [ "$(cat "$C/c-proof.png")" = 'linked evidence' ]
echo "== external calls the stubs absorbed:"; sed 's/^/  /' "$LAB/external-calls.log" 2>/dev/null | sort | uniq -c | head
lab_end
echo "FAILS=$FAILS"
