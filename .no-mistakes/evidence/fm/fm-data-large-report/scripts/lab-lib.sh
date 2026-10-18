# Shared helpers for live lab scenarios: a marked disposable FM_HOME, a private
# tmux server on the fm-lab socket, and the real bin/fm-teardown.sh run from the
# gate worktree. Stubs only stand in for external services that would otherwise
# reach the operator's real state (no-mistakes, gh, glab, tea, treehouse).
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M561HYK2NJK7SVS9P7S2W9X9
EV=/Users/dalecarman/.no-mistakes/evidence/01M561HYK2NJK7SVS9P7S2W9X9
GI=(-c user.email=lab@example.invalid -c user.name=lab)

lab_new() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || return 1
  LAB=$(cd -P "$LAB" && pwd -P)
  "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || return 1
  mkdir -p "$LAB/tmux" "$LAB/stubbin" "$LAB/home/.agent-config" "$LAB/home/dev/gsp-beads"
  LBIN=$LAB/stubbin; LHOME=$LAB/home
  printf '#!/usr/bin/env bash\necho "no-mistakes $*" >> "%s/external-calls.log"\nexit 0\n' "$LAB" > "$LBIN/no-mistakes"
  for c in gh gh-axi glab tea; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/external-calls.log"\necho "lab: no forge access" >&2\nexit 1\n' "$c" "$LAB" > "$LBIN/$c"
  done
  printf '#!/usr/bin/env bash\necho "treehouse $*" >> "%s/external-calls.log"\nexit 0\n' "$LAB" > "$LBIN/treehouse"
  chmod +x "$LBIN"/*
  git init -q --bare "$LAB/origin.git"
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
  git -C "$LAB/seed" "${GI[@]}" commit -q --allow-empty -m baseline
  git -C "$LAB/seed" push -q origin main
  PROJ=$LAB/projects/proj
  git clone -q "$LAB/origin.git" "$PROJ"
  git -C "$PROJ" remote set-head origin main 2>/dev/null || true
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 10' > "$LAB/.tasks.toml"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n fm-keep 'sleep 7200'
  LTMUX=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
  echo "lab home: $LAB (tmux $LTMUX)"
}

lab_tmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }

lab_task() { # <id>: in-flight backlog row, task record, live tmux window
  local id=$1
  tasks-axi add "$id" "lab task $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/missing-$id" \
    "project=$PROJ" "kind=ship" "mode=local-only" "spawn_gen=$id" > "$LAB/state/$id.meta"
  lab_tmux new-window -d -t firstmate: -n "fm-$id" 'sleep 7200'
}

lab_env() { # [VAR=value...] command...
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u BEADS_DIR -u BEADS_DB -u BR_DB \
    HOME="$LHOME" FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TMUX="$LTMUX" PATH="$LBIN:$PATH" "$@"
}

lab_teardown() { # <id> [VAR=value...]: real teardown from the gate worktree
  local id=$1; shift
  (cd "$WT" && lab_env "$@" "$WT/bin/fm-teardown.sh" "$id")
}

row_state() { tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }

lab_br() { # <dir> br-args...: real br in a lab-owned database
  local dir=$1; shift
  (cd "$dir" && env -u BEADS_DIR -u BEADS_DB -u BR_DB HOME="$LHOME" br "$@")
}

check() { # <description> <command...>
  local d=$1; shift
  if "$@"; then echo "  PASS: $d"; else echo "  FAIL: $d"; FAILS=$((FAILS + 1)); fi
}

lab_end() {
  lab_tmux kill-server 2>/dev/null || true
}
