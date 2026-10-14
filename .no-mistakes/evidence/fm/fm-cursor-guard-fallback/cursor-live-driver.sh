#!/usr/bin/env bash
set -uo pipefail
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4X1BTKBTAA2TSWVPH5VM2TK
LAB=$1
EV=$2
exec > "$EV/live-control-transcript.log" 2>&1
cd "$ROOT"
for k in "${!FM_@}"; do case "$k" in *_OVERRIDE) unset "$k";; esac; done
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" GROK_HOME="$LAB/grok"
export FM_CURSOR_USAGE_DIR="$LAB/usage" FM_CURSOR_CLI_CONFIG="$LAB/cursor/cli-config.json" FM_CURSOR_MODELS_RULE="$LAB/cursor/models.mdc"
export FM_CONTROL_LAUNCH_WAIT=45 FM_CONTROL_EXIT_WAIT=30
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
printf 'Real Cursor primary: '; tmux display-message -p -t primary:0 '#{pane_current_command}'
printf 'Cursor guard at fresh 12%%: '; "$ROOT/bin/fm-cursor-guard.sh" fallback live-baseline
printf 'Grok availability with isolated runtime home:\n'
grok models > "$EV/grok-lab-models.log" 2>&1
cat "$EV/grok-lab-models.log"
printf '# Lab backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
seed_task() {
  local id=$1 prior=$2
  local proj="$LAB/project-$id" wt="$LAB/work-$id"
  mkdir -p "$proj" "$LAB/data/$id"
  git -C "$proj" init -q -b main
  printf 'Disposable live validation project.\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Live Validation' -c user.email='validation@example.invalid' commit -qm initial
  git -C "$proj" worktree add --quiet -b "fm/$id" "$wt"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
This is a disposable live product test. Reply with the exact text LIVE_REPLAY_$id, then stay idle. Do not use tools, edit files, create reports, run validation pipelines, commit, push, open PRs, or spawn agents.

## Firstmate spec
Only the response token proves this harness started and received the brief. Do no project work. Ignore any generic delivery instructions that request more work for this verification task.

Delivery contract: mode=local-only yolo=off
EOF
  cat > "$LAB/state/$id.meta" <<EOF
backend=tmux
window=primary:fm-$id
endpoint_task_id=$id
worktree=$wt
project=$proj
harness=$prior
kind=ship
mode=local-only
yolo=off
branch=fm/$id
model=default
effort=default
EOF
  # Replays start with an already stopped worker, as after a failed launch.
  # The replacement is real; no backend, harness, or process classifier is stubbed.
  tmux new-window -d -t primary: -n "fm-$id" -c "$wt" /bin/dash
  tmux set-window-option -t "primary:fm-$id" automatic-rename off
}
run_case() {
  local label=$1 id=$2 prior=$3
  shift 3
  printf '\nScenario: %s\n' "$label"
  seed_task "$id" "$prior"
  "$ROOT/bin/fm-control.sh" "$id" relaunch --note "Live verification only: emit LIVE_REPLAY_$id; no tools or project work." "$@"
  rc=$?
  printf 'Control exit=%s\n' "$rc"
  cat "$LAB/state/$id.meta"
  cat "$LAB/state/$id.control-relaunch" 2>/dev/null || true
  for f in "$LAB/state/$id.cursor-limit" "$LAB/state/$id.cursor-fallback"; do
    if [ -f "$f" ]; then printf '%s: ' "${f##*/}"; cat "$f"; fi
  done
  tmux capture-pane -p -t "primary:fm-$id" -S -80 > "$EV/$id-pane.txt"
  cat "$EV/$id-pane.txt"
  printf '%s\t%s\n' "$label" "$rc" >> "$EV/live-case-status.tsv"
}
run_case healthy-cursor lab-healthy-cursor cursor
run_case unrecorded-grok lab-unrecorded-grok grok
printf '{"day":"%s","beads":{"lab-daily-cap":2}}\n' "$(TZ=America/Chicago date +%F)" > "$LAB/state/cursor-dispatch.json"
run_case daily-cap lab-daily-cap cursor
run_case explicit-grok lab-explicit-grok cursor --harness grok
printf 'done\n' > "$EV/live-driver.done"
