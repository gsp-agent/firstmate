#!/usr/bin/env bash
# Helpers sourced by the scenario drivers. Requires ROOT (the lab root).
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56X9093NEEWZJH7PFGG0YPN
LAB=$ROOT/home
TMUXD=$(cat "$ROOT/tmux-dir")
NONCE=${NONCE:-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}

# Run a command in the lab's clean environment: FM_HOME on the lab, the lab's
# private tmux server, its own treehouse pool, the shim ahead of PATH.
lab_run() {
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" \
    PATH="$ROOT/shim:$PATH" SHELL=/bin/bash TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" \
    TMUX_TMPDIR="$TMUXD" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux \
    FM_HOME="$LAB" "$@"
}
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TMUXD" tmux "$@"; }

# Brief + backlog item for one task on one project.
make_task() {  # <id> <project> [placeholder]
  local id=$1 proj=$2 keep=${3:-}
  (cd "$LAB" && lab_run "$WT/bin/fm-brief.sh" "$id" "$proj" --mode local-only) >/dev/null
  if [ -z "$keep" ]; then
    python3 - "$LAB/data/$id/brief.md" "$id" <<'PY'
import sys
path, tid = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text = text.replace("{TASK}", f"Hold a place on this project for capacity lab task {tid}.", 1)
text = text.replace("{FIRSTMATE_SPEC}", "Stay idle; this worker only holds a capacity place.", 1)
open(path, "w", encoding="utf-8").write(text)
PY
  fi
  (cd "$LAB" && lab_run "$WT/bin/fm-tasks-axi.sh" add "$id" "capacity lab $id" --kind ship --repo "$proj") >/dev/null
}

# Spawn one worker; the worker is a raw launch command that only idles.
# A worktree outside the lab pool stops the whole run at once.
spawn() {  # <id> <project>
  local rc=0 wt
  (cd "$LAB" && lab_run "$WT/bin/fm-spawn.sh" "$1" "$LAB/projects/$2" \
    --mode local-only --yolo on --harness "sleep 3600") || rc=$?
  wt=$(sed -n 's/^worktree=//p' "$LAB/state/$1.meta" 2>/dev/null)
  case "$wt" in
    '' | "$ROOT/treehouse/"*) ;;
    *) echo "LAB GUARD: worktree $wt is outside the lab pool; stopping" >&2; exit 99 ;;
  esac
  return "$rc"
}

row_state() {  # <id>
  (cd "$LAB" && lab_run "$WT/bin/fm-tasks-axi.sh" show "$1" 2>/dev/null) | sed -n 's/^  state: *//p' | head -1
}

windows() { lab_tmux list-windows -t firstmate -F '#{window_name} pane_dead=#{pane_dead} pid=#{pane_pid} cmd=#{pane_current_command}'; }

records() {
  local f
  for f in "$LAB/state/project-capacity-overshare"/*; do
    [ -f "$f" ] && printf '%s epoch=%s\n' "${f##*/}" "$(cat "$f")"
  done
  return 0
}

# The origin hash that names the project's shared lock (fm-wake-lib.sh).
lock_identity() {  # <project>
  local origin
  origin=$(cd "$(git -C "$LAB/projects/$1" remote get-url origin)" && pwd -P)
  printf '%s' "$origin" | git hash-object --stdin
}

show() { printf '\n$ %s\n' "$*"; }
