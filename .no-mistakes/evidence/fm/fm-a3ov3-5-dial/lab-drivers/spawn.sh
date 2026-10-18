#!/usr/bin/env bash
# Usage: spawn.sh <task-id> [--keep-placeholder] [--no-brief]
# Scaffold (unless told not to) a local-only ship brief and backlog item in the
# lab home, then run the real bin/fm-spawn.sh as Firstmate would from the lab's
# primary tmux session. Prints the spawn's output and its exit code.
set -u
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56CCG2561MPB8N9JBX9TJ70
. /tmp/fm-cap-drive/lab.env
ID=$1; shift
keep=0; brief=1
for a in "$@"; do case "$a" in --keep-placeholder) keep=1 ;; --no-brief) brief=0 ;; esac; done
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TASKS_AXI_FILE -u TASKS_AXI_BACKEND \
    FM_HOME="${SPAWN_HOME:-$LAB}" TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$LAB/treehouse" FM_BACKEND=tmux \
    TMUX="$TMUXV" TMUX_PANE="$PANE" "$@"
}
TMUXV=$(TMUX_TMPDIR="$SOCK" tmux -L fm-lab display -p -t primary '#{socket_path},#{pid},#{session_id}' | sed 's/,\$/,/')
PANE=$(TMUX_TMPDIR="$SOCK" tmux -L fm-lab display -p -t primary '#{pane_id}')
cd "$WT" || exit 1
if [ "$brief" = 1 ]; then
  labenv "$WT/bin/fm-brief.sh" "$ID" "${SPAWN_PROJECT:-labproj}" --mode local-only >/dev/null || { echo "brief scaffold failed"; exit 1; }
  if [ "$keep" = 0 ]; then
    python3 -I - "${SPAWN_HOME:-$LAB}/data/$ID/brief.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Lab task for project-capacity headroom admission; a stand-in worker idles in its pane.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Nothing to build; this task exists so the spawn can be admitted or deferred.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  fi
  labenv tasks-axi add "$ID" "lab item $ID" --kind ship --file "${SPAWN_HOME:-$LAB}/data/backlog.md" >/dev/null || { echo "backlog add failed"; exit 1; }
fi
start=$(date +%s)
labenv ${SPAWN_PATH_PREFIX:+PATH="$SPAWN_PATH_PREFIX:$PATH"} "$WT/bin/fm-spawn.sh" "$ID" "${SPAWN_HOME:-$LAB}/projects/${SPAWN_PROJECT:-labproj}" \
  --mode local-only --yolo on --harness "$LAB/worker.sh run" 2>&1
rc=$?
printf '[spawn %s exit=%s after %ss]\n' "$ID" "$rc" "$(( $(date +%s) - start ))"
exit "$rc"
