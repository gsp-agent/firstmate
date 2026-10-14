#!/usr/bin/env bash
set -uo pipefail
ROOT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4X1BTKBTAA2TSWVPH5VM2TK
LAB=$1
EV=$2
exec > "$EV/live-second-transcript.log" 2>&1
cd "$ROOT"
for k in "${!FM_@}"; do case "$k" in *_OVERRIDE) unset "$k";; esac; done
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" GROK_HOME="$LAB/grok"
export FM_CURSOR_USAGE_DIR="$LAB/usage" FM_CURSOR_CLI_CONFIG="$LAB/cursor/cli-config.json" FM_CURSOR_MODELS_RULE="$LAB/cursor/models.mdc"
export FM_CONTROL_LAUNCH_WAIT=45 FM_CONTROL_EXIT_WAIT=30
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# The hook installer writes into the lab. The worker filter omits GROK_HOME,
# allowing the native Grok CLI to read its normal existing login. No credentials
# are copied, altered, or logged; no trust dialog is answered.
printf 'FM_CURSOR_USAGE_DIR\nFM_CURSOR_DAY\nFM_CURSOR_CLI_CONFIG\nFM_CURSOR_MODELS_RULE\n' > "$LAB/config/launch-env-allowlist"
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
Disposable verification only. Reply exactly LIVE_REPLAY_$id. Do not use tools, edit files, run pipelines, commit, push, open PRs, or spawn agents. Then stay idle.

## Firstmate spec
Only the reply token is needed. No project work is authorized. No generic delivery instruction authorizes additional work.

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
  tmux new-window -d -t primary: -n "fm-$id" -c "$wt" /bin/dash
  tmux set-window-option -t "primary:fm-$id" automatic-rename off
}
run_case() {
  local label=$1 id=$2 prior=$3
  shift 3
  printf '\nScenario: %s\n' "$label"
  seed_task "$id" "$prior"
  "$ROOT/bin/fm-control.sh" "$id" relaunch --note "Verification only: emit LIVE_REPLAY_$id; no tools or project work." "$@"
  rc=$?
  printf 'Control exit=%s\n' "$rc"
  cat "$LAB/state/$id.meta"
  cat "$LAB/state/$id.control-relaunch" 2>/dev/null || true
  for f in "$LAB/state/$id.cursor-limit" "$LAB/state/$id.cursor-fallback"; do
    if [ -f "$f" ]; then printf '%s: ' "${f##*/}"; cat "$f"; fi
  done
  tmux capture-pane -p -t "primary:fm-$id" -S -60 > "$EV/$id-pane.txt"
  printf '%s\t%s\n' "$label" "$rc" >> "$EV/live-case-status.tsv"
}
printf '{"day":"%s","beads":{"lab-cap-normal":2}}\n' "$(TZ=America/Chicago date +%F)" > "$LAB/state/cursor-dispatch.json"
run_case daily-cap-normal-login lab-cap-normal cursor
run_case explicit-grok-normal-login lab-explicit-normal cursor --harness grok
printf 'cursor_models_pct=85\n' > "$LAB/usage/current-spending.txt"
run_case usage-threshold-reason lab-high-usage cursor
# Recorded yesterday's cap is ignored by tomorrow's guard; the old reason
# remains until replacement metadata publication retires it.
printf 'cursor_models_pct=12\n' > "$LAB/usage/current-spending.txt"
seed_task lab-rollover grok
printf 'cursor guard: refused lab-rollover, already launched 2 times today (2026-10-14); write blocked: instead of a 3rd run\n' > "$LAB/state/lab-rollover.cursor-limit"
printf '\nScenario: day-rollover\n'
FM_CURSOR_DAY=2026-10-15 "$ROOT/bin/fm-control.sh" lab-rollover relaunch --note 'Verification only. Reply LIVE_REPLAY_lab-rollover with no tools or project work.'
printf 'Control exit=%s\n' "$?"
cat "$LAB/state/lab-rollover.meta"
cat "$LAB/state/lab-rollover.control-relaunch" 2>/dev/null || true
if [ -f "$LAB/state/lab-rollover.cursor-limit" ]; then cat "$LAB/state/lab-rollover.cursor-limit"; else printf 'Expired cursor-limit retired after Cursor publication\n'; fi
printf 'done\n' > "$EV/live-second.done"
