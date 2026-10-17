#!/usr/bin/env bash
# Scenario A: named beads resolve in the database that owns them, an unreadable
# one keeps the task's data whole while the backlog close completes, and the
# next teardown of a different task retries it.
# Usage: scenario-a-bead-resolution.sh <fresh-empty-lab-dir> <fresh-empty-home-dir>
. "$(dirname "$0")/lab-common.sh"
trap lab_down EXIT
lab_up
# Lab A tests resolution, not the expiry budget: give expiry room on a loaded host.
BUDGET=FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=60

AC=$(cd "$H/.agent-config" && hbr create 'lab agent-config bead' -d 'evidence [capture](ac-proof.png)' --json | jq -r .id)
GSP=$(cd "$H/dev/gsp-beads" && hbr create 'lab gsp bead' -d 'evidence [capture](gsp-proof.png)' --json | jq -r .id)
PROJ=$(cd "$P" && hbr create 'lab project bead' -d 'evidence [capture](proj-proof.png)' --json | jq -r .id)
say "beads created: agent-config=$AC gsp=$GSP project=$PROJ (real br databases under the disposable HOME and project)"

# Each task folder: a brief naming one bead, a file linked ONLY from that
# bead's description (kept only if the bead was actually read), and scratch.
seed() { # <task> <bead> <linked-file>
  add_task "$1"
  printf 'Bead %s\n' "$2" > "$LAB/data/$1/brief.md"
  printf 'linked evidence\n' > "$LAB/data/$1/$3"
  printf 'scratch\n' > "$LAB/data/$1/scratch.bin"
}

window_gone() { ! window_present "$1"; }
no_refusal() { ! grep -Eq 'slug-shaped|not found|needs a retry|retained whole' "$1"; }

resolved_case() { # <label> <task> <bead> <linked-file>
  local label=$1 id=$2 bead=$3 linked=$4 rc
  say ""
  say "=== A-$label: task $id names bead $bead ==="
  seed "$id" "$bead" "$linked"
  teardown "$id" "$BUDGET"; rc=$?
  check "A-$label teardown exits 0" [ "$rc" = 0 ]
  check "A-$label backlog row is done (state=$(row_state "$id"))" [ "$(row_state "$id")" = done ]
  check "A-$label no pending close left" [ ! -e "$LAB/state/$id.backlog-close" ]
  check "A-$label task record retired" [ ! -e "$LAB/state/$id.meta" ]
  check "A-$label task window closed on the lab tmux server" window_gone "$id"
  check "A-$label file linked only from the bead stays in place" [ "$(cat "$LAB/data/$id/$linked" 2>/dev/null)" = 'linked evidence' ]
  check "A-$label scratch staged for one-cycle recovery" [ -f "$LAB/data/$id/.cleanup-hold/scratch.bin" ]
  check "A-$label no 'slug-shaped', 'not found' or retry warning" no_refusal "$H/out/$id.err"
  say "    record: $(record "$id" '{complete, expired, sources: [.sources[] | {beads, unread}]}')"
  check "A-$label record names the bead with nothing unread" \
    jq -e --arg b "$bead" '.complete == true and (.sources[-1].beads | index($b)) != null and ((.sources[-1].unread // []) == [])' \
    "$LAB/data/$id/record/data-cleanup.json"
  tree_of "$id"
}

resolved_case agent-config t-ac "$AC" ac-proof.png
resolved_case gsp t-gsp "$GSP" gsp-proof.png
say "    after t-gsp: t-ac hold expired by the later teardown? record=$(record t-ac '{complete, expired}')"
check "A-gsp later teardown expired t-ac's hold, re-reading the .agent-config bead" \
  jq -e '.expired == true' "$LAB/data/t-ac/record/data-cleanup.json"
check "A-gsp t-ac's held scratch is gone" [ ! -e "$LAB/data/t-ac/.cleanup-hold" ]
check "A-gsp t-ac's bead-linked file survived expiry" [ -f "$LAB/data/t-ac/ac-proof.png" ]
resolved_case project t-proj "$PROJ" proj-proof.png

say ""
say "=== A-fallback: task t-fb names fb-evidence, absent from the project's beads, present in Firstmate's backlog ==="
fm tasks-axi add fb-evidence 'named evidence' --body 'evidence [capture](fb-proof.png)' --file "$LAB/data/backlog.md" >/dev/null
resolved_case fallback t-fb fb-evidence fb-proof.png

say ""
say "=== A-unread: task t-unread names later-ref, which no database can read yet ==="
seed t-unread later-ref unread-proof.png
teardown t-unread "$BUDGET"; rc=$?
check "A-unread teardown exits 0" [ "$rc" = 0 ]
check "A-unread backlog close completes (state=$(row_state t-unread))" [ "$(row_state t-unread)" = done ]
check "A-unread no pending close left" [ ! -e "$LAB/state/t-unread.backlog-close" ]
check "A-unread task record retired" [ ! -e "$LAB/state/t-unread.meta" ]
check "A-unread teardown output names the unread id" grep -q 'later-ref' "$H/out/t-unread.err"
check "A-unread scratch NOT moved (data kept whole)" [ "$(cat "$LAB/data/t-unread/scratch.bin" 2>/dev/null)" = scratch ]
check "A-unread nothing staged" [ ! -e "$LAB/data/t-unread/.cleanup-hold" ]
say "    record: $(record t-unread '{complete, expired, sources: [.sources[] | {beads, unread}]}')"
check "A-unread record names the unread id and stays incomplete" \
  jq -e '.complete == false and .sources[-1].unread == ["later-ref"]' "$LAB/data/t-unread/record/data-cleanup.json"
tree_of t-unread

say ""
say "=== A-retry: later-ref becomes readable; the next teardown of a different task retries t-unread ==="
fm tasks-axi add later-ref 'late evidence' --body 'evidence [capture](unread-proof.png)' --file "$LAB/data/backlog.md" >/dev/null
add_task t-next
teardown t-next "$BUDGET"; rc=$?
check "A-retry teardown of t-next exits 0" [ "$rc" = 0 ]
say "    t-unread record: $(record t-unread '{complete, expired, sources: [.sources[] | {beads, unread}]}')"
check "A-retry t-unread's unread list cleared" jq -e '(.sources[-1].unread // []) == []' "$LAB/data/t-unread/record/data-cleanup.json"
check "A-retry t-unread scratch now staged" [ -f "$LAB/data/t-unread/.cleanup-hold/scratch.bin" ]
check "A-retry t-unread linked file kept" [ -f "$LAB/data/t-unread/unread-proof.png" ]
tree_of t-unread

say ""
say "backlog after all teardowns:"
sed 's/^/    backlog| /' "$LAB/data/backlog.md"
say ""
say "RESULT: $FAILS failing check(s)"
exit "$FAILS"
