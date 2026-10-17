#!/usr/bin/env bash
# Live scenario: teardowns whose briefs name beads owned by different databases.
# Usage: s1-named-beads.sh <worktree> <lab>
set -uo pipefail
WT=${1:?} LAB=${2:?}
E=$(cd "$(dirname "$0")" && pwd)
export HOME="$LAB/home"
proj="$LAB/projects/demo"

bead_in() { # <dir> <title> <description> -> prints id
  (cd "$1" && br create "$2" -d "$3" --json | jq -r .id)
}
show_task() { # <id>
  local id=$1
  echo "--- data/$id after teardown:"
  (cd "$LAB/data/$id" && find . -type f ! -path './record/*' | sort)
  echo "--- backlog row: $(tasks-axi show "$id" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)"
  if [ -e "$LAB/state/$id.backlog-close" ]; then echo "--- PENDING CLOSE: $(cat "$LAB/state/$id.backlog-close")"; else echo "--- no pending close"; fi
  [ -e "$LAB/state/$id.meta" ] && echo "--- task record still present" || echo "--- task record retired"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t firstmate -F '#{window_name}' | grep -qx "fm-$id" \
    && echo "--- tmux window fm-$id still open" || echo "--- tmux window fm-$id closed"
  echo "--- record/data-cleanup.json:"
  jq -c '{complete, expired, expiry, sources: [.sources[] | {beads, unread}]}' "$LAB/data/$id/record/data-cleanup.json" 2>/dev/null || echo "(none)"
}
run_case() { # <id> <bead line> <proof file>
  local id=$1 line=$2 proof=$3 rc
  bash "$E/lab-task.sh" "$LAB" "$id"
  printf '# Task\n%s\n' "$line" > "$LAB/data/$id/brief.md"
  printf 'PNG-bytes linked only from the bead\n' > "$LAB/data/$id/$proof"
  printf 'scratch\n' > "$LAB/data/$id/discard.bin"
  echo "=================== teardown $id ($line)"
  bash "$E/lab-teardown.sh" "$WT" "$LAB" "$id"
  rc=$?
  echo "--- exit $rc"
  show_task "$id"
}

ac=$(bead_in "$HOME/.agent-config" "lab dotted bead" "evidence [capture](ac-proof.png)")
gsp=$(bead_in "$HOME/dev/gsp-beads" "lab gsp bead" "evidence [capture](gsp-proof.png)")
demo=$(bead_in "$proj" "lab project bead" "evidence [capture](demo-proof.png)")
tasks-axi add lab-fallback1 "backlog-owned bead" --body '[capture](fb-proof.png)' --file "$LAB/data/backlog.md" >/dev/null
echo "beads: $ac (in ~/.agent-config) $gsp (in ~/dev/gsp-beads) $demo (in project) lab-fallback1 (Firstmate backlog row)"

run_case t-agentcfg "Bead: $ac" ac-proof.png
run_case t-gsp "Bead: $gsp" gsp-proof.png
run_case t-project "Bead: $demo" demo-proof.png
run_case t-fallback "Bead: lab-fallback1" fb-proof.png
