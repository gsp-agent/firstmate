#!/usr/bin/env bash
# Live driver for the task-data cleanup change (branch fm/fm-data-large-report).
# Runs the real bin/fm-teardown.sh from the gate worktree against disposable,
# marked lab homes (bin/fm-lab-home.sh), a disposable user HOME that holds real
# br databases for .agent-config-*, gsp-* and project beads, a real markdown
# backlog through tasks-axi, real dcg for expiry, and a private tmux server
# (TMUX_TMPDIR from fm-lab-home.sh tmux-dir; TMUX unset). Nothing is stubbed.
# Continuation of live-lab-driver.sh lab A (S7, S8) after that run hit the agent's 10-minute
# background limit mid-S7; S7 reruns under a fresh task id in the same lab A home.
# Usage: live-lab-driver-labA-cont.sh <repo-worktree> <workspace-dir> <evidence-dir>
set -u
ROOT=$1 E=$3
W=$(cd -P "$2" && pwd -P) || exit 1
mkdir -p "$E/live"
LOG="$E/live/transcript-labA-cont.txt"
: > "$LOG"
FAILS=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
check() { # <label> <command...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then say "PASS: $label"; else say "FAIL: $label"; FAILS=$((FAILS + 1)); fi
}
UH="$W/home"
PROJ="$W/proj"
DECOY="$W/decoy"
mkdir -p "$UH/.agent-config" "$UH/dev/gsp-beads" "$PROJ" "$DECOY"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

ubr() { (cd "$1" && shift && env -u BEADS_DIR -u BEADS_DB -u BR_DB HOME="$UH" br "$@"); }
newbead() { # <dir> <title> <description> -> id
  ubr "$1" create "$2" --description "$3" --json | jq -r .id
}
# Bead databases were created by live-lab-driver.sh in the same workspace.

mklab() { # <name> -> sets LAB, TMUXDIR
  LAB="$W/$1"
  bash "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  TMUXDIR=$(bash "$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  printf 'tmux\n' > "$LAB/config/backend"
  cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  touch "$LAB/state/.last-watcher-beat"
  env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s firstmate -n keepalive 'sleep 7200'
}
labtmux() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux "$@"; }
task() { # <id>: backlog row in flight, live tmux window, task record
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  labtmux new-window -d -t firstmate -n "fm-$id" 'sleep 7200'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$W/gone-$id" \
    "project=$PROJ" "kind=ship" "mode=local-only" "spawn_gen=lab-$id" > "$LAB/state/$id.meta"
  mkdir -p "$LAB/data/$id"
}
teardown() { # <id> [VAR=value...]: run the real teardown in the lab; sets RC
  local id=$1; shift
  local start=$SECONDS
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    HOME="$UH" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" \
    FM_TEARDOWN_DATA_STAGE_TIMEOUT=120 FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=60 \
    BEADS_DIR="$DECOY/.beads" BEADS_DB="$DECOY/.beads/beads.db" BR_DB="$DECOY/.beads/beads.db" \
    "$@" "$ROOT/bin/fm-teardown.sh" "$id" > "$E/live/$id.out" 2> "$E/live/$id.err"
  RC=$?
  say "--- teardown $id (lab $(basename "$LAB")) exit=$RC in $((SECONDS - start))s"
  sed 's/^/  stdout: /' "$E/live/$id.out" | tee -a "$LOG" >/dev/null
  sed 's/^/  stderr: /' "$E/live/$id.err" | tee -a "$LOG" >/dev/null
}
row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
rec() { jq -c "$2" "$LAB/data/$1/record/data-cleanup.json"; }
snap() { # <id> <label>
  local id=$1
  {
    echo "  [$2] data/$id files:"
    (cd "$LAB/data/$id" 2>/dev/null && find . \( -type f -o -type l \) ! -path './clone/*' | sort | sed 's/^/    /'
     [ -d clone ] && echo "    ./clone/: $(find clone -type f | wc -l | tr -d ' ') files"
     [ -d .cleanup-hold/clone ] && echo "    ./.cleanup-hold/clone/: $(find .cleanup-hold/clone -type f | wc -l | tr -d ' ') files")
    echo "  [$2] record: $(jq -c '{complete, expired, expiry, retained, sources: [.sources[] | {beads, unread}]}' "$LAB/data/$id/record/data-cleanup.json" 2>/dev/null | cut -c1-600)"
    echo "  [$2] backlog row $id: $(row_state "$id"); pending close file: $([ -e "$LAB/state/$id.backlog-close" ] && echo present || echo absent); task record: $([ -e "$LAB/state/$id.meta" ] && echo present || echo absent); tmux window fm-$id: $(labtmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo present || echo gone)"
  } | tee -a "$LOG" >/dev/null
}
retired_and_closed() { [ "$RC" = 0 ] && [ "$(row_state "$1")" = done ] && [ ! -e "$LAB/state/$1.backlog-close" ] && [ ! -e "$LAB/state/$1.meta" ]; }
staged() { [ -e "$LAB/data/$1/.cleanup-hold/discard.bin" ] && [ ! -e "$LAB/data/$1/discard.bin" ]; }
whole() { [ ! -e "$LAB/data/$1/.cleanup-hold" ] && [ -e "$LAB/data/$1/discard.bin" ]; }

say "=== Lab A continued (S7 rerun as la-huge2, S8)"
LAB="$W/labA"
TMUXDIR=$(cat "$LAB/state/.fm-lab-tmux-dir")
labtmux has-session -t firstmate 2>/dev/null || labtmux new-session -d -s firstmate -n keepalive "sleep 7200"
say "## S7 kept report over 16 MiB keeps the folder whole and names the file; close completes"
task la-huge2
head -c $((17 * 1024 * 1024)) /dev/zero | tr '\0' 'y' > "$LAB/data/la-huge2/report.md"
printf 'scratch\n' > "$LAB/data/la-huge2/discard.bin"
teardown la-huge2
snap la-huge2 after-teardown
check "S7 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-huge2
check "S7 folder kept whole" whole la-huge2
check "S7 report.md named in teardown output and record" bash -c 'grep -q "report.md" "$1" && jq -e ".complete == false and (.sources[0].unread | index(\"report.md\"))" "$2"' _ "$E/live/la-huge2.err" "$LAB/data/la-huge2/record/data-cleanup.json"

say "## S8 stage past FM_TEARDOWN_DATA_STAGE_TIMEOUT=1 (near-16 MiB report, 200 unmatched files) moves nothing; close completes"
task la-stage
head -c $((16 * 1024 * 1024 - 4096)) /dev/zero | tr '\0' 'z' > "$LAB/data/la-stage/report.md"
mkdir -p "$LAB/data/la-stage/clone"
for i in $(seq 1 200); do printf 'unmatched %s\n' "$i" > "$LAB/data/la-stage/clone/scratch-$i.bin"; done
printf 'scratch\n' > "$LAB/data/la-stage/discard.bin"
teardown la-stage FM_TEARDOWN_DATA_STAGE_TIMEOUT=1
snap la-stage after-teardown
check "S8 teardown exits 0, retired, backlog row done, no pending close" retired_and_closed la-stage
check "S8 nothing moved: no .cleanup-hold, all 200 files and scratch in place" bash -c '[ ! -e "$1/.cleanup-hold" ] && [ -e "$1/discard.bin" ] && [ "$(find "$1/clone" -type f | wc -l | tr -d " ")" = 200 ]' _ "$LAB/data/la-stage"
check "S8 warning names the task and the stage limit" grep -q 'la-stage.*stage limit' "$E/live/la-stage.err"
check "S8 record retained field names the limit" jq -e '.complete == false and (.retained | test("stage limit"))' "$LAB/data/la-stage/record/data-cleanup.json"

labtmux kill-server 2>/dev/null || true
bash "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true

say "=== live checks failed: $FAILS"
exit "$FAILS"
