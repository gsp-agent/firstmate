#!/usr/bin/env bash
# Live scenario: a teardown whose brief names beads that cannot be read keeps
# that task's data whole, still closes the backlog item, names the unread ids,
# and a later teardown of another task retries and stages it once readable.
# Also runs one teardown with BEADS_DIR/BEADS_DB/BR_DB pointing at the wrong
# database to show owner routing ignores them.
# Usage: s2-unread-beads.sh <worktree> <lab>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"

listing() { (cd "$LAB/data/$1" && find . -type f ! -path './record/*' | sort); }
row() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
record() { jq -c '{complete, expired, expiry, sources: [.sources[] | {beads, unread}]}' "$LAB/data/$1/record/data-cleanup.json"; }
pending_close() { if [ -e "$LAB/state/$1.backlog-close" ]; then echo "PENDING: $(tr '\n' ' ' < "$LAB/state/$1.backlog-close")"; else echo none; fi; }

bash "$E/lab-task.sh" "$LAB" t-unread
printf '# Task\nBead: zzz-missing1\n' > "$LAB/data/t-unread/brief.md"
printf 'PNG-bytes that only the unread bead would link\n' > "$LAB/data/t-unread/unread-proof.png"
printf 'scratch\n' > "$LAB/data/t-unread/discard.bin"
echo "=================== teardown t-unread (Bead: zzz-missing1 is in no database)"
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-unread; echo "--- exit $?"
echo "--- data/t-unread:"; listing t-unread
echo "--- backlog row: $(row t-unread)"
echo "--- pending close: $(pending_close t-unread)"
echo "--- record: $(record t-unread)"

echo
echo "=================== make zzz-missing1 readable (Firstmate backlog row linking the proof)"
tasks-axi add zzz-missing1 "now readable" --body '[capture](unread-proof.png)' --file "$LAB/data/backlog.md" >/dev/null
bash "$E/lab-task.sh" "$LAB" t-retry1
printf '# Task\nno beads\n' > "$LAB/data/t-retry1/brief.md"
echo "=================== teardown t-retry1 (a different task; its expiry pass retries t-unread)"
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-retry1; echo "--- exit $?"
echo "--- data/t-unread:"; listing t-unread
echo "--- record: $(record t-unread)"

echo
bash "$E/lab-task.sh" "$LAB" t-unread-gsp
printf '# Task\nBead: gsp-zzz999\n' > "$LAB/data/t-unread-gsp/brief.md"
printf 'scratch\n' > "$LAB/data/t-unread-gsp/discard.bin"
echo "=================== teardown t-unread-gsp (Bead: gsp-zzz999 is missing from ~/dev/gsp-beads; gsp ids never fall back elsewhere)"
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-unread-gsp; echo "--- exit $?"
echo "--- data/t-unread-gsp:"; listing t-unread-gsp
echo "--- backlog row: $(row t-unread-gsp)"
echo "--- pending close: $(pending_close t-unread-gsp)"
echo "--- record: $(record t-unread-gsp)"

echo
echo "=================== adversarial: wrong BEADS_DIR/BEADS_DB/BR_DB in the teardown environment"
ac=$(cd "$HOME/.agent-config" && br create "routing bead" -d "evidence [capture](route-proof.png)" --json | jq -r .id)
bash "$E/lab-task.sh" "$LAB" t-route
printf '# Task\nBead: %s\n' "$ac" > "$LAB/data/t-route/brief.md"
printf 'PNG-bytes linked only from the bead\n' > "$LAB/data/t-route/route-proof.png"
printf 'scratch\n' > "$LAB/data/t-route/discard.bin"
bash "$E/lab-teardown.sh" "$WT" "$LAB" t-route BEADS_DIR="$proj/.beads" BEADS_DB="$proj/.beads/beads.db" BR_DB="$proj/.beads/beads.db"
echo "--- exit $?"
echo "--- data/t-route:"; listing t-route
echo "--- backlog row: $(row t-route)"
echo "--- record: $(record t-route)"
