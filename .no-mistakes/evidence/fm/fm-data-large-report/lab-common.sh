#!/usr/bin/env bash
# Shared setup for the live task-data scenarios. Sourced by scenario-*.sh.
# Drives the real bin/fm-teardown.sh and bin/fm-send.sh from the run worktree
# against a disposable marked lab home ($LAB), a disposable HOME ($H) holding
# real br databases for ~/.agent-config and ~/dev/gsp-beads, and the lab's own
# private tmux socket. Nothing here touches the operator's home, fleet or tmux.
set -u
ROOT=${ROOT:-/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M54HTDXBEM2HDQP19MSPVBF0}
EVID=${EVID:-/Users/dalecarman/.no-mistakes/evidence/01M54HTDXBEM2HDQP19MSPVBF0}
LAB=$1
H=$2
P="$LAB/projects/proj"
TMUXDIR="$LAB/tmux"
FAILS=0

say() { printf '%s\n' "$*"; }
ok() { say "PASS: $*"; }
bad() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() { # <description> <command...>
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

ltmux() { TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab "$@"; }

# Run a command the way the lab primary would: stock FM_HOME, no fleet-path
# overrides, the lab tmux server as $TMUX, and the disposable HOME.
fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    HOME="$H" FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" TMUX="$LAB_TMUX_ENV" \
    FM_SUPERVISION_ACTOR=main "$@"
}

hbr() { HOME="$H" br "$@"; }

lab_up() {
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
  mkdir -p "$TMUXDIR"
  ltmux new-session -d -s firstmate -n keep 'sleep 86400' || { say "lab tmux failed"; exit 1; }
  LAB_TMUX_ENV="$(ltmux display -p -t firstmate '#{socket_path},#{pid},0')"
  # A primary with a running watcher keeps this beacon fresh.
  touch "$LAB/state/.last-watcher-beat"
  # Firstmate's markdown backlog in the lab home.
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 10' > "$LAB/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  # The task's project: a git repo with its own beads database.
  git init -q -b main "$P"
  git -C "$P" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m 'lab baseline'
  (cd "$P" && hbr init --prefix proj -q)
  # The disposable HOME: the two bead databases the intent names, and dcg's
  # hook budget set as on this machine's real config (5000 ms).
  mkdir -p "$H/.agent-config" "$H/dev/gsp-beads" "$H/.config/dcg"
  (cd "$H/.agent-config" && hbr init --prefix .agent-config -q)
  (cd "$H/dev/gsp-beads" && hbr init --prefix gsp -q)
  printf '%s\n' '[general]' 'hook_timeout_ms = 5000' > "$H/.config/dcg/config.toml"
}

lab_down() {
  ltmux kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
}

# A ship task that spawn recorded and whose worker already finished: backlog
# row in flight, task record, a live tmux window on the lab socket standing in
# for the crew pane, and a worktree that is already gone.
add_task() { # <id>
  local id=$1
  fm tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  fm tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  ltmux new-window -d -t firstmate -n "fm-$id" 'sleep 86400'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/gone-$id" \
    "project=$P" "kind=ship" "mode=local-only" "spawn_gen=lab-$id" > "$LAB/state/$id.meta"
  mkdir -p "$LAB/data/$id"
}

row_state() { fm tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
window_present() { ltmux list-windows -t firstmate -F '#{window_name}' | grep -qxF "fm-$1"; }
record() { jq -c "$2" "$LAB/data/$1/record/data-cleanup.json"; }

teardown() { # <id> [env assignments...] ; output in $H/out/<id>.{out,err}
  local id=$1 rc
  shift
  OUTDIR="$H/out"
  mkdir -p "$OUTDIR"
  fm "$@" "$ROOT/bin/fm-teardown.sh" "$id" > "$OUTDIR/$id.out" 2> "$OUTDIR/$id.err"
  rc=$?
  say "\$ FM_HOME=<lab> $* bin/fm-teardown.sh $id   -> exit $rc"
  sed 's/^/    out| /' "$OUTDIR/$id.out"
  sed 's/^/    err| /' "$OUTDIR/$id.err"
  return "$rc"
}

tree_of() { (cd "$LAB/data/$1" && find . -path ./record -prune -o -type f -print | sort | sed 's/^/    file| /'); }
