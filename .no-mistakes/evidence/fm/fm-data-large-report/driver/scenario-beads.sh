#!/usr/bin/env bash
# Live: named beads resolve in the database that owns them; an unreadable one
# keeps data/<id> whole, lets the backlog close, is named, and is retried.
# Real bin/fm-teardown.sh, real br (lab-local databases), real tasks-axi, real dcg.
. "$(dirname "$0")/lab-env.sh"
LAB=$(lab_new) || exit 1
lab_export "$LAB"
echo "lab home: $LAB"
lab_project "$LAB"
FAILS=0
check() { # <description> <command...>
  local what=$1; shift
  if "$@"; then echo "PASS: $what"; else echo "FAIL: $what"; FAILS=$((FAILS + 1)); fi
}
record() { cat "$LAB/data/$1/record/data-cleanup.json"; }

AC=$(lab_bead "$LAB/home/.agent-config" "ac evidence" "[capture](ac-proof.png)")
GSP=$(lab_bead "$LAB/home/dev/gsp-beads" "gsp evidence" "[capture](gsp-proof.png)")
PRJ=$(lab_bead "$LAB/projects/demo" "project evidence" "[capture](prj-proof.png)")
FB=fmb-fallback1
tasks-axi add "$FB" "firstmate backlog evidence" --body '[capture](fb-proof.png)' --file "$LAB/data/backlog.md" >/dev/null
echo "beads: agent-config=$AC gsp=$GSP project=$PRJ firstmate-backlog=$FB"

resolved_case() { # <task> <bead> <linked-file>
  local id=$1 bead=$2 linked=$3 rc
  lab_task "$LAB" "$id"
  printf 'Bead %s\n' "$bead" > "$LAB/data/$id/brief.md"
  printf 'linked evidence\n' > "$LAB/data/$id/$linked"
  printf 'scratch\n' > "$LAB/data/$id/scratch.bin"
  echo
  echo "== teardown $id (names $bead; inherited BEADS_DIR/BEADS_DB/BR_DB point at /wrong) =="
  lab_teardown "$LAB" "$id" BEADS_DIR=/wrong BEADS_DB=/wrong BR_DB=/wrong > "$LAB/$id.out" 2> "$LAB/$id.err"
  rc=$?
  echo "exit=$rc"; echo "-- stdout"; cat "$LAB/$id.out"; echo "-- stderr"; cat "$LAB/$id.err"
  echo "-- record"; record "$id"
  echo "-- data/$id"; (cd "$LAB/data/$id" && find . -path ./record -prune -o -type f -print | sort)
  check "$id teardown exits 0" [ "$rc" = 0 ]
  check "$id backlog row is done" [ "$(row_state "$LAB" "$id")" = done ]
  check "$id leaves no pending close" [ ! -e "$LAB/state/$id.backlog-close" ]
  check "$id bead-linked $linked stays in place (bead text was read)" [ "$(cat "$LAB/data/$id/$linked" 2>/dev/null)" = 'linked evidence' ]
  check "$id scratch is staged to .cleanup-hold" [ -e "$LAB/data/$id/.cleanup-hold/scratch.bin" ]
  check "$id record lists $bead with no unread ids" jq -e --arg b "$bead" '.sources[-1].unread == [] and (.sources[-1].beads | index($b) != null) and .complete == true' "$LAB/data/$id/record/data-cleanup.json"
}

resolved_case t-ac "$AC" ac-proof.png
resolved_case t-gsp "$GSP" gsp-proof.png
resolved_case t-prj "$PRJ" prj-proof.png
resolved_case t-fb "$FB" fb-proof.png
check "earlier holds were expired by later teardowns through real dcg" [ ! -e "$LAB/data/t-ac/.cleanup-hold" ]
check "expired t-ac still keeps its bead-linked evidence" [ -e "$LAB/data/t-ac/ac-proof.png" ]

# An id that no database can answer, and a dotted .agent-config id that does not exist.
for pair in "t-unread zzz-missing1" "t-dotmiss .agent-config-zzzz"; do
  set -- $pair
  id=$1 bead=$2
  lab_task "$LAB" "$id"
  printf 'Bead %s\n' "$bead" > "$LAB/data/$id/brief.md"
  printf 'linked evidence\n' > "$LAB/data/$id/proof.png"
  printf 'scratch\n' > "$LAB/data/$id/scratch.bin"
  echo
  echo "== teardown $id (names unreadable $bead) =="
  lab_teardown "$LAB" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err"
  rc=$?
  echo "exit=$rc"; echo "-- stdout"; cat "$LAB/$id.out"; echo "-- stderr"; cat "$LAB/$id.err"
  echo "-- record"; record "$id"
  echo "-- data/$id"; (cd "$LAB/data/$id" && find . -path ./record -prune -o -type f -print | sort)
  check "$id teardown exits 0" [ "$rc" = 0 ]
  check "$id backlog row is done (close went through)" [ "$(row_state "$LAB" "$id")" = done ]
  check "$id leaves no pending close" [ ! -e "$LAB/state/$id.backlog-close" ]
  check "$id scratch stays in place (data kept whole)" [ "$(cat "$LAB/data/$id/scratch.bin" 2>/dev/null)" = scratch ]
  check "$id staged nothing" [ ! -e "$LAB/data/$id/.cleanup-hold" ]
  check "$id teardown output names $bead" grep -qF -- "$bead" "$LAB/$id.err"
  check "$id record names $bead as unread and is incomplete" jq -e --arg b "$bead" '.complete == false and (.sources[-1].unread | index($b) != null)' "$LAB/data/$id/record/data-cleanup.json"
done

echo
echo "== retry 1: teardown t-next1 while zzz-missing1 is still unreadable =="
lab_task "$LAB" t-next1
lab_teardown "$LAB" t-next1 > "$LAB/t-next1.out" 2> "$LAB/t-next1.err"
rc=$?
echo "exit=$rc"; echo "-- stderr"; cat "$LAB/t-next1.err"; echo "-- t-unread record"; record t-unread
check "t-next1 teardown exits 0" [ "$rc" = 0 ]
check "the retry names zzz-missing1 again" grep -qF zzz-missing1 "$LAB/t-next1.err"
check "the retry still keeps t-unread whole" [ "$(cat "$LAB/data/t-unread/scratch.bin" 2>/dev/null)" = scratch ]
check "the retry staged nothing for t-unread" [ ! -e "$LAB/data/t-unread/.cleanup-hold" ]

echo
echo "== retry 2: zzz-missing1 now readable from the Firstmate backlog; teardown t-next2 =="
tasks-axi add zzz-missing1 "now readable" --body '[capture](proof.png)' --file "$LAB/data/backlog.md" >/dev/null
lab_task "$LAB" t-next2
lab_teardown "$LAB" t-next2 > "$LAB/t-next2.out" 2> "$LAB/t-next2.err"
rc=$?
echo "exit=$rc"; echo "-- stdout"; cat "$LAB/t-next2.out"; echo "-- stderr"; cat "$LAB/t-next2.err"
echo "-- t-unread record"; record t-unread
echo "-- data/t-unread"; (cd "$LAB/data/t-unread" && find . -path ./record -prune -o -type f -print | sort)
check "t-next2 teardown exits 0" [ "$rc" = 0 ]
check "the next cleanup pass staged t-unread's scratch" [ -e "$LAB/data/t-unread/.cleanup-hold/scratch.bin" ]
check "the next cleanup pass kept t-unread's linked proof.png" [ "$(cat "$LAB/data/t-unread/proof.png" 2>/dev/null)" = 'linked evidence' ]
check "the t-unread record no longer lists an unread id" jq -e '.sources[-1].unread == [] and .complete == true' "$LAB/data/t-unread/record/data-cleanup.json"
check "t-dotmiss is still kept whole and named" grep -qF .agent-config-zzzz "$LAB/t-next2.err"

echo
echo "lab home to remove: $LAB"
echo "FAILS=$FAILS"
