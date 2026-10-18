#!/usr/bin/env bash
# Shared helpers for the live task-data lab runs. Each lab is a disposable,
# marked FM_HOME minted by bin/fm-lab-home.sh, with its own private tmux
# server. Real tools drive the product: bin/fm-teardown.sh, bin/fm-task-data*.{sh,py},
# br, tasks-axi, dcg, jq, python3, git and tmux (on the lab socket only).
# Only the services that would reach the operator's shared state are stubbed:
# no-mistakes (could abort live gate runs), treehouse (shared pool), gh/gh-axi
# (network; lab projects have no forge remote).
set -u
ROOT=${ROOT:?run from the gate worktree with ROOT set}

say() { printf '\n=== %s\n' "$*"; }
check() { # <description> <command...>
  local what=$1; shift
  if "$@"; then printf 'PASS: %s\n' "$what"; else printf 'FAIL: %s\n' "$what"; FAILS=$((FAILS + 1)); fi
}
FAILS=0

new_lab() { # sets LAB TMUXDIR STUBS PROJ
  # Physical path: macOS TMPDIR sits under the /var symlink, and task-data
  # cleanup refuses data directories with symlinked ancestors by design.
  LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  STUBS="$LAB/stubs"
  mkdir -p "$STUBS" "$LAB/home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/no-mistakes"
  cat > "$STUBS/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$STUBS/gh-axi" "$STUBS/gh"
  chmod +x "$STUBS"/*
  PROJ="$LAB/projects/proj"
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m "lab baseline"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  touch "$LAB/state/.last-watcher-beat"
  labtmux new-session -d -s firstmate -n keep 'sleep 3600'
  echo "lab home: $LAB (tmux dir $TMUXDIR)"
}

labtmux() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux "$@"; }

# Start a backlog task with a lab tmux window and a record, as spawn would.
add_task() { # <id>
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  labtmux new-window -d -t firstmate: -n "fm-$id" 'sleep 3600'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/missing" \
    "project=$PROJ" "kind=ship" "mode=local-only" "spawn_gen=$id" > "$LAB/state/$id.meta"
  mkdir -p "$LAB/data/$id"
}

# Run the real teardown in the lab: FM_HOME only, no fleet overrides.
lab_teardown() { # <id> [VAR=value...]; writes $LAB/<id>.out/.err, returns its rc
  local id=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u BEADS_PATH \
    FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" PATH="$STUBS:$PATH" "$@" \
    "$ROOT/bin/fm-teardown.sh" "$id" > "$LAB/$id.out" 2> "$LAB/$id.err"
}

# The advertised by-hand command, run the same way.
lab_by_hand() { # <id> <out-prefix> [VAR=value...]
  local id=$1 out=$2; shift 2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u TMUX -u BEADS_PATH PATH="$STUBS:$PATH" "$@" \
    bash "$ROOT/bin/fm-task-data-lib.sh" expire "$LAB/data" "$LAB/state" "$id" > "$out.out" 2> "$out.err"
}

row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
record() { cat "$LAB/data/$1/record/data-cleanup.json"; }
show() { printf -- '--- %s\n' "$1"; cat "$1"; }

end_lab() {
  labtmux kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
}
