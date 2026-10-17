#!/usr/bin/env bash
# lab-lib.sh - sourced by the live scenario drivers in this evidence directory.
# Each scenario mints its own disposable firstmate lab home with
# bin/fm-lab-home.sh and drives the real retirement code (fm-task-data.py,
# the teardown retirement hooks, and bin/fm-teardown.sh) with FM_HOME=<lab>
# and no FM_*_OVERRIDE. Real python3, tasks-axi, jq, tmux (lab-private
# socket only) and dcg are used. External services teardown talks to for
# unrelated steps are disposable stand-ins inside the lab: gh-axi answers the
# lab's own PR fixtures (lab/prs/<number>; anything else is unreadable, exit 2),
# and treehouse/no-mistakes/gh are no-ops so no real worktree pool or gate run
# is touched.
ROOT=${ROOT:-/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53SQGEGDY4VTCKTFHZEBF7T}
EV=${EV:-/Users/dalecarman/.no-mistakes/evidence/01M53SQGEGDY4VTCKTFHZEBF7T}

lab_new() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || return 1
  lab=$(cd "$lab" && pwd -P) || return 1
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  mkdir -p "$lab/tmux" "$lab/fakebin" "$lab/history" "$lab/prs" "$lab/projects/demo"
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "history/completed.md"
TOML
  cat > "$lab/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list") printf '%s\n' 'count: 0 (showing first 0)' 'pull_requests[]: []'; exit 0 ;;
  "pr view")
    printf '%s\n' "gh-axi \$*" >> '$lab/gh-axi.calls'
    f='$lab/prs/'"\${3:-}"
    [ -f "\$f" ] && exec cat "\$f"
    echo "error: pull request not found" >&2; exit 2 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr view") exit 1 ;; esac\nexit 0\n' > "$lab/fakebin/gh"
  chmod +x "$lab/fakebin/"*
  printf '%s\n' "$lab"
}

# Run a command against the lab home only: no fleet-path overrides, no
# inherited TMUX, and a tmux default socket private to the lab.
lab_run() {
  local lab=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u TMUX -u TMUX_PANE \
    FM_HOME="$lab" TMUX_TMPDIR="$lab/tmux" PATH="$lab/fakebin:$PATH" "$@"
}

# fm-task-data.py <action> under the task's meta lock, as its contract requires.
lab_helper() {
  local lab=$1
  shift
  lab_run "$lab" bash "$EV/locked-helper.sh" "$ROOT" "$lab" "$@"
}

# The real teardown of a different, already-landed local-only task: the
# "next completed task" cycle that expires other tasks' holds.
lab_teardown_other() {
  local lab=$1 id=$2
  touch "$lab/state/.last-watcher-beat"
  lab_run "$lab" tasks-axi add "$id" "next completed task" --kind ship --file "$lab/data/backlog.md" >/dev/null || return 1
  lab_run "$lab" tasks-axi start "$id" --file "$lab/data/backlog.md" >/dev/null || return 1
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$lab/missing-$id" \
    "project=$lab/projects/demo" "kind=ship" "mode=local-only" "spawn_gen=$id" > "$lab/state/$id.meta"
  lab_run "$lab" "$ROOT/bin/fm-teardown.sh" "$id"
}

kib() { du -sk "$1" | awk '{print $1}'; }
show_tree() { (cd "$1" && find . -path ./record -prune -o -type f -print | LC_ALL=C sort); }
record_view() { jq -c '{complete, expired, sources: [.sources[] | {pr, legacy: (.backlog.legacy // false), closed: (.backlog.closed // false), unread: (.unread // [])}]}' "$1/record/data-cleanup.json"; }
