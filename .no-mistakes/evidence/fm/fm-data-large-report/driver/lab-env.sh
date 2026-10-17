#!/usr/bin/env bash
# Shared setup for the live task-data scenarios: a marked disposable lab home,
# a disposable HOME (so ~/.agent-config and ~/dev/gsp-beads are lab-local br
# databases), a private tmux socket dir, and the real br/dcg/tasks-axi/jq.
set -u
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M55K1VPQMVY2S65757P9E9Q4
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX
export GIT_AUTHOR_NAME=fmlab GIT_AUTHOR_EMAIL=fmlab@example.invalid GIT_COMMITTER_NAME=fmlab GIT_COMMITTER_EMAIL=fmlab@example.invalid

lab_new() { # prints LAB
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || return 1
  lab=$(cd "$lab" && pwd -P) || return 1
  rmdir "$lab"
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  mkdir -p "$lab/tmux" "$lab/home/.agent-config" "$lab/home/dev/gsp-beads"
  touch "$lab/state/.last-watcher-beat"
  # The real dcg reads the disposable HOME's config. Its default 200 ms hook
  # budget fails closed on this heavily loaded machine, so the lab raises it.
  mkdir -p "$lab/home/.config/dcg"
  printf '[general]\nhook_timeout_ms = 5000\n' > "$lab/home/.config/dcg/config.toml"
  printf '%s\n' "$lab"
}

lab_export() { # <lab>
  export FM_HOME=$1 HOME=$1/home TMUX_TMPDIR=$1/tmux
}

lab_project() { # <lab> : project repo with origin and its own br db (prefix demo)
  local lab=$1
  git init -q --bare "$lab/origin.git"
  git -C "$lab/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$lab/projects/demo"
  git -C "$lab/projects/demo" commit -q --allow-empty -m baseline
  git -C "$lab/projects/demo" remote add origin "$lab/origin.git"
  git -C "$lab/projects/demo" push -q origin main
  (cd "$lab/projects/demo" && br init --prefix demo >/dev/null)
  (cd "$lab/home/.agent-config" && git init -q . && br init --prefix .agent-config >/dev/null)
  (cd "$lab/home/dev/gsp-beads" && git init -q . && br init --prefix gsp >/dev/null)
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$lab/data/backlog.md"
}

lab_bead() { # <dir> <title> <description> : prints new bead id
  (cd "$1" && br create "$2" --description "$3" --json | jq -r .id)
}

lab_task() { # <lab> <id> : backlog row in flight + live task record (local-only ship, worktree gone)
  local lab=$1 id=$2
  tasks-axi add "$id" "lab task $id" --kind ship --file "$lab/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$lab/data/backlog.md" >/dev/null
  mkdir -p "$lab/data/$id"
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$lab/gone-$id" \
    "project=$lab/projects/demo" kind=ship mode=local-only "spawn_gen=$id" > "$lab/state/$id.meta"
}

lab_teardown() { # <lab> <id> [env...] : real bin/fm-teardown.sh against the lab home
  local lab=$1 id=$2
  shift 2
  env "$@" "$ROOT/bin/fm-teardown.sh" "$id"
}

row_state() { # <lab> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}
