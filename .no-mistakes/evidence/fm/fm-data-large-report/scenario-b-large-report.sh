#!/usr/bin/env bash
# Scenario B: a kept report over 1 MiB no longer blocks preparation, and an
# owner-prefixed id missing from its own database is unread (never a refusal
# that blocks the close). The next teardown runs with an invalid expiry budget.
# Usage: scenario-b-large-report.sh <fresh-empty-lab-dir> <fresh-empty-home-dir>
. "$(dirname "$0")/lab-common.sh"
trap lab_down EXIT
lab_up

say "=== B-large: task t-big keeps a 1.4 MB report.md whose last line links proof/capture.png ==="
add_task t-big
mkdir -p "$LAB/data/t-big/proof"
{ head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$LAB/data/t-big/report.md"
printf 'keep this image\n' > "$LAB/data/t-big/proof/capture.png"
printf 'scratch\n' > "$LAB/data/t-big/scratch.bin"
say "    report.md bytes: $(wc -c < "$LAB/data/t-big/report.md" | tr -d ' ')"
teardown t-big; rc=$?
check "B-large teardown exits 0" [ "$rc" = 0 ]
check "B-large backlog row is done (state=$(row_state t-big))" [ "$(row_state t-big)" = done ]
check "B-large no pending close left" [ ! -e "$LAB/state/t-big.backlog-close" ]
check "B-large no 'exceeds 1 MiB' refusal" bash -c '! grep -q "exceeds 1 MiB" "$1"' _ "$H/out/t-big.err"
check "B-large scratch staged" [ -f "$LAB/data/t-big/.cleanup-hold/scratch.bin" ]
check "B-large file linked at the end of the large report kept" [ -f "$LAB/data/t-big/proof/capture.png" ]
check "B-large report bytes unchanged" [ "$(wc -c < "$LAB/data/t-big/report.md" | tr -d ' ')" = 1400041 ]
say "    record: $(record t-big '{complete, expired, sources: [.sources[] | {beads, unread}]}')"
tree_of t-big

say ""
say "=== B-owner-unread: task t-missing names .agent-config-zz9 and gsp-zz9, absent from their databases (gsp-zz9 IS a Firstmate backlog row) ==="
fm tasks-axi add gsp-zz9 'decoy row' --body '[capture](decoy.png)' --file "$LAB/data/backlog.md" >/dev/null
add_task t-missing
printf 'Bead .agent-config-zz9 and bead gsp-zz9\n' > "$LAB/data/t-missing/brief.md"
printf 'decoy\n' > "$LAB/data/t-missing/decoy.png"
printf 'scratch\n' > "$LAB/data/t-missing/scratch.bin"
teardown t-missing; rc=$?
check "B-owner-unread teardown exits 0" [ "$rc" = 0 ]
check "B-owner-unread backlog close completes (state=$(row_state t-missing))" [ "$(row_state t-missing)" = done ]
check "B-owner-unread no pending close left" [ ! -e "$LAB/state/t-missing.backlog-close" ]
check "B-owner-unread no 'slug-shaped' refusal" bash -c '! grep -q "slug-shaped" "$1"' _ "$H/out/t-missing.err"
check "B-owner-unread output names .agent-config-zz9" grep -q '\.agent-config-zz9' "$H/out/t-missing.err"
check "B-owner-unread output names gsp-zz9 (not resolved from Firstmate's backlog)" grep -q 'gsp-zz9' "$H/out/t-missing.err"
check "B-owner-unread data kept whole" [ -f "$LAB/data/t-missing/scratch.bin" ]
check "B-owner-unread nothing staged" [ ! -e "$LAB/data/t-missing/.cleanup-hold" ]
say "    record: $(record t-missing '{complete, expired, sources: [.sources[] | {beads, unread}]}')"
check "B-owner-unread record lists both unread ids" \
  jq -e '.complete == false and (.sources[-1].unread | sort) == [".agent-config-zz9", "gsp-zz9"]' "$LAB/data/t-missing/record/data-cleanup.json"

say ""
say "=== B-expire: next teardown with FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=0 (invalid, must fall back to 10) expires t-big's hold ==="
add_task t-next
teardown t-next FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=0; rc=$?
check "B-expire teardown exits 0" [ "$rc" = 0 ]
check "B-expire t-big hold expired" jq -e '.expired == true' "$LAB/data/t-big/record/data-cleanup.json"
check "B-expire t-big held scratch removed" [ ! -e "$LAB/data/t-big/.cleanup-hold" ]
check "B-expire large report kept" [ -f "$LAB/data/t-big/report.md" ]
check "B-expire link from the large report kept" [ -f "$LAB/data/t-big/proof/capture.png" ]
check "B-expire t-missing still kept whole (still unreadable)" [ -f "$LAB/data/t-missing/scratch.bin" ]
tree_of t-big

say ""
say "RESULT: $FAILS failing check(s)"
exit "$FAILS"
